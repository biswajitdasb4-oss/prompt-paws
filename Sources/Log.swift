import Foundation

/// Appends lines to ~/.promptpaws/promptpaws.log (and to stderr in --selftest runs).
enum Log {
    static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".promptpaws", isDirectory: true)
    static let file = dir.appendingPathComponent("promptpaws.log")
    static let selftest = CommandLine.arguments.contains("--selftest")

    private static let queue = DispatchQueue(label: "promptpaws.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func start() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int ?? 0
        if size > 1_000_000 { try? FileManager.default.removeItem(at: file) }
    }

    static func write(_ text: String) {
        let now = Date()
        queue.async {
            let line = "\(stamp.string(from: now)) \(text)\n"
            let data = Data(line.utf8)
            if let h = try? FileHandle(forWritingTo: file) {
                h.seekToEndOfFile()
                h.write(data)
                try? h.close()
            } else {
                try? data.write(to: file)
            }
            if selftest { FileHandle.standardError.write(data) }
        }
    }
}
