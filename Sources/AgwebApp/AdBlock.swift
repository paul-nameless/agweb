import AgwebCore
import Foundation
import WebKit

/// Blocks ads and trackers with uBlock Origin's default lists, converted to WebKit content rules (FilterConverter).
/// The lists are fetched every 4 days (EasyList's own expiry) and compiled in the background; until the first
/// compile, and when one fails, pages load with the last good rules or none. On by default; the person turns it off
/// for the whole instance in Settings, an agent only for its own workspace (`agweb -w NAME adblock off`).
@MainActor
final class AdBlock {
    static let shared = AdBlock()

    struct Source { let name: String, url: String }

    /// uBlock Origin's defaults, plus RU AdList for the languages uBO enables it for. AGWEB_ADBLOCK_LISTS (comma
    /// separated URLs) replaces them, for the selftest's local list.
    static let sources: [Source] = {
        if let urls = ProcessInfo.processInfo.environment["AGWEB_ADBLOCK_LISTS"], !urls.isEmpty {
            return urls.split(separator: ",").map { Source(name: String($0.split(separator: "/").last ?? $0), url: String($0)) }
        }
        let ubo = "https://ublockorigin.github.io/uAssetsCDN/filters/"
        var sources = [
            Source(name: "EasyList", url: "https://easylist.to/easylist/easylist.txt"),
            Source(name: "EasyPrivacy", url: "https://easylist.to/easylist/easyprivacy.txt"),
            Source(name: "Peter Lowe", url: "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=adblockplus&showintro=0&mimetype=plaintext"),
            Source(name: "uBlock filters", url: ubo + "filters.min.txt"),
            Source(name: "uBlock privacy", url: ubo + "privacy.min.txt"),
            Source(name: "uBlock unbreak", url: ubo + "unbreak.min.txt"),
            Source(name: "uBlock quick fixes", url: ubo + "quick-fixes.min.txt"),
        ]
        let languages = Locale.preferredLanguages.map { String($0.prefix(2)) }
        if languages.contains(where: ["ru", "be", "kk", "tt", "uz"].contains) {
            sources.append(Source(name: "RU AdList", url: "https://cdn.jsdelivr.net/gh/dimisa-RUAdList/RUAdListCDN@main/lists/ruadlist.ubo.min.txt"))
        }
        return sources
    }()

    static let refreshInterval: TimeInterval = 4 * 24 * 3600

    /// What was last compiled, kept next to the lists.
    struct State: Codable {
        var identifiers: [String] = []
        var networkRules = 0
        var hidingRules = 0
        var lists: [String] = []
        var compiled: Date?
        var checked: Date?
        /// Per list URL, for conditional requests.
        var etags: [String: String] = [:]
        var lastModified: [String: String] = [:]
    }

    private let folder = Agweb.root.appendingPathComponent("adblock")
    private lazy var store: WKContentRuleListStore? = {
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("compiled"), withIntermediateDirectories: true)
        return WKContentRuleListStore(url: folder.appendingPathComponent("compiled"))
    }()
    private var state = State()
    private var rules: [WKContentRuleList] = []
    /// Every content controller pages use (a workspace's, a reopened tab's own), with the workspace it belongs to.
    private let controllers = NSMapTable<WKUserContentController, Workspace>.weakToWeakObjects()
    private(set) var updating: Task<Void, Never>?
    /// Finding last time's compiled rules at launch; commands and reopened tabs wait for it.
    private(set) var loading: Task<Void, Never>?
    private var lastError: String?
    private var timer: Timer?

    /// The Settings switch: the person's, for the whole instance.
    var enabled: Bool { Settings.store.bool(forKey: Settings.adBlock) }

    /// Loads what was compiled before, then refreshes when the lists are due.
    func start() {
        if let data = try? Data(contentsOf: folder.appendingPathComponent("state.json")),
           let saved = try? JSONDecoder().decode(State.self, from: data) {
            state = saved
        }
        loading = Task {
            var found: [WKContentRuleList] = []
            for id in state.identifiers {
                guard let list = try? await store?.contentRuleList(forIdentifier: id) else { found = []; break }
                found.append(list)
            }
            if !found.isEmpty { rules = found; apply() }
            loading = nil
            refreshIfDue()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in AdBlock.shared.refreshIfDue() }
        }
    }

    func attach(_ controller: WKUserContentController, to workspace: Workspace) {
        controllers.setObject(workspace, forKey: controller)
        if enabled && !workspace.adBlockOff { rules.forEach(controller.add) }
    }

    /// The Settings switch changed.
    func settingChanged() {
        apply()
        refreshIfDue()
    }

    /// Puts the rules on every controller whose workspace blocks, and takes them off the rest; pages see it from
    /// their next request. Nothing else in agweb uses content rule lists.
    func apply() {
        for controller in controllers.keyEnumerator().allObjects as? [WKUserContentController] ?? [] {
            controller.removeAllContentRuleLists()
            if enabled, controllers.object(forKey: controller)?.adBlockOff == false { rules.forEach(controller.add) }
        }
    }

    func refreshIfDue() {
        guard enabled, updating == nil, loading == nil else { return }
        let due = state.checked.map { Date().timeIntervalSince($0) > Self.refreshInterval } ?? true
        if due || rules.isEmpty { update(force: false) }
    }

    /// Fetches the lists (conditionally) and recompiles when one changed, or always with `force`.
    @discardableResult
    func update(force: Bool) -> Task<Void, Never> {
        if let updating { return updating }
        let task = Task {
            do {
                lastError = try await refresh(force: force)
            } catch {
                lastError = "\(error)"
            }
            updating = nil
        }
        updating = task
        return task
    }

    /// Returns the lists that couldn't be fetched, if any; the rest are compiled without them.
    private func refresh(force: Bool) async throws -> String? {
        guard let store else { throw Failure("cannot open the rule store in \(folder.path)") }
        var changed = force || rules.isEmpty
        var texts: [String] = [], used: [String] = [], failed: [String] = []
        for source in Self.sources {
            let file = folder.appendingPathComponent(Self.fileName(source.url))
            let have = FileManager.default.fileExists(atPath: file.path)
            var request = URLRequest(url: URL(string: source.url)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
            if have, !force {
                if let etag = state.etags[source.url] { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
                if let date = state.lastModified[source.url] { request.setValue(date, forHTTPHeaderField: "If-Modified-Since") }
            }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let http = response as? HTTPURLResponse
                if http?.statusCode == 200, !data.isEmpty {
                    try data.write(to: file, options: .atomic)
                    state.etags[source.url] = http?.value(forHTTPHeaderField: "ETag")
                    state.lastModified[source.url] = http?.value(forHTTPHeaderField: "Last-Modified")
                    changed = true
                } else if http?.statusCode != 304 {
                    failed.append("\(source.name) (HTTP \(http?.statusCode ?? 0))")
                }
            } catch {
                // Offline or the server is down: the copy from last time, if any, still counts.
                failed.append("\(source.name) (\(error.localizedDescription))")
            }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            texts.append(text)
            used.append(source.name)
        }
        state.checked = Date()
        let failure = failed.isEmpty ? nil : "could not fetch " + failed.joined(separator: ", ")
        guard !texts.isEmpty else { save(); throw Failure(failure ?? "no lists") }
        guard changed else { save(); return failure }

        let fetched = texts
        let (network, hiding, jsons) = await Task.detached(priority: .utility) { () -> (Int, Int, [String]) in
            var converter = FilterConverter()
            fetched.forEach { converter.add($0) }
            let lists = converter.lists()
            let encoder = JSONEncoder()
            let jsons = (lists.network + lists.hiding).map { String(decoding: (try? encoder.encode($0)) ?? Data("[]".utf8), as: UTF8.self) }
            return (lists.network.reduce(0) { $0 + $1.count }, lists.hiding.reduce(0) { $0 + $1.count }, jsons)
        }.value

        // New identifiers each time, so the old lists keep working until the new ones are in.
        let stamp = Int(Date().timeIntervalSince1970)
        var compiled: [WKContentRuleList] = [], ids: [String] = []
        for (i, json) in jsons.enumerated() {
            let id = "rules-\(stamp)-\(i)"
            guard let list = try await store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json) else {
                throw Failure("rule list \(id) did not compile")
            }
            compiled.append(list)
            ids.append(id)
        }
        let old = state.identifiers
        rules = compiled
        apply()
        state.identifiers = ids
        state.networkRules = network
        state.hidingRules = hiding
        state.lists = used
        state.compiled = Date()
        save()
        for id in old where !ids.contains(id) { try? await store.removeContentRuleList(forIdentifier: id) }
        return failure
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: folder.appendingPathComponent("state.json"), options: .atomic)
    }

    static func fileName(_ url: String) -> String {
        url.replacingOccurrences(of: "https://", with: "").map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" }
            .map(String.init).joined() + ".txt"
    }

    /// One short line for Settings.
    var summary: String {
        guard enabled else { return "Off" }
        if updating != nil { return rules.isEmpty ? "Fetching lists…" : "Updating…" }
        guard let compiled = state.compiled, !rules.isEmpty else { return lastError == nil ? "No rules yet" : "Couldn't fetch the lists" }
        let count = (state.networkRules + state.hidingRules).formatted(.number.notation(.compactName))
        return "\(count) rules, updated \(compiled.formatted(date: .abbreviated, time: .omitted))" + (lastError == nil ? "" : "; some lists failed")
    }

    /// For `agweb adblock`; `workspace` adds whether that one has it off.
    func status(for workspace: Workspace? = nil) -> String {
        guard enabled else { return "ad blocking off in Settings, for every workspace" }
        var parts: [String] = []
        if let workspace, workspace.adBlockOff {
            parts.append("ad blocking off in workspace \(workspace.name) (agweb -w \(workspace.name) adblock on); on elsewhere")
        } else if let compiled = state.compiled, !rules.isEmpty {
            let date = compiled.formatted(date: .abbreviated, time: .shortened)
            parts.append("ad blocking on: \(state.networkRules.formatted()) network and \(state.hidingRules.formatted()) hiding rules from \(state.lists.joined(separator: ", ")), compiled \(date)")
        } else {
            parts.append("ad blocking on, but no rules yet: pages load unblocked until the lists are fetched")
        }
        if updating != nil { parts.append("updating the lists now") }
        if let lastError { parts.append("last update: \(lastError)") }
        return parts.joined(separator: "; ")
    }
}
