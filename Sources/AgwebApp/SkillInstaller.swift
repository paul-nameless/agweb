import AgwebCore
import Foundation

/// Links Claude Code's and Codex's `skills/agweb` to the skill folder in this bundle, so the skill always matches the
/// app. A person's own `agweb` skill or link is left alone.
@MainActor
enum SkillInstaller {
    static let agents = [(name: "Claude Code", folder: ".claude"), (name: "Codex", folder: ".codex")]
    /// Ended the copies older versions installed; such a copy is replaced by the link.
    private static let copyMarker = "<!-- installed by agweb; reinstalled when agweb updates -->"

    /// AGWEB_HOME moves it, so the selftest never touches the person's agents.
    private static func destination(_ folder: String) -> String {
        let home = ProcessInfo.processInfo.environment["AGWEB_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/\(folder)/skills/agweb"
    }

    private static var bundled: String? {
        Bundle.main.resourceURL.map { $0.appendingPathComponent("skill").path }
            .flatMap { FileManager.default.fileExists(atPath: "\($0)/SKILL.md") ? $0 : nil }
    }

    private static func isOldCopy(_ path: String) -> Bool {
        (try? String(contentsOfFile: "\(path)/SKILL.md", encoding: .utf8))?.contains(copyMarker) == true
    }

    static func status(_ folder: String) -> String {
        let path = destination(folder)
        switch LinkInstall.state(at: path) {
        case .missing: return "not installed"
        case .ours(let target) where target == bundled: return "installed"
        case .ours(let target): return "links to another copy: \(LinkInstall.abbreviated(target))"
        case .foreign: return isOldCopy(path) ? "an older copy; Install replaces it" : "another agweb skill is there; left alone"
        }
    }

    /// One line per agent saying what happened. `repairOnly`, at launch: replace old copies and links that lead nowhere,
    /// add nothing new.
    @discardableResult
    static func install(repairOnly: Bool = false) -> [String] {
        guard let bundled else { return ["The skill is not bundled in this build."] }
        if LinkInstall.isTransient(bundle: Bundle.main.bundlePath) {
            return ["agweb is running from a temporary copy. Move Agweb to Applications, open it from there and install again."]
        }
        return agents.compactMap { agent in
            let path = destination(agent.folder)
            switch LinkInstall.state(at: path) {
            case .foreign where !isOldCopy(path): return repairOnly ? nil : "\(agent.name): another agweb skill is there; left alone"
            case .ours(let target) where target == bundled || repairOnly && !LinkInstall.isBroken(target): return repairOnly ? nil : "\(agent.name): installed"
            case .missing where repairOnly: return nil
            default: break
            }
            do {
                try LinkInstall.link(path, to: bundled)
                return "\(agent.name): linked \(LinkInstall.abbreviated(path))"
            } catch {
                return "\(agent.name): \(error.localizedDescription)"
            }
        }
    }
}
