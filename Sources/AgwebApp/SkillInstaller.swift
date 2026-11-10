import Foundation

/// Copies the bundled agent skill to Claude Code's and Codex's skills folders. Each copy ends with `marker`, so an
/// install, and the refresh at launch, replace only what agweb put there: a person's own `agweb` skill or link
/// is left alone.
@MainActor
enum SkillInstaller {
    static let marker = "<!-- installed by agweb; reinstalled when agweb updates -->"
    static let agents = [(name: "Claude Code", folder: ".claude"), (name: "Codex", folder: ".codex")]

    enum Status: String {
        case notInstalled = "not installed", installed, outdated = "installed, older version", foreign = "another agweb skill is there; left alone"
    }

    private static func destination(_ folder: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("\(folder)/skills/agweb/SKILL.md")
    }

    private static var bundled: String? {
        Bundle.main.url(forResource: "SKILL", withExtension: "md")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .map { $0 + "\n" + marker + "\n" }
    }

    static func status(_ folder: String) -> Status {
        let file = destination(folder), folderPath = file.deletingLastPathComponent().path
        // lstat, so a link there counts as present even when it points nowhere. A link is the person's own setup and
        // is never read: following it into ~/Downloads or ~/Documents would ask them for access at every launch.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: folderPath) else { return .notInstalled }
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink { return .foreign }
        guard let installed = try? String(contentsOf: file, encoding: .utf8), installed.contains(marker) else { return .foreign }
        return installed == bundled ? .installed : .outdated
    }

    /// One line per agent saying what happened.
    @discardableResult
    static func install(onlyOutdated: Bool = false) -> [String] {
        guard let bundled else { return ["The skill is not bundled in this build."] }
        return agents.compactMap { agent in
            let status = status(agent.folder)
            if status == .foreign { return "\(agent.name): \(status.rawValue)" }
            if onlyOutdated, status != .outdated { return nil }
            let file = destination(agent.folder)
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bundled.write(to: file, atomically: true, encoding: .utf8)
                return "\(agent.name): installed at \((file.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)"
            } catch {
                return "\(agent.name): \(error.localizedDescription)"
            }
        }
    }
}
