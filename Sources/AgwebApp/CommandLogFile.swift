#if AGWEB_COMMAND_LOG
import AgwebCore
import Foundation

/// ~/Library/Logs/agweb/commands.jsonl, renamed to commands.1.jsonl at 10 MB. Test instances don't write.
@MainActor
enum CommandLogFile {
    private static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/agweb")
    private static let file = folder.appendingPathComponent("commands.jsonl")

    static func append(_ request: Request, _ response: Response, started: Date) {
        guard !Agweb.customSocket else { return }
        let line = CommandLog.line(request, ok: response.ok, output: response.output, at: started, seconds: Date().timeIntervalSince(started)) + "\n"
        let fm = FileManager.default
        if let size = try? fm.attributesOfItem(atPath: file.path)[.size] as? Int, size > 10_000_000 {
            let old = folder.appendingPathComponent("commands.1.jsonl")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: file, to: old)
        }
        if !fm.fileExists(atPath: file.path) {
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }
}
#endif
