import AppKit
import Carbon

/// One Claude Code session, as last written by the hook script.
struct ClaudeSession: Equatable {
    let id: String
    let state: String        // thinking, typing, searching, working, needs_you, ready
    let at: TimeInterval     // unix time of the last hook event
    let project: String      // folder name of the session's working directory
    var tty: String?         // Claude's terminal (e.g. "ttys001") and the app it runs in (e.g.
    var app: String?         // "com.apple.Terminal"): only known while it needs you or it's your turn

    var isWorking: Bool { ["thinking", "typing", "searching", "working"].contains(state) }

    var label: String {
        switch state {
        case "needs_you": return "needs you"
        case "ready": return "your turn"
        case "typing": return "editing"
        case "searching": return "reading"
        default: return state
        }
    }
}

/// What all Claude sessions on this Mac are doing.
struct ClaudeSummary: Equatable {
    var sessions: [ClaudeSession] = []
    var needsYou: [ClaudeSession] { sessions.filter { $0.state == "needs_you" } }
    var ready: [ClaudeSession] { sessions.filter { $0.state == "ready" } }
    var working: [ClaudeSession] { sessions.filter { $0.isWorking } }
}

/// Reads ~/.promptpaws/sessions/<session id> ("<state> <unix time> <project>", plus "<tty> <app id>" on a
/// second line while it needs you or it's your turn), one file per session, written by the hook script.
/// A session with no events for a while no longer counts (Claude may have been stopped with Esc, which
/// sends no hook event).
final class SessionWatcher {
    static let dir = Log.dir.appendingPathComponent("sessions", isDirectory: true)
    static let workingFor: TimeInterval = 20 * 60
    static let waitingFor: TimeInterval = 3 * 3600
    private var signature = "-"

    /// The current summary when anything changed since the last call, else nil.
    func poll() -> ClaudeSummary? {
        let fm = FileManager.default
        let now = Date().timeIntervalSince1970
        // The self-test reads only its own fake sessions, so your real sessions cannot change its results.
        let names = ((try? fm.contentsOfDirectory(atPath: Self.dir.path)) ?? [])
            .filter { !$0.contains(".") && (!Log.selftest || SelfTest.sessions.contains($0)) }
        var sessions: [ClaudeSession] = []
        for name in names.sorted() {
            let url = Self.dir.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let first = lines.first else { continue }
            let parts = first.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 2, let at = TimeInterval(String(parts[1])) else { continue }
            var session = ClaudeSession(id: name, state: String(parts[0]), at: at,
                                        project: parts.count > 2 ? String(parts[2]) : "Claude")
            if lines.count > 1 {
                let place = lines[1].split(separator: " ").map(String.init).map { $0 == "-" ? nil : $0 }
                session.tty = place.first ?? nil
                session.app = place.count > 1 ? place[1] : nil
            }
            let age = now - at
            if age > 86_400 {
                try? fm.removeItem(at: url)   // a day old: that session is long gone
                continue
            }
            if age < (session.isWorking ? Self.workingFor : Self.waitingFor) { sessions.append(session) }
        }
        let sig = sessions.map { "\($0.id):\($0.state):\($0.at)" }.joined(separator: "|")
        guard sig != signature else { return nil }
        signature = sig
        return ClaudeSummary(sessions: sessions)
    }
}

/// A system-wide shortcut through Carbon's RegisterEventHotKey (needs no Accessibility permission).
final class Hotkey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let hotkey = Unmanaged<Hotkey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { hotkey.action() }
            return noErr
        }, 1, &spec, me, &handlerRef)
        guard installed == noErr else { return nil }
        let id = EventHotKeyID(signature: OSType(0x4450_4554), id: 1) // "DPET"
        guard RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef) == noErr else {
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}

/// "Start at login" through a LaunchAgent that opens the app by its bundle ID at login, so it still
/// starts after the app is moved (or when it was first opened from Downloads).
enum LoginItem {
    static let id = Bundle.main.bundleIdentifier ?? "io.github.biswajitdasb4-oss.promptpaws"
    static let plist = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/\(id).plist")

    static var enabled: Bool { FileManager.default.fileExists(atPath: plist.path) }

    /// What the LaunchAgent file holds.
    static var contents: [String: Any] {
        ["Label": id, "ProgramArguments": ["/usr/bin/open", "-b", id], "RunAtLoad": true]
    }

    static func set(_ on: Bool) {
        guard on else {
            try? FileManager.default.removeItem(at: plist)
            return
        }
        try? FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? PropertyListSerialization.data(fromPropertyList: contents, format: .xml, options: 0) {
            try? data.write(to: plist)
        }
    }
}

/// Characters shipped in the app plus any in ~/.promptpaws/characters/<name>/character.json.
struct Character {
    let id: String      // folder URL relative to the page, e.g. "../characters/robot/"
    let name: String

    static func all() -> [Character] {
        var list: [Character] = []
        let sources: [(URL, String)] = [
            (Bundle.main.resourceURL!.appendingPathComponent("characters"), "../characters/"),
            (Log.dir.appendingPathComponent("characters"), "../user-characters/"),
        ]
        for (dir, prefix) in sources {
            let folders = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            for folder in folders.sorted() {
                let json = dir.appendingPathComponent(folder).appendingPathComponent("character.json")
                guard let data = try? Data(contentsOf: json),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                let path = folder.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? folder
                list.append(Character(id: prefix + path + "/", name: obj["name"] as? String ?? folder))
            }
        }
        return list
    }
}
