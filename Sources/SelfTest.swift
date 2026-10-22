import AppKit

/// `PromptPaws --selftest`: checks the window setup, plays every clip, drives a fake Claude session
/// through the real hook script (bubble + reactions, click to open Claude), checks that Stay never walks and Sleep stays
/// asleep, clicks, drags, hides and shows the pet, lets it roam, then prints PASS/FAIL and quits.
/// It does not change the saved mode, place, size or character (see AppDelegate.persist).
final class SelfTest {
    static let session = "promptpaws-selftest"   // the fake session's id (its file in ~/.promptpaws/sessions)
    static let session2 = "promptpaws-selftest-2"   // a second one, for which session a click opens
    static let sessions = [session, session2]
    private unowned let app: AppDelegate
    private var started = false
    private var finished = false
    private var failures: [String] = []
    private var fpsSamples: [Double] = []
    private var steps: [(TimeInterval, (@escaping () -> Void) -> Void)] = []
    private let project = "Prompt Paws Self Test"
    private let project2 = "Prompt Paws Self Test 2"

    init(app: AppDelegate) {
        self.app = app
        Log.write("SELFTEST start")
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak self] in
            guard let self, !self.started else { return }
            self.check(false, "character became ready within 90 s")
            self.finish()
        }
    }

    func stats(_ m: [String: Any]) {
        if let fps = (m["fps"] as? NSNumber)?.doubleValue { fpsSamples.append(fps) }
    }

    private var testSession: ClaudeSession? { app.claude.sessions.first { $0.project == project } }
    private var testSession2: ClaudeSession? { app.claude.sessions.first { $0.project == project2 } }

    // swiftlint:disable:next function_body_length
    func characterReady() {
        guard !started else { return }
        started = true
        let brain = app.brain!
        let panel = app.panel!

        step(1) {
            let b = panel.collectionBehavior
            Log.write("window: level \(panel.level.rawValue), behaviour \(b.rawValue), frame \(panel.frame)")
            self.check(panel.level == .floating, "window floats above normal windows")
            self.check(b.contains(.canJoinAllSpaces), "window shows on every Space")
            self.check(b.contains(.fullScreenAuxiliary), "window may show over full-screen apps")
            self.check(!panel.canBecomeKey, "window never takes keyboard focus")
            self.check(panel.isVisible, "window is on screen")
            self.check(self.app.statusItem.isVisible, "paw icon is in the menu bar")
            self.check(brain.keys.count >= 10, "at least 10 behaviour keys resolved (got \(brain.keys.count))")
            let copy = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".promptpaws/pet-mood.sh")
            self.check(!FileManager.default.fileExists(atPath: copy.path),
                       "the hook script comes from the plugin; the app puts no copy in ~/.promptpaws")
            self.check(self.menuTitles().contains("Connect Claude Code…"),
                       "before any Claude session -> the menu offers 'Connect Claude Code…'")
            let login = LoginItem.contents["ProgramArguments"] as? [String] ?? []
            self.check(login == ["/usr/bin/open", "-b", "io.github.biswajitdasb4-oss.promptpaws"],
                       "Start at Login opens the app by its ID, so moving the app keeps it working (\(login))")
            self.check(brain.napAfter == .infinity, "test runs never nap because the real user is away")
            brain.autopilot = false
        }
        for key in brain.keys.keys.sorted() {
            step(0.8) { brain.debugPlay(key) }
        }

        // A fake Claude session through the real hook script.
        step(1) {
            brain.autopilot = true
            brain.setMode(.roam)
            self.hook("thinking")
        }
        step(1.2) {
            let file = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".promptpaws/sessions/\(Self.session)")
            self.check(FileManager.default.fileExists(atPath: file.path), "the hook writes ~/.promptpaws/sessions/<session id>")
            self.check(!self.menuTitles().contains("Connect Claude Code…"),
                       "after the first Claude session -> 'Connect Claude Code…' is gone")
            self.check(self.testSession?.state == "thinking", "hook 'thinking' -> session is working")
            self.bubble { self.check(!$0.isEmpty, "working -> a bubble shows (\($0))") }
            self.hook("notify", extra: #","notification_type":"permission_prompt""#)
        }
        step(1.2) {
            self.check(self.testSession?.state == "needs_you", "permission prompt -> session needs you")
            self.bubble { self.check($0 == "needs", "needs you -> orange 'Needs you' bubble (\($0))") }
        }
        // The pet may first have to stand up (if it sat down), so wait for the reaction instead of looking at one moment.
        expect(within: 4, { "needs you -> comes over / waves (\(brain.activity))" }, { [.approach, .wave].contains(brain.activity) })
        step(0) {
            self.check(self.testSession?.app == "selftest.app", "needs you -> hook notes the app Claude runs in (\(self.testSession?.app ?? "none"))")
            let h = brain.hitOnScreen
            brain.mouseDown(at: CGPoint(x: h.midX, y: h.midY))
            brain.mouseUp(at: CGPoint(x: h.midX, y: h.midY))
            self.check(self.app.openedClaude?.id == Self.session && brain.activity == .wave,
                       "click while it needs you -> opens that session and waves (\(self.app.openedClaude?.id ?? "nothing"), \(brain.activity))")
            self.hook("ready")
        }
        step(1.2) {
            self.check(self.testSession?.state == "ready", "Stop -> session is 'your turn'")
        }
        // The hook and the 3 Hz session watcher can take a while (slower under Rosetta): wait for the cheer.
        // 4 s stays close to the cheer's own 3.4 s, and only this hook can start a cheer, so no later state can pass for it.
        expect(within: 4, { "Claude finished -> cheers once (\(brain.activity))" }, { brain.activity == .cheer })
        step(0) {
            self.check(self.testSession?.app == "selftest.app", "your turn -> hook notes the app Claude runs in (\(self.testSession?.app ?? "none"))")
            self.click()
            let s = self.testSession
            self.check(s != nil && self.app.openedClaude == s && brain.activity == .wave,
                       "click on 'your turn' -> opens that session and waves (\(self.app.openedClaude?.state ?? "nothing"), \(brain.activity))")
            self.hook("working", extra: #","agent_id":"sub-1""#)
        }
        step(1.2) {
            self.check(self.testSession?.state == "ready", "a subagent's work does not hide 'your turn'")
            self.hook("end")
        }
        step(1.2) {
            self.check(self.testSession == nil, "SessionEnd -> session gone")
        }

        // Two sessions: a click opens the one that needs you, else the 'your turn' that has waited longest.
        step(0.5) { self.hook("ready") }
        step(1.2) { self.hook("ready", session: Self.session2, project: self.project2) }
        step(1.2) {
            self.click()
            let first = self.testSession
            self.check(first != nil && self.app.openedClaude == first,
                       "two on 'your turn' -> click opens the one waiting longest (\(self.app.openedClaude?.project ?? "nothing"))")
            self.hook("notify", extra: #","notification_type":"permission_prompt""#, session: Self.session2, project: self.project2)
        }
        step(1.2) {
            self.click()
            let needs = self.testSession2
            self.check(needs?.state == "needs_you" && self.app.openedClaude == needs,
                       "needs you beats 'your turn' -> click opens the one that needs you (\(self.app.openedClaude?.project ?? "nothing"))")
            self.hook("end")
            self.hook("end", session: Self.session2, project: self.project2)
        }

        // Stay: never walks, even while Claude works.
        var spot = CGPoint.zero
        step(0.5) {
            brain.setMode(.stay)
            self.hook("typing")
            spot = brain.feet
        }
        step(7) {
            let moved = hypot(brain.feet.x - spot.x, brain.feet.y - spot.y)
            self.check(moved < 0.5, "Stay: did not move in 7 s while Claude worked (moved \(moved) pt)")
            self.hook("end")
        }

        // Sleep: lies down and stays down, whatever you do with the mouse.
        step(0.5) { brain.setMode(.sleep) }
        step(2.5) {
            self.check(brain.activity == .sleep, "Sleep: lies down (\(brain.activity))")
            self.app.petView.query("[pet.zzzShown(), pet.bubbleKind()]") { r in
                let a = r as? [Any] ?? []
                let zzz = a.first as? Bool ?? false
                let kind = a.count > 1 ? a[1] as? String ?? "" : ""
                self.check(zzz == kind.isEmpty, "Sleep: z's show unless a Claude bubble does (zzz \(zzz), bubble '\(kind)')")
            }
        }
        step(4) {
            self.check(brain.activity == .sleep && brain.mode == .sleep, "Sleep: still asleep 4 s later (\(brain.activity))")
            let h = brain.hitOnScreen
            brain.mouseDown(at: CGPoint(x: h.midX, y: h.midY))
            brain.mouseUp(at: CGPoint(x: h.midX, y: h.midY))
            self.check(brain.mode == .stay && brain.activity == .wake, "click wakes it into the mode before sleep (\(brain.mode), \(brain.activity))")
        }

        // Drag and drop, hide and show.
        var before = CGPoint.zero
        step(1.5) {
            before = brain.feet
            let h = brain.hitOnScreen
            let p = CGPoint(x: h.midX, y: h.midY)
            brain.mouseDown(at: p)
            brain.mouseDragged(to: CGPoint(x: p.x + 40, y: p.y + 30))
            brain.mouseDragged(to: CGPoint(x: p.x + 80, y: p.y + 60))
        }
        step(0.4) {
            let off = hypot(brain.feet.x - before.x - 80, brain.feet.y - before.y - 60)
            self.check(brain.activity == .dragged && off < 1, "drag moves the pet with the pointer (off by \(off))")
            let h = brain.hitOnScreen
            brain.mouseUp(at: CGPoint(x: h.midX, y: h.midY))
            self.check(brain.activity == .land, "drop -> lands (\(brain.activity))")
        }
        step(1) {
            self.app.toggleHidden()
            self.check(!panel.isVisible && brain.hidden, "Option+Command+P action hides the pet")
        }
        step(0.6) {
            self.app.toggleHidden()
            self.check(panel.isVisible && !brain.hidden, "Option+Command+P action shows it again")
            brain.setMode(.roam)
            self.fpsSamples.removeAll()
        }

        // Roam for a while and render smoothly.
        var seen: [String] = []
        for _ in 0..<12 {
            step(1) { if seen.last != brain.activity.rawValue { seen.append(brain.activity.rawValue) } }
        }
        step(0.5) {
            Log.write("roaming 12 s: \(seen.joined(separator: " -> "))")
            let fps = self.fpsSamples.isEmpty ? 0 : self.fpsSamples.reduce(0, +) / Double(self.fpsSamples.count)
            self.check(fps > 20, "renders smoothly (\(String(format: "%.1f", fps)) fps)")
            self.check(self.app.pageErrors == 0, "no page errors (\(self.app.pageErrors))")
            self.finish()
        }
        run()
    }

    private func step(_ delay: TimeInterval, _ body: @escaping () -> Void) {
        steps.append((delay, { done in body(); done() }))
    }

    /// Waits for the pet's reaction to a Claude state change: polls `cond` every 0.1 s until it is true or `timeout`
    /// passes, then checks it once with the final label. The steps after it run only when it has finished.
    private func expect(within timeout: TimeInterval, _ what: @escaping () -> String, _ cond: @escaping () -> Bool) {
        steps.append((0, { done in
            let deadline = Date().addingTimeInterval(timeout)
            func poll() {
                let ok = cond()
                if ok || Date() >= deadline {
                    self.check(ok, what())
                    done()
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { poll() }
                }
            }
            poll()
        }))
    }

    private func run() {
        guard !steps.isEmpty, !finished else { return }
        let (delay, body) = steps.removeFirst()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            body { self?.run() }
        }
    }

    private func bubble(_ done: @escaping (String) -> Void) {
        app.petView.query("pet.bubbleKind()") { done($0 as? String ?? "?") }
    }

    /// The titles of the menu the paw icon and a right-click show.
    private func menuTitles() -> [String] { app.makeMenu().items.map(\.title) }

    /// A plain click in the middle of the pet.
    private func click() {
        let h = app.brain.hitOnScreen
        app.brain.mouseDown(at: CGPoint(x: h.midX, y: h.midY))
        app.brain.mouseUp(at: CGPoint(x: h.midX, y: h.midY))
    }

    /// Sends a hook event for a fake session through the real script, as Claude Code would.
    private func hook(_ state: String, extra: String = "", session: String = SelfTest.session, project: String? = nil) {
        let json = #"{"session_id":"\#(session)","cwd":"/tmp/\#(project ?? self.project)""# + extra + "}"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [Bundle.main.url(forResource: "pet-mood", withExtension: "sh")!.path, state]
        // Claude Code passes on the app it runs in through this variable; the script records it.
        p.environment = ProcessInfo.processInfo.environment.merging(["__CFBundleIdentifier": "selftest.app"]) { $1 }
        let pipe = Pipe()
        p.standardInput = pipe
        do {
            try p.run()
            pipe.fileHandleForWriting.write(Data(json.utf8))
            try? pipe.fileHandleForWriting.close()
            p.waitUntilExit()
        } catch {
            check(false, "hook script runs (\(error))")
        }
    }

    private func check(_ ok: Bool, _ what: String) {
        Log.write("\(ok ? "ok  " : "FAIL") \(what)")
        if !ok { failures.append(what) }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        for s in Self.sessions { try? FileManager.default.removeItem(at: SessionWatcher.dir.appendingPathComponent(s)) }
        Log.write(failures.isEmpty ? "SELFTEST PASS" : "SELFTEST FAIL (\(failures.count)): \(failures.joined(separator: "; "))")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(self.failures.isEmpty ? 0 : 1) }
    }
}

/// `PromptPaws --bench`: runs fixed phases (roam, asleep, paused, hidden) so tools/measure.py can read
/// the CPU time of the app and its WebKit helper processes at each "BENCH <phase>" log line.
enum Bench {
    static let phase: TimeInterval = 40

    static func run(_ app: AppDelegate) {
        let brain = app.brain!
        let plan: [(String, () -> Void)] = [
            ("roam", { brain.setMode(.roam) }),
            ("asleep", { brain.setMode(.sleep) }),
            ("paused", { brain.setPaused(true) }),
            ("hidden", { brain.setPaused(false); app.toggleHidden() }),
        ]
        for (i, (name, action)) in plan.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5 + phase * Double(i)) {
                action()
                Log.write("BENCH \(name)")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5 + phase * Double(plan.count)) {
            Log.write("BENCH end")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
        }
    }
}
