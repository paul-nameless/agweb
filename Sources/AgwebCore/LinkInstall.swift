import Foundation

/// Links from outside the app into its bundle: the CLI on PATH and the agent skill folders.
/// Only lstat and readlink are used on what is already there, never a read through it: following a person's link
/// into ~/Downloads or ~/Documents would ask them for access.
public enum LinkInstall {
    public enum State: Equatable {
        case missing
        /// A link into some Agweb.app, this one or another copy.
        case ours(target: String)
        /// Anything else: a file, a folder, a link elsewhere (a dev checkout).
        case foreign(String)
    }

    public static func state(at path: String) -> State {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return .missing }
        guard attributes[.type] as? FileAttributeType == .typeSymbolicLink,
              let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else {
            return .foreign(attributes[.type] as? FileAttributeType == .typeDirectory ? "a folder" : "a file")
        }
        return isInBundle(target) ? .ours(target: target) : .foreign("a link to \(abbreviated(target))")
    }

    public static func isInBundle(_ path: String) -> Bool { path.contains("/Agweb.app/Contents/") }

    /// A copy macOS runs from a randomized read-only mount (an app opened where it was downloaded) or a disk image:
    /// a link to it breaks once it quits or is ejected.
    public static func isTransient(bundle: String) -> Bool {
        bundle.contains("/AppTranslocation/") || bundle.hasPrefix("/Volumes/")
    }

    /// Replaces whatever is at `path` with a link to `target`, creating the folder.
    public static func link(_ path: String, to target: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if state(at: path) != .missing { try fm.removeItem(atPath: path) }
        try fm.createSymbolicLink(atPath: path, withDestinationPath: target)
    }

    /// A link of ours that no longer leads anywhere: the app moved or a copy was deleted. Targets inside the folders
    /// macOS guards are never checked, for the reason above.
    public static func isBroken(_ target: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if ["Desktop", "Documents", "Downloads"].contains(where: { target.hasPrefix("\(home)/\($0)/") }) { return false }
        return !FileManager.default.fileExists(atPath: target)
    }

    public static func abbreviated(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
}

/// `/usr/local/bin/agweb`, on every default PATH, including the non-login shells agents run.
public enum CLILink {
    /// AGWEB_CLI_LINK moves it, so the selftest never touches the real one.
    public static var path: String { ProcessInfo.processInfo.environment["AGWEB_CLI_LINK"] ?? "/usr/local/bin/agweb" }

    public enum Outcome: Equatable {
        case linked
        case foreign(String)
        case transient
        /// The folder is root-owned (a clean Apple Silicon Mac); the app asks for an administrator password.
        case noPermission
        case failed(String)
    }

    public static func install(helper: String, bundle: String, replacingForeign: Bool = false) -> Outcome {
        if LinkInstall.isTransient(bundle: bundle) { return .transient }
        if !replacingForeign, case .foreign(let what) = LinkInstall.state(at: path) { return .foreign(what) }
        // The nearest folder that exists decides: /usr/local/bin may not exist yet, /usr/local then does.
        var folder = (path as NSString).deletingLastPathComponent
        while !FileManager.default.fileExists(atPath: folder) { folder = (folder as NSString).deletingLastPathComponent }
        if !FileManager.default.isWritableFile(atPath: folder) { return .noPermission }
        do {
            try LinkInstall.link(path, to: helper)
            return .linked
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    public static func status(helper: String) -> String {
        switch LinkInstall.state(at: path) {
        case .missing: "not installed"
        case .ours(let target) where target == helper: "installed at \(path)"
        case .ours(let target): "\(path) links to another copy: \(LinkInstall.abbreviated(target))"
        case .foreign(let what): "\(path) is \(what); left alone"
        }
    }

    public static func describe(_ outcome: Outcome, helper: String) -> String {
        switch outcome {
        case .linked: "Linked \(path) to \(LinkInstall.abbreviated(helper)). Open a new terminal and run agweb help."
        case .foreign(let what): "\(path) is \(what), not agweb's; left alone."
        case .transient: "agweb is running from a temporary copy. Move Agweb to Applications, open it from there and install again."
        case .noPermission: "No permission to write \(path)."
        case .failed(let message): "Could not link \(path): \(message)"
        }
    }

    /// For the administrator prompt.
    public static func shellCommand(helper: String) -> String {
        let quote = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return "mkdir -p \(quote((path as NSString).deletingLastPathComponent)) && ln -sfn \(quote(helper)) \(quote(path))"
    }
}
