import AppKit
import AgwebCore
import Security
import Synchronization

/// Check for Updates and `agweb update`: only when the person asks, never on its own. Reads the latest GitHub
/// release, and on request downloads its Agweb.dmg, checks the app in it is signed by the same Developer ID team as
/// this one, swaps it in for this bundle and restarts, every workspace reopening.
enum Updater {
    struct Release {
        let version: String
        let dmg: URL
        let page: URL
        let notes: String
    }

    /// AGWEB_UPDATE_FEED points the selftest at a local release; it also lets a local build update itself.
    static let override = ProcessInfo.processInfo.environment["AGWEB_UPDATE_FEED"].flatMap(URL.init(string:))
    static let feed = override ?? URL(string: "https://api.github.com/repos/paul-nameless/agweb/releases/latest")!
    static let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

    static func latest() async throws -> Release {
        // Never a cached answer: GitHub's says max-age=60, and a check is a question about now.
        var request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("agweb/\(current)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw Failure("the release feed answered \(http.statusCode): \(feed.absoluteString)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let tag = json["tag_name"] as? String else {
            throw Failure("the release feed has no tag_name: \(feed.absoluteString)")
        }
        let assets = json["assets"] as? [[String: Any]] ?? []
        guard let dmg = assets.first(where: { $0["name"] as? String == "Agweb.dmg" })?["browser_download_url"] as? String,
              let dmgURL = URL(string: dmg, relativeTo: feed)?.absoluteURL else {
            throw Failure("release \(tag) has no Agweb.dmg")
        }
        let page = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? feed
        return Release(version: Version.bare(tag), dmg: dmgURL, page: page, notes: json["body"] as? String ?? "")
    }

    /// Why this copy can't update itself, or nil when it can.
    static func blocker() -> String? {
        if override == nil, developerTeam() == nil {
            return "this Agweb was built from source; update it with git pull and scripts/build.sh"
        }
        let bundle = Bundle.main.bundleURL
        if bundle.path.contains("/AppTranslocation/") || !FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path) {
            return "can't replace \(bundle.path); move Agweb to /Applications, or to ~/Applications if you are not an admin, first"
        }
        return nil
    }

    /// One install at a time: the first to finish restarts Agweb, killing any other mid-way with its image still
    /// mounted. Held after a swap too, since this process then runs on top of the new bundle until it restarts.
    private static let busy = Mutex(false)

    /// Downloads and checks the release, swaps it in for this bundle and returns; the caller restarts.
    static func install(_ release: Release) async throws {
        if let blocker = blocker() { throw Failure(blocker) }
        guard busy.withLock({ held in defer { held = true }; return !held }) else {
            throw Failure("an update is already being installed, or is waiting for Agweb to restart")
        }
        var swapped = false
        defer { if !swapped { busy.withLock { $0 = false } } }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("agweb-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let (download, response) = try await URLSession.shared.download(from: release.dmg)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw Failure("downloading \(release.dmg.absoluteString) answered \(http.statusCode)") }
        let dmg = work.appendingPathComponent("Agweb.dmg")
        try FileManager.default.moveItem(at: download, to: dmg)
        let mount = work.appendingPathComponent("mount")
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        let staged = work.appendingPathComponent("Agweb.app")
        try run("/usr/bin/ditto", [mount.appendingPathComponent("Agweb.app").path, staged.path])
        try verify(staged)
        let version = Bundle(url: staged)?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        guard version == release.version else { throw Failure("the downloaded app is \(version), not \(release.version)") }
        // An atomic swap: the running process keeps its mapped files, and the next launch gets the new bundle.
        _ = try FileManager.default.replaceItemAt(Bundle.main.bundleURL, withItemAt: staged)
        swapped = true
    }

    /// Starts the swapped-in app once this process is gone, in the background as the CLI launches it, on this root.
    static func relaunchAfterExit() throws {
        let passed = ["AGWEB_AWAKE_SECONDS", "AGWEB_HOME", "AGWEB_CLI_LINK", "AGWEB_ADBLOCK_LISTS", "AGWEB_UPDATE_FEED"]
            .compactMap { name in ProcessInfo.processInfo.environment[name].map { "--env \(quoted("\(name)=\($0)"))" } }
        let script = "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open -g -n --env "
            + quoted("AGWEB_ROOT=\(Agweb.root.path)") + " " + passed.joined(separator: " ") + " -a " + quoted(Bundle.main.bundleURL.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    // MARK: Signatures

    /// The team of this app's Developer ID signature, or nil for a local (Apple Development or ad-hoc) build.
    static func developerTeam() -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any], let team = info[kSecCodeInfoTeamIdentifier as String] as? String,
              let leaf = (info[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first,
              let subject = SecCertificateCopySubjectSummary(leaf) as String?, subject.hasPrefix("Developer ID Application") else { return nil }
        return team
    }

    /// The new app must carry this app's identifier and, for a release, a Developer ID signature of the same team.
    static func verify(_ app: URL) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { throw Failure("can't read the downloaded app's signature") }
        var text = "identifier \"\(Agweb.bundleIdentifier)\""
        if let team = developerTeam() {
            text += " and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = \"\(team)\""
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { throw Failure("bad signature requirement") }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        let status = SecStaticCodeCheckValidity(code, flags, requirement)
        guard status == errSecSuccess else {
            throw Failure("the downloaded app's signature doesn't match this one (\(SecCopyErrorMessageString(status, nil) as String? ?? "\(status)")); not installed")
        }
    }

    private static func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure("\(URL(fileURLWithPath: tool).lastPathComponent) failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))") }
        return output
    }
}
