import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let robot = "../characters/robot/"   // tiny fallback if a character fails to load
    static let panda = "../characters/panda/"   // default character
    static let sizes: [(String, CGFloat)] = [("Small", 160), ("Medium", 220), ("Large", 300)]
    static let isBench = CommandLine.arguments.contains("--bench")
    /// The README section that explains how to connect Claude Code (the plugin command).
    static let connectHelp = URL(string: "https://github.com/biswajitdasb4-oss/prompt-paws#2-connect-claude-code")!
    /// `--character <folder>`: load that built-in character instead of the saved one (for --selftest/--bench).
    static let forcedCharacter: String? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--character"), i + 1 < args.count else { return nil }
        return "../characters/\(args[i + 1])/"
    }()

    private(set) var panel: PetPanel!
    private(set) var brain: Brain!
    private(set) var petView: PetView!
    private var grab: GrabView!
    private(set) var statusItem: NSStatusItem!
    private var hotkey: Hotkey?
    private var timer: Timer?
    private let sessions = SessionWatcher()
    private(set) var claude = ClaudeSummary()
    private var claudeLogged = ""
    private(set) var openedClaude: ClaudeSession?   // last session a click brought forward (self-test)
    private var ticks = 0
    private var statsCount = 0
    private var selfTest: SelfTest?
    private var benchStarted = false
    private(set) var pageErrors = 0
    /// True once any Claude session has been seen; until then the menus offer "Connect Claude Code…".
    private(set) var claudeSeen = false
    private(set) var currentCharacter = ""
    private var characterName = "Pet"
    private var characterCredit = ""
    private let defaults = UserDefaults.standard
    /// Test runs must not change what the real pet remembers.
    private let persist = !(Log.selftest || AppDelegate.isBench)

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.start()
        Log.write("Prompt Paws starting (pid \(ProcessInfo.processInfo.processIdentifier))")
        claudeSeen = persist && defaults.bool(forKey: "claudeSeen")   // test runs always start "not connected"

        let saved = CGFloat(defaults.double(forKey: "size"))
        let size = saved > 0 ? saved : 220
        let frame = NSRect(x: 0, y: 0, width: size, height: size)
        panel = PetPanel(size: size)
        petView = PetView(frame: frame)
        grab = GrabView(frame: frame)
        grab.autoresizingMask = [.width, .height]
        let container = NSView(frame: frame)
        container.addSubview(petView.webView)
        container.addSubview(grab)
        panel.contentView = container

        brain = Brain(panel: panel, view: petView)
        if Log.selftest || Self.isBench { brain.napAfter = .infinity }   // test runs must not depend on whether someone is at the Mac
        restorePlace()
        brain.onSave = { [weak self] in self?.savePlace() }
        brain.onOpenClaude = { [weak self] s in self?.openClaude(s) }
        grab.onDown = { [weak self] p in self?.brain.mouseDown(at: p) }
        grab.onDrag = { [weak self] p in self?.brain.mouseDragged(to: p) }
        grab.onUp = { [weak self] p in self?.brain.mouseUp(at: p) }
        grab.onMenu = { [weak self] event in
            guard let self else { return }
            NSMenu.popUpContextMenu(self.makeMenu(), with: event, for: self.grab)
        }
        petView.onMessage = { [weak self] message in self?.handle(message) }

        loadCharacter(Self.forcedCharacter ?? defaults.string(forKey: "character") ?? Self.panda)
        panel.orderFrontRegardless()
        setUpStatusItem()

        hotkey = Hotkey(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey | optionKey)) { [weak self] in
            self?.toggleHidden()
        }
        if hotkey == nil { Log.write("could not register Option+Command+P") }

        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)   // .common: keeps running while a menu is open
        timer = t
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.brain.screensChanged()
        }

        if Log.selftest { selfTest = SelfTest(app: self) }
    }

    func applicationWillTerminate(_ notification: Notification) { savePlace() }

    private func tick() {
        brain.tick()
        ticks += 1
        if ticks % 9 == 0, let summary = sessions.poll() { claudeChanged(summary) }
    }

    // MARK: - Mode and place, remembered between launches

    private func restorePlace() {
        let mode = PetMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .roam
        let before = PetMode(rawValue: defaults.string(forKey: "modeBeforeSleep") ?? "") ?? .roam
        var feet: CGPoint?
        if defaults.object(forKey: "feetX") != nil {
            feet = CGPoint(x: defaults.double(forKey: "feetX"), y: defaults.double(forKey: "feetY"))
        }
        brain.restore(mode: mode, modeBeforeSleep: before, feet: feet)
    }

    private func savePlace() {
        guard persist, let brain else { return }
        defaults.set(brain.mode.rawValue, forKey: "mode")
        defaults.set(brain.modeBeforeSleep.rawValue, forKey: "modeBeforeSleep")
        defaults.set(Double(brain.feet.x), forKey: "feetX")
        defaults.set(Double(brain.feet.y), forKey: "feetY")
    }

    // MARK: - Claude status: bubble, menu-bar icon, reactions

    private func claudeChanged(_ summary: ClaudeSummary) {
        let before = Dictionary(claude.sessions.map { ($0.id, $0.state) }, uniquingKeysWith: { a, _ in a })
        let newNeeds = summary.needsYou.contains { before[$0.id] != "needs_you" }
        let newReady = summary.ready.contains { before[$0.id] != nil && before[$0.id] != "ready" }
        claude = summary
        if !summary.sessions.isEmpty, !claudeSeen {
            claudeSeen = true
            if persist { defaults.set(true, forKey: "claudeSeen") }
        }
        // Log only real changes: a session starts or ends, or moves between working / needs you / your turn.
        let line = summary.sessions.isEmpty ? "no sessions"
            : summary.sessions.map { "\($0.project) \($0.isWorking ? "working" : $0.label)" }.joined(separator: ", ")
        if line != claudeLogged {
            claudeLogged = line
            Log.write("claude: " + line)
        }
        brain.claudeChanged(summary, newNeeds: newNeeds, newReady: newReady)
        showBubble()
        updateStatusIcon()
    }

    /// The most useful line for the bubble: needs you > your turn > working.
    func bubble(for s: ClaudeSummary) -> [String: String]? {
        func who(_ list: [ClaudeSession]) -> String {
            let names = Array(Set(list.map(\.project)))
            return names.count == 1 && list.count == 1 ? names[0] : "\(list.count) sessions"
        }
        if !s.needsYou.isEmpty { return ["kind": "needs", "text": "Needs you", "sub": who(s.needsYou)] }
        if !s.ready.isEmpty { return ["kind": "ready", "text": "Your turn", "sub": who(s.ready)] }
        if !s.working.isEmpty { return ["kind": "working", "text": "Working", "sub": who(s.working)] }
        return nil
    }

    private func showBubble() {
        guard brain.ready else { return }
        if let b = bubble(for: claude),
           let data = try? JSONSerialization.data(withJSONObject: b),
           let json = String(data: data, encoding: .utf8) {
            petView.js("pet.status(\(json))")
        } else {
            petView.js("pet.status(null)")
        }
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let (symbol, tint): (String, NSColor?) = !claude.needsYou.isEmpty ? ("hand.raised.fill", .systemOrange)
            : !claude.ready.isEmpty ? ("checkmark.circle.fill", .systemGreen)
            : ("pawprint.fill", nil)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Prompt Paws")
        button.image?.isTemplate = true
        button.contentTintColor = tint
        button.toolTip = bubble(for: claude).map { "Prompt Paws: \($0["text"]!) (\($0["sub"]!))" } ?? "Prompt Paws"
    }

    /// Brings a Claude session that needs you (or whose turn it is) to the front: its Terminal tab
    /// (macOS asks once for permission to control Terminal), else the app it runs in. osascript runs in
    /// the background so the pet never waits for Terminal or for that permission prompt.
    private func openClaude(_ s: ClaudeSession) {
        openedClaude = s
        Log.write("click: open \(s.project) (\(s.tty ?? "no tty") in \(s.app ?? "unknown app"))")
        guard !Log.selftest else { return }
        let app = s.app ?? "com.apple.Terminal"
        guard app == "com.apple.Terminal", let tty = s.tty, tty.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            NSRunningApplication.runningApplications(withBundleIdentifier: app).first?
                .activate(options: [.activateIgnoringOtherApps])
            return
        }
        let script = """
            on run {ttyPath}
                tell application id "com.apple.Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is ttyPath then
                                if miniaturized of w then set miniaturized of w to false
                                set selected tab of w to t
                                set index of w to 1
                                activate
                                return "found"
                            end if
                        end repeat
                    end repeat
                    activate
                    return "tab not found"
                end tell
            end run
            """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script, "/dev/\(tty)"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.terminationHandler = { p in
            let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            Log.write("open Claude: \(text.trimmingCharacters(in: .whitespacesAndNewlines)) (exit \(p.terminationStatus))")
        }
        do { try p.run() } catch { Log.write("open Claude: osascript failed (\(error))") }
    }

    // MARK: - Page messages

    private func handle(_ m: [String: Any]) {
        switch m["type"] as? String {
        case "layout":
            guard let foot = m["foot"] as? [String: Any], let hit = m["hit"] as? [String: Any] else { return }
            brain.layoutChanged(foot: CGPoint(x: num(foot["x"]), y: num(foot["y"])),
                                hit: CGRect(x: num(hit["x"]), y: num(hit["y"]), width: num(hit["w"]), height: num(hit["h"])),
                                height: num(m["height"]))
        case "ready":
            characterName = m["name"] as? String ?? "Pet"
            characterCredit = m["credit"] as? String ?? ""
            var keys: [String: Double] = [:]
            for (k, v) in (m["keys"] as? [String: Any]) ?? [:] {
                keys[k] = Double(num((v as? [String: Any])?["duration"]))
            }
            let clips = (m["clips"] as? [String])?.joined(separator: ", ") ?? ""
            Log.write("ready: \(characterName); clips: \(clips); mode \(brain.mode.rawValue)")
            brain.characterReady(walkSpeed: Double(num(m["walkSpeed"])), runSpeed: Double(num(m["runSpeed"])), keys: keys)
            showBubble()
            selfTest?.characterReady()
            if Self.isBench, !benchStarted {
                benchStarted = true
                Bench.run(self)
            }
        case "finished":
            brain.clipFinished(m["key"] as? String ?? "")
        case "stats":
            statsCount += 1
            if Log.selftest || statsCount % 12 == 1 {
                Log.write("stats: \(m["fps"] ?? "?") fps, \(m["ms"] ?? "?") ms per frame, doing \(brain.activity.rawValue)")
            }
            selfTest?.stats(m)
        case "log":
            if (m["level"] as? String) == "error" { pageErrors += 1 }
            Log.write("page \(m["level"] ?? ""): \(m["text"] ?? "")")
        case "loadFailed":
            pageErrors += 1
            Log.write("character failed to load: \(m["text"] ?? "")")
            if currentCharacter != Self.robot { loadCharacter(Self.robot) }
        default:
            break
        }
    }

    private func num(_ v: Any?) -> CGFloat { CGFloat((v as? NSNumber)?.doubleValue ?? 0) }

    private func loadCharacter(_ id: String) {
        currentCharacter = id
        if persist { defaults.set(id, forKey: "character") }
        brain.characterUnloaded()
        petView.load(character: id)
    }

    // MARK: - Menus (menu bar icon and right-click on the pet)

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusIcon()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, let w = self.statusItem.button?.window else { return }
            Log.write("menu-bar icon: visible \(self.statusItem.isVisible), at \(w.frame)")
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let fresh = makeMenu()
        let items = fresh.items
        fresh.removeAllItems()
        menu.removeAllItems()
        items.forEach(menu.addItem)
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(header(characterName))
        if !claudeSeen { menu.addItem(item("Connect Claude Code…", #selector(openConnectHelp))) }
        if claude.sessions.isEmpty {
            menu.addItem(note("Claude: no active sessions"))
        } else {
            for s in claude.sessions {
                let dot = s.state == "needs_you" ? "🟠" : s.state == "ready" ? "🟢" : "⚪️"
                menu.addItem(note("\(dot) \(s.project): \(s.label)"))
            }
        }
        menu.addItem(.separator())

        menu.addItem(item("Roam Around", #selector(modeRoam), on: brain.mode == .roam))
        menu.addItem(item("Stay in One Place", #selector(modeStay), on: brain.mode == .stay))
        menu.addItem(item(brain.mode == .sleep ? "Sleeping (click the pet to wake it)" : "Sleep Here",
                          #selector(modeSleep), on: brain.mode == .sleep))
        menu.addItem(.separator())

        let show = item(brain.hidden ? "Show Pet" : "Hide Pet", #selector(toggleHiddenAction), key: "p")
        show.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(show)
        menu.addItem(item("Pause Animation", #selector(togglePause), on: brain.paused))

        let sizeMenu = NSMenu()
        for (name, value) in Self.sizes {
            let i = item(name, #selector(pickSize(_:)), on: abs(panel.frame.width - value) < 1)
            i.tag = Int(value)
            sizeMenu.addItem(i)
        }
        let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        let charMenu = NSMenu()
        for c in Character.all() {
            let i = item(c.name, #selector(pickCharacter(_:)), on: c.id == currentCharacter)
            i.representedObject = c.id
            charMenu.addItem(i)
        }
        charMenu.addItem(.separator())
        charMenu.addItem(item("Open Characters Folder", #selector(openCharactersFolder)))
        if !characterCredit.isEmpty { charMenu.addItem(note(characterCredit)) }
        let charItem = NSMenuItem(title: "Character", action: nil, keyEquivalent: "")
        charItem.submenu = charMenu
        menu.addItem(charItem)
        menu.addItem(.separator())

        menu.addItem(item("Start at Login", #selector(toggleLogin), on: LoginItem.enabled))
        menu.addItem(item("Open Log", #selector(openLog)))
        menu.addItem(item("Quit Prompt Paws", #selector(quit), key: "q"))
        return menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "", on: Bool = false) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        i.state = on ? .on : .off
        return i
    }

    private func note(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func header(_ title: String) -> NSMenuItem {
        let i = note(title)
        i.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        return i
    }

    // MARK: - Actions

    func toggleHidden() { brain.setHidden(!brain.hidden) }
    @objc private func toggleHiddenAction() { toggleHidden() }
    @objc private func modeRoam() { brain.setMode(.roam) }
    @objc private func modeStay() { brain.setMode(.stay) }
    @objc private func modeSleep() { brain.setMode(.sleep) }
    @objc private func togglePause() { brain.setPaused(!brain.paused) }
    @objc private func toggleLogin() { LoginItem.set(!LoginItem.enabled) }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func pickSize(_ sender: NSMenuItem) {
        let size = CGFloat(sender.tag)
        if persist { defaults.set(Double(size), forKey: "size") }
        panel.setContentSize(NSSize(width: size, height: size))   // the page reports the new layout
    }

    @objc private func pickCharacter(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, id != currentCharacter else { return }
        loadCharacter(id)
    }

    @objc private func openCharactersFolder() {
        let dir = Log.dir.appendingPathComponent("characters", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    @objc private func openLog() { NSWorkspace.shared.open(Log.file) }
    @objc private func openConnectHelp() { NSWorkspace.shared.open(Self.connectHelp) }
}
