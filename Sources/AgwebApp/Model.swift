import AppKit
import CryptoKit
import Observation
import WebKit
import Network
import AgwebCore

@Observable @MainActor
final class BrowserModel {
    var workspaces: [Workspace] = []
    var displayedTabID: Int?
    var dashboardOpen = false {
        didSet { if dashboardOpen != oldValue { onDashboard?(dashboardOpen) } }
    }
    /// agweb's processes and their usage, sampled while the dashboard is open with Settings ▸ CPU and memory on.
    var processes: [pid_t: (name: String, usage: Usage)] = [:]
    /// The dashboard's clock for "N s ago", advanced with the usage figures every 5 s.
    var dashboardNow = Date()
    @ObservationIgnored var onDashboard: ((Bool) -> Void)?
    /// The tab's id, and whether showing it counts as use (Tab.lastUsed): not a fallback after a close, nor the launch.
    @ObservationIgnored var onDisplay: ((Int, Bool) -> Void)?
    @ObservationIgnored var onCloseTab: ((Tab) -> Void)?
    /// The tab's menu: Mute Tab (false) or Unmute Tab (true).
    @ObservationIgnored var onSound: ((Tab, Bool) -> Void)?
    @ObservationIgnored var onCloseWorkspace: ((Workspace) -> Void)?
    @ObservationIgnored var onNewTab: ((Workspace?) -> Void)?
    /// File ▸ New Workspace: a name and a named profile (nil: fresh); returns why it failed.
    @ObservationIgnored var onNewWorkspace: ((String, String?) -> String?)?

    func display(_ id: Int, used: Bool = true) {
        displayedTabID = id
        onDisplay?(id, used)
    }

    var displayedTab: Tab? {
        workspaces.lazy.flatMap(\.tabs).first { $0.id == self.displayedTabID }
    }
}

/// One agent's tabs, the one it drives, and the profile (website data store) behind them: a named one, or
/// with `profile` nil a fresh one that keeps nothing.
@Observable @MainActor
final class Workspace: Identifiable {
    nonisolated let name: String
    let profile: String?
    var tabs: [Tab] = []
    var currentID: Int?
    /// Basic and Digest logins by origin (`Address.origin`), from `--basic-auth` or the login bar; in memory only. A
    /// refused one is kept for the note but never sent again: each try could count toward the account's lockout.
    @ObservationIgnored var basicAuth: [String: (user: String, password: String, refused: Bool)] = [:]
    /// True while an agent command runs. Commands on one workspace are serialized, so this is exact.
    /// Pages may open windows only meanwhile: WebKit blocks a window.open that follows a fetch after the click
    /// (a deploy button that opens a window after a fetch), and an ad's timer must not hand an idle agent a new tab.
    var busy = false {
        didSet {
            guard busy != oldValue else { return }
            for tab in tabs { tab.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = busy }
            guard !busy else { return }
            let generation = workingGeneration
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                if let self, self.workingGeneration == generation { self.workingTabID = nil }
            }
        }
    }
    /// The tab with the green dot in the sidebar and dashboard: the one the running command acts on (Browser.wake),
    /// held 0.6 s after the command so a run of quick ones reads as one steady dot. Commands that touch no page
    /// (`cookie-list`, `tab-list`) light none.
    private(set) var workingTabID: Int?
    @ObservationIgnored private var workingGeneration = 0
    func working(on tab: Tab) {
        workingGeneration += 1
        if workingTabID != tab.id { workingTabID = tab.id }
    }
    /// What the agent last ran here and when, for the dashboard.
    var lastCommand: String?
    var lastCommandAt: Date?
    /// The newest use of the workspace or any tab in it (Tab.markUsed); saved, for `list`.
    @ObservationIgnored var lastUsed = Date() { didSet { usedClock = RunningClock.now } }
    /// RunningClock at that use: cleanup ages by the time agweb has run since, not by the calendar (Cleanup.swift).
    @ObservationIgnored var usedClock = RunningClock.now
    @ObservationIgnored var acceptDialogs = false
    /// Where downloads nobody named go: the last command's `--download-dir`, by default its caller's `.agweb/`.
    @ObservationIgnored var downloadDir: URL?
    /// The tab ids and current tab the agent last saw in a reply, so unchanged tabs aren't listed again.
    @ObservationIgnored var tabsShown: [Int] = []
    /// The running command's reply is printed --raw, without the tab list.
    @ObservationIgnored var rawReply = false
    /// The highest ref any of the workspace's pages handed out, so every page, a popup's included, numbers on from
    /// it (see PageScripts.find).
    @ObservationIgnored var refSeed = 0
    /// Set when the running command woke a tab, so its current tab is kept awake after it.
    @ObservationIgnored var actedOn: Tab?
    /// What `dialog-accept <text>` answers prompt() with; nil answers with the prompt's default.
    @ObservationIgnored var promptText: String?
    @ObservationIgnored var recorder: Recorder?
    /// `agweb -w NAME adblock off`: this workspace loads everything until it turns it back on; kept across restarts.
    @ObservationIgnored var adBlockOff = false
    /// `agweb -w NAME unload off`: its tabs keep their pages however long they sit unused, and its current tab keeps
    /// running unseen (Visibility.swift); kept across restarts.
    @ObservationIgnored var unloadOff = false
    /// `agweb -w NAME sound on`: its tabs are heard while hidden too (music behind other tabs or the dashboard); an
    /// agent's tabs are otherwise muted while hidden. Kept across restarts.
    @ObservationIgnored var soundOn = false
    /// What the agent's pages copied, or `clipboard-set` gave; never the person's clipboard (ClipboardRouting.swift).
    @ObservationIgnored var clipboard: Clip?
    @ObservationIgnored let dataStore: WKWebsiteDataStore
    @ObservationIgnored let contentController = WKUserContentController()
    @ObservationIgnored var routes: [Route] = [] { didSet { installScripts() } }
    /// localStorage from `state-load` by origin, set when the origin next loads.
    @ObservationIgnored var pendingStorage: [String: [[String]]] = [:] { didSet { installScripts() } }
    /// `agweb media`: the "camera" and "mic" files getUserMedia answers with (FakeDevices), copies under the root.
    @ObservationIgnored var media: [String: FakeDevices.Source] = [:] { didSet { if media.isEmpty != oldValue.isEmpty { installScripts() } } }
    /// `agweb geolocation`: the position navigator.geolocation answers with (FakeDevices).
    @ObservationIgnored var geolocation: Geolocation? { didSet { if (geolocation == nil) != (oldValue == nil) { installScripts() } } }
    /// Fake devices' ids are hashed with it: the same for a named profile, as Safari keeps them per site.
    @ObservationIgnored lazy var deviceSalt = profile ?? UUID().uuidString
    /// The controllers that have the agwebDevices handler now (weak: a closed tab's controller leaves by itself).
    @ObservationIgnored let devicesHandlers = NSHashTable<WKUserContentController>.weakObjects()

    nonisolated var id: String { name }
    var current: Tab? { tabs.first { $0.id == currentID } }

    struct Route: Codable {
        var pattern: String
        var status: Int?
        var body: String?
        var contentType: String?
        var headers: [String: String] = [:]
    }

    /// Finishes the recording, if any, and describes the file.
    func stopRecording() async throws -> String? {
        guard let recorder else { return nil }
        self.recorder = nil
        return try await recorder.stop()
    }

    @ObservationIgnored let console: ConsoleSink
    /// A fresh workspace's passkeys, gone with it; a named profile's are in the Keychain (Passkeys).
    @ObservationIgnored let passkeys = MemoryPasskeyStore()
    /// The command running (or last run) acts on the page, so its page may use passkeys (Passkeys.commands).
    @ObservationIgnored var passkeyCommand = false

    init(name: String, profile: String?, console: ConsoleSink) {
        self.name = name
        self.profile = profile
        self.console = console
        dataStore = Profiles.store(profile)
        // One controller per workspace: popups get a copy of the opener's configuration, and registering
        // a message handler twice on a shared controller throws.
        Self.addHandlers(console, to: contentController)
        AdBlock.shared.attach(contentController, to: self)
        installScripts()
    }

    /// The fake devices' page script, when the workspace fakes any.
    var devicesShim: String? {
        media.isEmpty && geolocation == nil ? nil : PageScripts.devicesShim(media: !media.isEmpty, geolocation: geolocation != nil)
    }

    /// Pages see window.webkit.messageHandlers.agwebDevices only in a workspace that fakes a device.
    /// Changed only when that changes: removing a handler invalidates the object live pages hold.
    private func syncDevicesHandler(_ controller: WKUserContentController) {
        let wanted = devicesShim != nil
        guard wanted != devicesHandlers.contains(controller) else { return }
        if wanted {
            controller.addScriptMessageHandler(FakeDevices.shared, contentWorld: .page, name: FakeDevices.handlerName)
            devicesHandlers.add(controller)
        } else {
            controller.removeScriptMessageHandler(forName: FakeDevices.handlerName, contentWorld: .page)
            devicesHandlers.remove(controller)
        }
    }

    static func addHandlers(_ sink: ConsoleSink, to controller: WKUserContentController) {
        for handler in ["agwebConsole", "agwebPage"] { controller.add(sink, name: handler) }
        controller.addScriptMessageHandler(sink, contentWorld: .page, name: "agwebClipboard")
        controller.addScriptMessageHandler(Passkeys.shared, contentWorld: .page, name: Passkeys.handlerName)
    }

    /// User scripts apply to the next load; live pages get the new routes directly. A reopened tab with saved
    /// sessionStorage has a controller of its own, carrying the same scripts plus its own values.
    func installScripts() {
        let routesJSON = String(decoding: (try? JSONEncoder().encode(routes)) ?? Data("[]".utf8), as: UTF8.self)
        let setRoutes = "window.__agwebRoutes = \(routesJSON);"
        var scripts = [WKUserScript(source: PageScripts.consoleHook, injectionTime: .atDocumentStart, forMainFrameOnly: false),
                       WKUserScript(source: setRoutes + PageScripts.networkHook, injectionTime: .atDocumentStart, forMainFrameOnly: false),
                       WKUserScript(source: PageScripts.clipboardHook, injectionTime: .atDocumentStart, forMainFrameOnly: false)]
        if Passkeys.shared.enabled {
            scripts.append(WKUserScript(source: PageScripts.passkeyShim, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        }
        if let shim = devicesShim {
            scripts.append(WKUserScript(source: shim, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        }
        if !pendingStorage.isEmpty, let json = try? JSONEncoder().encode(pendingStorage) {
            scripts.append(WKUserScript(source: PageScripts.pendingStorage(String(decoding: json, as: UTF8.self)),
                                        injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        contentController.removeAllUserScripts()
        syncDevicesHandler(contentController)
        scripts.forEach(contentController.addUserScript)
        for tab in tabs {
            guard let own = tab.ownController else { continue }
            own.removeAllUserScripts()
            syncDevicesHandler(own)
            scripts.forEach(own.addUserScript)
            if !tab.pendingSeeds.isEmpty, let json = try? JSONEncoder().encode(tab.pendingSeeds) {
                own.addUserScript(WKUserScript(source: PageScripts.seedSession(String(decoding: json, as: UTF8.self)),
                                               injectionTime: .atDocumentStart, forMainFrameOnly: true))
            }
        }
        // A tab not loaded yet gets them from the user script; running a script would start its web process.
        for tab in tabs where tab.pendingURL == nil && !tab.unloaded { tab.webView.evaluateJavaScript(setRoutes) }
    }

    /// `lazy`: no web process until the first load, for a reopened tab whose page loads only when used. Not for a tab
    /// that may never load (a blank one), which scripts must still reach.
    /// `ownController`: a controller of the tab's own, for a reopened tab whose saved sessionStorage only it may get.
    func makeConfiguration(lazy: Bool = false, ownController: Bool = false) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        let delay = NSSelectorFromString("_setDelaysWebProcessLaunchUntilFirstLoad:")
        if lazy, config.responds(to: delay) {
            typealias SetBool = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(config.method(for: delay), to: SetBool.self)(config, delay, true)
        }
        config.websiteDataStore = dataStore
        if ownController {
            let own = WKUserContentController()
            Self.addHandlers(console, to: own)
            syncDevicesHandler(own)
            AdBlock.shared.attach(own, to: self)
            config.userContentController = own
        } else {
            config.userContentController = contentController
        }
        // On only while a command runs; see Workspace.busy.
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        // Only hidden tabs are affected (see Visibility.swift): after about 4 minutes hidden WebKit frees their memory
        // and suspends the process; any command wakes it in milliseconds.
        config.preferences.inactiveSchedulingPolicy = .suspend
        // A page reading the clipboard (navigator.clipboard.read*) would pop up WebKit's Paste menu at the real
        // pointer; with requests off the read fails at once with NotAllowedError. Private feature flag.
        let setFeature = NSSelectorFromString("_setEnabled:forFeature:")
        if let paste = Self.pasteRequests, config.preferences.responds(to: setFeature) {
            typealias SetFeature = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
            unsafeBitCast(config.preferences.method(for: setFeature), to: SetFeature.self)(config.preferences, setFeature, false, paste)
        }
        // Without a Safari token Google sign-in and bot checks treat the browser as unknown.
        config.applicationNameForUserAgent = "Version/\(Self.safariVersion) Safari/605.1.15"
        return config
    }

    private static let pasteRequests: AnyObject? = {
        let list = NSSelectorFromString("_features")
        guard (WKPreferences.self as AnyObject).responds(to: list),
              let features = (WKPreferences.self as AnyObject).perform(list)?.takeUnretainedValue() as? [NSObject]
        else { return nil }
        return features.first { $0.responds(to: NSSelectorFromString("key"))
            && ($0.value(forKey: "key") as? String) == "DOMPasteAccessRequestsEnabled" }
    }()

    private static let safariVersion: String = {
        let plist = NSDictionary(contentsOfFile: "/Applications/Safari.app/Contents/Info.plist")
        return plist?["CFBundleShortVersionString"] as? String ?? "18.0"
    }()

}

/// Named profiles: persistent website data stores shared by every workspace naming them. WebKit keys a store
/// by a UUID that can't be turned back into the name, so the names live in a file of their own.
@MainActor
enum Profiles {
    private static let file = Agweb.profilesFolder.appendingPathComponent("profiles.json")
    private static var stores: [String: WKWebsiteDataStore] = [:]

    static var names: [String] { readNames() ?? [] }
    private static func readNames() -> [String]? { try? JSONDecoder().decode([String].self, from: Data(contentsOf: file)) }

    static func store(_ name: String?) -> WKWebsiteDataStore {
        guard let name else { return .nonPersistent() }
        holdInUse(name)
        if let store = stores[name] { return store }
        // Registered first: another instance's launch sweep removes folders of names it can't find.
        if !names.contains(name) { locked { _ = update { $0.contains(name) ? $0 : $0 + [name] } } }
        let store = makeStore(name)
        stores[name] = store
        // A store remade after a delete in this run keeps the route the first one had (see `live`).
        let route = live[name] ?? savedRoute(name)
        live[name] = route
        switch route {
        case .direct: break
        case .proxy(let spec): store.proxyConfigurations = [configuration(spec)]
        // Nothing reaches the internet; Tab.load refuses too, for what skips proxies (loopback, link-local).
        case .unreadable: store.proxyConfigurations = [ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: 9))]
        }
        return store
    }

    // MARK: Proxies

    enum Route: Equatable {
        case direct, proxy(ProxySpec), unreadable
    }

    private static let proxiesFile = Agweb.profilesFolder.appendingPathComponent("proxies.json")
    /// The route each profile's store got when first made in this run, kept after a delete. WebKit keeps a store's
    /// connections, tunnels through the old proxy included, after its proxy changes and after its workspaces close, so
    /// a proxy changed in a run waits for the next start; new workspaces on that profile are refused meanwhile.
    private static var live: [String: Route] = [:]

    static func savedRoute(_ name: String) -> Route {
        guard FileManager.default.fileExists(atPath: proxiesFile.path) else { return .direct }
        guard let data = try? Data(contentsOf: proxiesFile), let entries = ProxyRegistry.entries(data) else { return .unreadable }
        switch entries[name] {
        case nil: return .direct
        case .proxy(let spec)?: return .proxy(spec)
        case .unreadable?: return .unreadable
        }
    }

    private static var proxiesFileReadable: Bool {
        guard FileManager.default.fileExists(atPath: proxiesFile.path) else { return true }
        return (try? Data(contentsOf: proxiesFile)).flatMap(ProxyRegistry.entries) != nil
    }

    /// Network.framework's: failover stays off, so a proxy that is down or refuses fails the load instead of going direct.
    private static func configuration(_ spec: ProxySpec) -> ProxyConfiguration {
        let endpoint = NWEndpoint.hostPort(host: .init(spec.host), port: .init(integerLiteral: UInt16(spec.port)))
        let config = switch spec.kind {
        case .socks5: ProxyConfiguration(socksv5Proxy: endpoint)
        case .http: ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: nil)
        case .https: ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: NWProtocolTLS.Options())
        }
        if let username = spec.username, let password = spec.password { config.applyCredential(username: username, password: password) }
        return config
    }

    /// Why a profile's pages may not load at all: its proxy can't be read.
    static func refusal(_ name: String?) -> String? {
        guard let name, live[name] == .unreadable else { return nil }
        if savedRoute(name) != .unreadable {
            return "profile \(name)'s proxy couldn't be read when it was opened in this run, so it loads nothing until agweb next starts"
        }
        return proxiesFileReadable ? "profile \(name) has an unreadable proxy in profiles/proxies.json; fix it or agweb profile set \(name) proxy off"
            : ProxyRegistry.unreadableFile
    }

    /// Whether the profile's pages go through a proxy in this run.
    static func proxied(_ name: String?) -> Bool {
        guard let name, case .proxy? = live[name] else { return false }
        return true
    }

    /// Why no new workspace may start on the profile: its saved proxy isn't the one its store has in this run.
    static func pending(_ name: String) -> String? {
        guard let route = live[name], route != savedRoute(name) else { return nil }
        return "profile \(name)'s proxy changed after it was opened in this run and applies when agweb next starts (the person "
            + "restarts it); until then it keeps \(describe(route)), so new workspaces on it are refused. Use another profile meanwhile"
    }

    /// For a failed load's error: the route the profile's pages take.
    static func routeNote(_ name: String) -> String? {
        guard let route = live[name] else { return nil }
        let pendingNote = route != savedRoute(name) ? "; the proxy saved since applies when agweb next starts" : ""
        switch route {
        case .direct: return pendingNote.isEmpty ? nil : "profile \(name) has no proxy in this run" + pendingNote
        case .proxy(let spec): return "profile \(name) goes through proxy \(spec)" + pendingNote
        case .unreadable: return refusal(name)
        }
    }

    private static func describe(_ route: Route) -> String {
        switch route {
        case .direct: "loading direct"
        case .proxy(let spec): "going through \(spec)"
        case .unreadable: "loading nothing"
        }
    }

    /// `profile list`'s note: the saved proxy, and the route this run keeps when they differ.
    static func proxyNote(_ name: String) -> String? {
        let saved = savedRoute(name)
        var note: String? = switch saved {
        case .direct: nil
        case .proxy(let spec): "proxy \(spec)" + (spec.password == nil ? "" : ", password saved")
        case .unreadable: proxiesFileReadable ? "proxy unreadable in profiles/proxies.json, so it loads nothing" : "profiles/proxies.json unreadable, so it loads nothing"
        }
        if let route = live[name], route != saved {
            note = (note ?? "no proxy") + " from agweb's next start; now \(describe(route))"
        }
        return note
    }

    /// Saves the profile's proxy (nil: none), registering a new name. When the profile was opened in this run, the
    /// change waits for the next start: then the route it keeps meanwhile.
    static func setProxy(_ name: String, _ spec: ProxySpec?) throws -> String? {
        try locked {
            let data = FileManager.default.fileExists(atPath: proxiesFile.path) ? try Data(contentsOf: proxiesFile) : nil
            // The proxy first: a name registered without it would load direct.
            try writePrivately(try ProxyRegistry.setting(name, to: spec, in: data), to: proxiesFile)
            guard update({ $0.contains(name) ? $0 : $0 + [name] }) else {
                throw Failure("profiles/profiles.json can't be read, so \(name) isn't registered; its proxy is saved")
            }
        }
        guard let route = live[name], route != savedRoute(name) else { return nil }
        return describe(route)
    }

    /// The person's instance keeps WebKit's own place for named stores. Any other root keeps them in its folder, so
    /// a test instance can't see, change or sweep the person's logins. WebKit's public API can't place a store, so
    /// that takes its SPI; without it a test instance stops rather than put stores where nobody sweeps them.
    private static func makeStore(_ name: String) -> WKWebsiteDataStore {
        if Agweb.isDefaultRoot { return WKWebsiteDataStore(forIdentifier: identifier(name)) }
        let folder = webKitFolder.appendingPathComponent(identifier(name).uuidString)
        let initDirectory = NSSelectorFromString("initWithDirectory:"), initStore = NSSelectorFromString("_initWithConfiguration:")
        let alloc = NSSelectorFromString("alloc")
        // macOS 26's WebKit has only -_initWithConfiguration:, not +_storeWithConfiguration:. init consumes the
        // allocation and returns a retained object.
        if let configuration = NSClassFromString("_WKWebsiteDataStoreConfiguration") as? NSObject.Type,
           configuration.instancesRespond(to: initDirectory), WKWebsiteDataStore.instancesRespond(to: initStore),
           let config = (configuration as AnyObject).perform(alloc)?.takeUnretainedValue()
               .perform(initDirectory, with: folder as NSURL)?.takeRetainedValue(),
           let store = (WKWebsiteDataStore.self as AnyObject).perform(alloc)?.takeUnretainedValue()
               .perform(initStore, with: config)?.takeRetainedValue() as? WKWebsiteDataStore {
            return store
        }
        fatalError("this WebKit has no _WKWebsiteDataStoreConfiguration; a profile on AGWEB_ROOT \(Agweb.root.path) can't be kept in it")
    }

    private static var webKitFolder: URL {
        Agweb.isDefaultRoot
            ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/WebKit/\(Agweb.bundleIdentifier)/WebsiteDataStore")
            : Agweb.root.appendingPathComponent("webkit")
    }

    static func delete(_ name: String) async throws {
        guard names.contains(name) else { throw Failure("no profile \(name); see agweb profile list") }
        if let fd = inUse.removeValue(forKey: name) { close(fd) }
        let probe = open(inUseFile(name).path, O_CREAT | O_RDWR, 0o600)
        defer { if probe >= 0 { close(probe) } }
        guard probe < 0 || flock(probe, LOCK_EX | LOCK_NB) == 0 else {
            if stores[name] != nil { holdInUse(name) }
            throw Failure("profile \(name) is open in another agweb instance; quit it or close its workspaces first")
        }
        // WebKit refuses to remove a store it still holds, which it does for a while after the store's last tab
        // closes, and crashes removing one before any web view exists. Wiping its data works in both cases.
        // First: what the person made stays theirs, and passkeys left in the Keychain would pass to a profile made later
        // with this name.
        try await MainActor.run {
            let mine = try Passkeys.shared.personMade(profile: name)
            guard mine.isEmpty else {
                throw Failure("profile \(name) holds passkeys the person made (\(mine.joined(separator: ", "))); they delete those in Settings ▸ Passkeys first")
            }
            try Passkeys.shared.forget(profile: name)
        }
        let store = stores.removeValue(forKey: name) ?? makeStore(name)
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        if Agweb.isDefaultRoot { try? await WKWebsiteDataStore.remove(forIdentifier: identifier(name)) }
        restoring[name] = nil
        try? FileManager.default.removeItem(at: sessionCookies(name))
        try? FileManager.default.removeItem(at: inUseFile(name))
        locked {
            _ = update { $0.filter { $0 != name } }
            // An unreadable file stays as it is; it already keeps every profile from loading.
            if let data = try? Data(contentsOf: proxiesFile), let without = try? ProxyRegistry.setting(name, to: nil, in: data) {
                try? writePrivately(without, to: proxiesFile)
            }
        }
    }

    // Cookies without an expiry die with the app in every browser that doesn't restore sessions, and SSO logins
    // live in them. They're saved per named profile as pages change and on quit, and put back before the profile's
    // first page loads in a run. A profile whose saved cookies were never put back is not saved: its store holds
    // none yet, and saving would wipe the logins.

    /// One per profile per run; a second load of the profile waits for the first one's restore to finish.
    private static var restoring: [String: Task<Bool, Never>] = [:]

    /// At launch, before any store exists: the folders of deleted profiles, which WebKit keeps while it still holds the
    /// store (with databases listing the sites visited). Removing them under a live store would lose a profile
    /// recreated under the same name in that run.
    static func sweepDeletedStores() {
        // No readable registry, no sweep: a missing, moved or damaged file must not read as "every profile was deleted".
        guard let names = readNames() else { return }
        let folder = webKitFolder
        let known = Set(names.map { identifier($0).uuidString.lowercased() })
        for id in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where !known.contains(id.lowercased()) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(id))
        }
    }

    static func saveSessionCookies() async {
        for (name, store) in stores {
            // Mid-restore, the store holds only part of the saved cookies.
            guard let restore = restoring[name], await restore.value else { continue }
            guard let all = try? await withTimeout(5, "reading cookies", { await store.httpCookieStore.allCookies() }),
                  stores[name] === store else { continue } // deleted meanwhile
            let cookies = all.filter(\.isSessionOnly)
            let list = cookies.compactMap { $0.properties.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.key.rawValue, $0.value) }) } }
            guard let data = try? PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0) else { continue }
            let file = sessionCookies(name)
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600])
        }
    }

    /// A restore the cookie store didn't answer (no web view in this process yet) is forgotten, so no save writes
    /// the partial set over the file and the next load tries again.
    static func restoreSessionCookies(_ name: String) async {
        if let task = restoring[name] { return _ = await task.value }
        guard let store = stores[name] else { return }
        let file = sessionCookies(name)
        let task = Task { () -> Bool in
            guard let data = try? Data(contentsOf: file),
                  let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] else { return true }
            for properties in list {
                let keyed = Dictionary(uniqueKeysWithValues: properties.map { (HTTPCookiePropertyKey($0.key), $0.value) })
                guard let cookie = HTTPCookie(properties: keyed) else { continue }
                guard (try? await withTimeout(2, "restoring a cookie", { await store.httpCookieStore.setCookie(cookie) })) != nil else { return false }
            }
            return true
        }
        restoring[name] = task
        if await !task.value, restoring[name] == task { restoring[name] = nil }
    }

    // Every instance holding a profile's store keeps a shared lock on its file, so another instance on the same root
    // can't delete a profile one has open.
    private static var inUse: [String: Int32] = [:]

    private static func holdInUse(_ name: String) {
        guard inUse[name] == nil else { return }
        let file = inUseFile(name)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(file.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return }
        // Blocking: another instance's delete holds the lock only while it wipes the folder.
        if flock(fd, LOCK_SH) == 0 { inUse[name] = fd } else { close(fd) }
    }

    /// When no workspace uses the profile any more, so another instance may delete it.
    static func release(_ name: String) {
        if let fd = inUse.removeValue(forKey: name) { close(fd) }
    }

    private static func inUseFile(_ name: String) -> URL {
        Agweb.profilesFolder.appendingPathComponent("locks/\(identifier(name)).lock")
    }

    private static func sessionCookies(_ name: String) -> URL {
        Agweb.profilesFolder.appendingPathComponent("session-cookies/\(identifier(name)).plist")
    }

    /// Stable forever: changing it would orphan every saved login.
    private static func identifier(_ name: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data("agweb.profile.\(name)".utf8)).prefix(16))
        return digest.withUnsafeBufferPointer { NSUUID(uuidBytes: $0.baseAddress!) as UUID }
    }

    /// Two read-modify-writes at once, from this instance or another on the root, would lose a name or a proxy.
    private static func locked<T>(_ body: () throws -> T) rethrows -> T {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lock = open(file.path + ".lock", O_CREAT | O_RDWR, 0o600)
        defer { if lock >= 0 { close(lock) } }
        if lock >= 0 { flock(lock, LOCK_EX) }
        return try body()
    }

    /// Inside `locked`. False, writing nothing, when the file exists but can't be read: rewriting it from no names would
    /// leave only the one being added, and the next launch would sweep every other profile's data.
    private static func update(_ change: ([String]) -> [String]) -> Bool {
        let current = FileManager.default.fileExists(atPath: file.path) ? readNames() : []
        guard let current, let data = try? JSONEncoder().encode(change(current).sorted()) else { return false }
        return (try? writePrivately(data, to: file)) != nil
    }

    /// Created 0600 before anything is written (proxies.json holds passwords), then renamed over the file.
    private static func writePrivately(_ data: Data, to url: URL) throws {
        let temporary = url.path + ".tmp"
        unlink(temporary)
        let fd = open(temporary, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard fd >= 0 else { throw Failure("cannot write \(url.lastPathComponent)") }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        close(fd)
        guard written == data.count, rename(temporary, url.path) == 0 else {
            unlink(temporary)
            throw Failure("cannot write \(url.lastPathComponent)")
        }
    }
}

@Observable @MainActor
final class Tab: NSObject, Identifiable, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    static let agentWorld = WKContentWorld.world(name: "agweb")

    nonisolated let id: Int
    var title = ""
    /// The dashboard's picture of the tab, and when an agent last acted on it (its place there).
    var thumbnail: NSImage?
    /// The picture was taken mid-load: a full one replaces it once the load finishes.
    @ObservationIgnored var thumbnailWhileLoading = false
    /// The picture's file in Browser.thumbnailsFolder, kept across launches.
    @ObservationIgnored var thumbnailName = UUID().uuidString
    @ObservationIgnored var thumbnailTask: Task<Void, Never>?
    /// Pictures after an agent's command, apart from those after a load: neither cancels the other.
    @ObservationIgnored var commandPictures: Task<Void, Never>?
    @ObservationIgnored var thumbnailAt = Date.distantPast
    /// What the agent asked the person to do here (`ask`), while it waits.
    var asking: String?
    var url = ""
    /// Strong on purpose: a closed tab can still get page callbacks, and closeTab breaks the cycle.
    @ObservationIgnored let workspace: Workspace
    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored weak var browser: Browser?
    @ObservationIgnored weak var opener: Tab?
    @ObservationIgnored var console: [String] = []
    /// The last snapshot of each target ("" for the page) and the document it came from, for `snapshot --diff`
    /// and `### Changes`.
    @ObservationIgnored var snapshots: [String: (doc: String, tree: String)] = [:]
    /// Console errors since the last reply, for the hint under ### Page.
    @ObservationIgnored var unreadErrors = 0
    /// Console lines ever appended, so a command can tell which came in during it.
    @ObservationIgnored var consoleTotal = 0

    /// WebKit posts "pageerror: Script error. (at :0)" for an eval that doesn't parse, before its reply: take out the
    /// one that came in since `since` (a `consoleTotal`), so it doesn't read as the page's.
    func forgetEvalError(since: Int) {
        if let index = console.suffix(min(consoleTotal - since, console.count)).lastIndex(of: "pageerror: Script error. (at :0)") {
            console.remove(at: index)
            unreadErrors = max(0, unreadErrors - 1)
        }
    }
    /// Documents, fetch and XHR calls since the page loaded: the hook's messages, as dictionaries.
    @ObservationIgnored var requests: [[String: Any]] = []
    /// What the ad blocker stopped since the page loaded, by URL; `requests` marks these.
    @ObservationIgnored var blocked: [String] = []
    /// The address whose response said `cf-mitigated: challenge`: a Cloudflare challenge page. By address, since a page
    /// restored by back or forward gets no response to clear or set it.
    @ObservationIgnored var challengedURL: URL?
    var challenged: Bool { challengedURL != nil && webView.url == challengedURL }
    /// A 401 asking for a Basic or Digest login, by address like `challengedURL`.
    struct AuthWall { let url: URL, origin: String, scheme: String, realm: String }
    @ObservationIgnored var authWallSeen: AuthWall?
    var authWall: AuthWall? { authWallSeen.flatMap { $0.url == webView.url ? $0 : nil } }
    @ObservationIgnored var events: [String] = []
    /// The page has asked for the fake position (an event says so once, not on every poll of a watch).
    @ObservationIgnored var geolocationAsked = false
    /// getUserMedia calls whose fake tracks are live; the tab stays awake meanwhile (Visibility.swift).
    @ObservationIgnored var liveCaptures = 0
    /// What setMuted last set; observed for the Mute/Unmute item in the tab's menu.
    private(set) var isMuted = false
    /// The person's Mute Tab (false) or Unmute Tab (true, heard even hidden) from the tab's menu, over the
    /// workspace's rule; nil follows it. For this run only.
    var personSound: Bool?
    /// The cross-origin frame each snapshot ref inside one lives in; a ref missing here is in the page itself.
    @ObservationIgnored var frameRefs: [String: Frame] = [:]
    /// When the agent's last command here ended plus the grace, and the person's last click or key in the page while
    /// it was shown: the only times a page may use passkeys (Passkeys.prepare). Kept across a load, unlike
    /// personInputAt: a sign-in button often opens the page that asks.
    @ObservationIgnored var agentUntil = Date.distantPast
    @ObservationIgnored var passkeyInputAt = Date.distantPast
    /// The last passkey ceremony answered here, which `settle` waits past for the call that sends it to the site.
    @ObservationIgnored var passkeyAt = Date.distantPast
    /// What each ref shown on this page was (`button "Close"`), so an error about a ref gone since can name it.
    @ObservationIgnored var refLabels: [String: String] = [:]
    /// Where the tab was when the last command here ended. A different history entry at the next command, or a new
    /// document at another URL in the same entry (`location.replace`), means something else moved the tab: a click in
    /// the window, the page itself. A URL change inside the page (`replaceState`) doesn't count: apps do it all the time.
    @ObservationIgnored private var seen: (entry: WKBackForwardListItem?, commits: Int, url: URL?)?
    @ObservationIgnored private(set) var commits = 0
    func markSeen() { seen = (webView.backForwardList.currentItem, commits, webView.url) }
    var movedSinceSeen: Bool {
        guard let seen, let entry = webView.backForwardList.currentItem else { return false }
        return entry !== seen.entry || (commits != seen.commits && webView.url != seen.url)
    }
    /// Keys and a button the agent is holding down (keydown, mousedown).
    @ObservationIgnored var held = NativeInput.Held()
    /// A rich editor's caret was saved after the agent's last key here, and nothing else ran on the tab since
    /// (Browser.takeKeyboard).
    @ObservationIgnored var caretKept = false
    /// A fixed viewport from `resize`, in CSS pixels; nil fills the window.
    @ObservationIgnored var viewportSize: CGSize?
    /// `emulate --device iphone`: the user agent, and the viewport `--device off` puts back. Tabs it opens inherit it.
    @ObservationIgnored var phone: (userAgent: String, viewportBefore: CGSize?)?
    /// While true, a context menu the page asks for is dropped: it would pop up on the person's screen.
    @ObservationIgnored var suppressMenus = false
    /// Where the next download goes; nil is the workspace's download folder.
    /// A tab reopened at launch: where it was, loaded on first use.
    @ObservationIgnored var pendingURL: URL?
    /// Its web content process was ended after it sat idle (Unload.swift); the next use reloads it.
    @ObservationIgnored var unloaded = false
    /// The process was killed and WebKit hasn't reported its end yet: a load started meanwhile would die with it.
    @ObservationIgnored var awaitingExit = false
    /// The page is a POST's result, which a reload would send again (an unloaded one comes back by its address
    /// instead); and the method of the main-frame load under way.
    @ObservationIgnored private(set) var postedPage = false
    @ObservationIgnored private var loadingMethod: String?
    var downloading: Bool { !downloads.isEmpty }
    @ObservationIgnored var downloadPath: URL?
    @ObservationIgnored var downloadsStarted = 0
    /// Main-frame loads WebKit was told to download (an attachment, a type it can't show; it then stops the load); the
    /// downloads they became, numbered as WebKit hands them over (sometimes just after it reports the load stopped),
    /// the number of each one under way, and how each ended: its saved path, or why it failed. Numbers, as a finished
    /// download's object identifier can come back for the next one.
    @ObservationIgnored var pageDownloads = 0
    @ObservationIgnored var pageDownloadsStarted = 0
    @ObservationIgnored private var pageDownloadNumbers: [ObjectIdentifier: Int] = [:]
    @ObservationIgnored var pageDownloadResults: [Int: Result<String, Failure>] = [:]
    /// `commits` when the agent's snapshot of the whole page (`snapshots[""]`) was taken, the baseline of an action's Changes.
    @ObservationIgnored var baselineCommits = 0
    /// `commits` as the agent's last goto, reload, go-back or go-forward in this tab ended.
    @ObservationIgnored var navigatedCommits = -1
    /// Saved paths, or why a download failed, in the order they ended.
    @ObservationIgnored var downloadsEnded: [Result<String, Failure>] = []
    /// Where each download is written, and the file it replaces once it finishes (`download --filename`).
    @ObservationIgnored private var downloads: [ObjectIdentifier: (url: URL, replaces: URL?)] = [:]
    @ObservationIgnored var pendingUpload: [URL]?
    @ObservationIgnored var chooserOpened = false
    /// Where the agent's pointer last went, in CSS pixels of the viewport; nil until the first move.
    @ObservationIgnored var pointer: CGPoint?
    @ObservationIgnored var motion = Motion()
    /// For the click ring in recordings.
    @ObservationIgnored var lastClick: (point: CGPoint, time: Double)?
    @ObservationIgnored private var loadWaiter: CheckedContinuation<Void, Error>?
    @ObservationIgnored private var initialLoad: Task<Void, Error>?
    @ObservationIgnored private var loadGeneration = 0
    /// `closePage` ran: WebKit fails a script still waiting on the page with an unrelated error.
    @ObservationIgnored private(set) var closed = false
    /// The navigation `load` started; another one ending (the page it replaced) doesn't end the wait.
    @ObservationIgnored private var expected: WKNavigation?
    @ObservationIgnored private var loadTimeout: Task<Void, Never>?
    @ObservationIgnored private var lastCrash: Double?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    init(id: Int, workspace: Workspace, configuration: WKWebViewConfiguration, browser: Browser, opener: Tab?) {
        self.id = id
        self.workspace = workspace
        self.browser = browser
        self.opener = opener
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isInspectable = true
        // WebKit treats every tab as hidden when the window is covered, which pauses rendering, rAF and
        // snapshots for agents. Private API, so only when it exists.
        // KVC can't reach it: the setter is _setWindowOcclusionDetectionEnabled:, not set_window….
        let setter = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        if webView.responds(to: setter) {
            typealias SetBool = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(webView.method(for: setter), to: SetBool.self)(webView, setter, false)
        }
        // KVO catches what navigation callbacks miss: late titles and pushState URL changes.
        observations = [
            webView.observe(\.title) { [weak self] webView, _ in
                // An unloaded tab's web view forgets its title; the sidebar keeps showing the page's.
                Task { @MainActor in if self?.unloaded == false { self?.title = webView.title ?? "" } }
            },
            webView.observe(\.url) { [weak self] webView, _ in
                Task { @MainActor in
                    guard let self, let url = webView.url else { return }
                    self.url = url.absoluteString
                    self.browser?.scheduleSave()
                }
            },
        ]
    }

    // MARK: Loading

    var currentURL: String { webView.url?.absoluteString ?? (url.isEmpty ? "about:blank" : url) }
    var currentTitle: String { webView.title.flatMap { $0.isEmpty ? nil : $0 } ?? title }

    /// Loads a reopened tab's page, or waits for the load already under way: the window starts one for the tab it
    /// shows, and a command arriving meanwhile must not act on about:blank.
    func loadIfPending() async throws {
        if unloaded {
            unloaded = false
            let posted = postedPage
            events.append("the tab was unloaded to free memory after it sat unused, and reloaded now: what the page held only in memory (typed text, scroll position, an app's state) is gone"
                + (posted ? "; it showed a form's result, so it was opened by its address instead, without sending the form again" : ""))
            let address = URL(string: url)
            let generation = loadGeneration
            initialLoad = Task {
                await self.endOfUnload()
                // A goto or a close meanwhile: their load wins, and a closed tab's detached view must not load.
                guard generation == self.loadGeneration else { return }
                do {
                    // The web view still has the entry, so history survives; without one, the saved address. A reload
                    // of a POST's result would send the form again.
                    if !posted, let navigation = self.webView.reload() {
                        self.expected = navigation
                        try await self.waitForLoad()
                    } else if let address, try await self.load(address) {
                        try await self.waitForLoad()
                    }
                } catch {
                    // Still no page: the next command or display tries again.
                    if self.webView.url == nil { self.unloaded = true }
                    throw error
                }
            }
        }
        if let url = pendingURL {
            pendingURL = nil
            // A tab reopened at launch loads before any command: it too waits for last time's ad-blocking rules.
            initialLoad = Task {
                await AdBlock.shared.loading?.value
                if try await self.load(url) { try await self.waitForLoad() }
            }
        }
        guard let task = initialLoad else { return }
        defer { if initialLoad == task { initialLoad = nil } }
        try await task.value
    }

    /// A load must not start before WebKit has seen the killed process go, or it goes with it.
    func endOfUnload() async {
        for _ in 0..<40 where awaitingExit { try? await Task.sleep(for: .milliseconds(50)) }
        // No word from WebKit: a later crash must not be taken for this.
        awaitingExit = false
    }

    /// A tab opened behind the current one: a command that later selects it waits for this load like a reopened tab's.
    func loadInBackground(_ url: URL) {
        initialLoad = Task { if try await self.load(url) { try await self.waitForLoad() } }
    }

    /// A closed tab: a load waiting on the cookie restore must not start in its detached web view.
    func cancelLoads() {
        loadGeneration += 1
        initialLoad = nil
        // A display queued just before (a restored tab closed at launch) would load it in the detached view.
        pendingURL = nil
    }

    /// Ends the page and lets its web content process go, as a browser closing a tab does. Without it the page
    /// runs on while anything still holds the web view: the sidebar's SwiftUI rows keep closed tabs for minutes.
    func closePage() {
        closed = true
        let selector = NSSelectorFromString("_close")
        guard webView.responds(to: selector) else { return }
        typealias Close = @convention(c) (AnyObject, Selector) -> Void
        unsafeBitCast(webView.method(for: selector), to: Close.self)(webView, selector)
    }

    /// `headers`: sent with this page load and its redirects, not its subresources; a load by address later (an
    /// unloaded tab coming back, a relaunch) goes without them.
    func goto(_ url: URL, headers: [String: String] = [:]) async throws {
        let (pending, wasUnloaded, downloads) = (pendingURL, unloaded, pageDownloads)
        pendingURL = nil
        initialLoad = nil
        unloaded = false
        await endOfUnload()
        // A fragment-only change is a same-document navigation; WebKit sends no didFinish for it.
        if headers.isEmpty, let current = webView.url, Self.sameDocument(current, url) {
            webView.load(URLRequest(url: url))
            try? await Task.sleep(for: .milliseconds(100))
            return
        }
        guard try await load(url, headers: headers) else { return }
        do {
            try await waitForLoad()
        } catch {
            // A URL that answers with a file leaves the page as it was: one not loaded yet, or unloaded, loads on next use.
            if pageDownloads != downloads { pendingURL = pending; unloaded = wasUnloaded }
            throw error
        }
        // A page that sends itself on by script (an SPA's SSO check) starts that navigation just after loading;
        // wait for it, so the reply shows where the agent really is.
        // A chain (app, then the IdP, then its callback page's own redirect) repeats that until a load stays put.
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            for _ in 0..<6 where !webView.isLoading { try? await Task.sleep(for: .milliseconds(50)) }
            guard webView.isLoading else { break }
            while webView.isLoading, Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        }
        // An SSO bounce or a login redirect explains a page the agent didn't ask for; the reply's URL already says where
        // (an SSO landing's can be thousands of characters of tokens).
        if let landed = webView.url, landed.host != url.host || Self.trimmedPath(landed) != Self.trimmedPath(url) {
            events.append("redirected (URL shows where it landed)")
        }
        // The title arrives just after didFinish; agents read it from the reply.
        for _ in 0..<5 where (webView.title ?? "").isEmpty { try? await Task.sleep(for: .milliseconds(60)) }
    }

    /// Waits until WebKit has handed the page every mouse event sent so far: it sends them one at a time, so a script
    /// right after a click would run between its press and release and take the press's user activation away from the
    /// click (a page's copy or clipboard read in its handler is refused then).
    func mouseEventsDelivered() async {
        let selector = NSSelectorFromString("_doAfterProcessingAllPendingMouseEvents:")
        guard webView.responds(to: selector) else { try? await Task.sleep(for: .milliseconds(150)); return }
        typealias Call = @convention(c) (AnyObject, Selector, @escaping @convention(block) () -> Void) -> Void
        let call = unsafeBitCast(webView.method(for: selector), to: Call.self)
        _ = try? await withTimeout(2, "the page taking the click") { [webView] in
            await withCheckedContinuation { continuation in call(webView, selector) { continuation.resume() } }
        }
    }

    /// What the last load asked for: a failure macOS 15 reports with no URL (a refused proxy login) names it.
    @ObservationIgnored var requestedURL: URL?

    /// Every first load goes through here, so a profile's saved session cookies are back before any page asks.
    /// False when a later load replaced this one while the cookies were coming back.
    @discardableResult
    func load(_ url: URL, headers: [String: String] = [:]) async throws -> Bool {
        if let refusal = Profiles.refusal(workspace.profile) { throw Failure(refusal) }
        requestedURL = url
        loadGeneration += 1
        let generation = loadGeneration
        if let profile = workspace.profile { await Profiles.restoreSessionCookies(profile) }
        guard generation == loadGeneration else { return false }
        expected = url.isFileURL
            ? webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            : webView.load(Self.request(url, headers))
        return true
    }

    private static func request(_ url: URL, _ headers: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    /// "/login/" and "/login" are one page; an empty path is "/".
    private static func trimmedPath(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path.isEmpty ? "/" : path
    }

    private static func sameDocument(_ a: URL, _ b: URL) -> Bool {
        guard b.fragment != nil, var ca = URLComponents(url: a, resolvingAgainstBaseURL: false),
              var cb = URLComponents(url: b, resolvingAgainstBaseURL: false) else { return false }
        ca.fragment = nil
        cb.fragment = nil
        return ca == cb
    }

    func waitForLoad() async throws {
        loadWaiter?.resume()
        loadTimeout?.cancel()
        loadTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            if !Task.isCancelled { self?.finishLoad(Failure("timed out waiting for the page to load")) }
        }
        try await withCheckedThrowingContinuation { loadWaiter = $0 }
    }

    /// sessionStorage by origin, saved with the tab of a named profile so a restart doesn't log out apps that keep
    /// their tokens there (OAuth implicit flows), as Chrome and Safari restore it. A fresh profile keeps nothing.
    @ObservationIgnored var session: [String: [String: String]] = [:]
    /// Saved origins not yet put back: until a page of that origin confirms it got them, a failed first load or a
    /// detour through another origin (an SSO bounce) can't lose them. `ownController` carries the seed script.
    @ObservationIgnored var pendingSeeds: [String: [String: String]] = [:]
    @ObservationIgnored var ownController: WKUserContentController?

    func seeded(_ origin: String) {
        guard pendingSeeds.removeValue(forKey: origin) != nil else { return }
        workspace.installScripts()
    }

    func captureSession() async {
        guard workspace.profile != nil, pendingURL == nil, !unloaded, let scheme = webView.url?.scheme, scheme.hasPrefix("http"),
              // Short: quit reads every tab, and a hung page must not hold it up.
              let json = try? await withTimeout(2, "reading sessionStorage", { try await self.call(PageScripts.readSession) }),
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let origin = object["origin"] as? String, let items = object["items"] as? [String: String],
              // Not yet put back: what the page holds now isn't what it had.
              pendingSeeds[origin] == nil,
              // Megabytes of cache: keep the last copy that fit, which holds the token.
              json.utf8.count <= 1_000_000 else { return }
        session[origin] = items.isEmpty ? nil : items
    }

    /// The tab stays visible until then after its agent's last command; see Visibility.swift.
    @ObservationIgnored var awakeUntil = Date.distantPast

    /// When an agent's command, or the person's display, click or key, last used the tab; saved, for `list`. A page's
    /// own timers and reloads don't count.
    @ObservationIgnored var lastUsed = Date() { didSet { usedClock = RunningClock.now } }
    /// RunningClock at that use, as for Workspace.usedClock.
    @ObservationIgnored var usedClock = RunningClock.now
    /// RunningClock when Unload.swift last saw it shown or heard: being read or played is use too, so a tab isn't
    /// unloaded the moment the person switches away, nor in a gap between two songs.
    @ObservationIgnored var seenClock = 0.0
    /// The page process was killed (Unload.swift) or crashed, so every page in its history is gone: a back or forward
    /// onto a form's result would send the form again. A tab that never lost its process resubmits as before.
    @ObservationIgnored var lostPages = false
    /// An explicit reload (the agent's or the toolbar's) under way, up to its commit: it may send a form again, its
    /// redirects included.
    @ObservationIgnored var resubmitAllowed = false
    @ObservationIgnored private var useSavedAt = Date.distantPast

    func markUsed() {
        let now = Date()
        lastUsed = now
        workspace.lastUsed = now
        // A command saves anyway; the person's clicks and keys add a save at most every 10 minutes.
        if now.timeIntervalSince(useSavedAt) > 600 {
            useSavedAt = now
            browser?.scheduleSave()
        }
    }

    /// What the tab costs: "visible", "hidden" (throttled), "suspended" (process frozen by WebKit) or "not loaded".
    /// The page's web content process; 0 before it has one. Popups opened by script can share their opener's.
    var processID: pid_t {
        let selector = NSSelectorFromString("_webProcessIdentifier")
        typealias Get = @convention(c) (AnyObject, Selector) -> pid_t
        return webView.responds(to: selector) ? unsafeBitCast(webView.method(for: selector), to: Get.self)(webView, selector) : 0
    }

    var state: String {
        if unloaded { return "unloaded" }
        if pendingURL != nil || webView.url == nil { return "not loaded" }
        let selector = NSSelectorFromString("_webProcessState")
        typealias Get = @convention(c) (AnyObject, Selector) -> Int
        // 0 not running, 1 foreground, 2 background, 3 suspended.
        let process = webView.responds(to: selector) ? unsafeBitCast(webView.method(for: selector), to: Get.self)(webView, selector) : 1
        if process == 3 { return "suspended" }
        if process == 0 { return "not running" }
        // A closed, minimized or hidden window hides every tab from WebKit.
        let shown = webView.superview?.isHidden == false && webView.window.map(MainWindow.isRendering) == true
        return shown ? "visible" : "hidden"
    }

    /// Playing sound the person can hear: kept loaded, like a playing tab in Safari or Chrome. Without WebKit's
    /// `_isPlayingAudio`, any unmuted tab counts.
    var audible: Bool {
        guard !isMuted else { return false }
        let selector = NSSelectorFromString("_isPlayingAudio")
        guard webView.responds(to: selector) else { return true }
        typealias Get = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(webView.method(for: selector), to: Get.self)(webView, selector)
    }

    func setMuted(_ muted: Bool) {
        guard muted != isMuted else { return }
        isMuted = muted
        // _WKMediaAudioMuted is 1; 0 unmutes.
        let selector = NSSelectorFromString("_setPageMuted:")
        guard webView.responds(to: selector) else { return }
        typealias SetMuted = @convention(c) (AnyObject, Selector, Int) -> Void
        unsafeBitCast(webView.method(for: selector), to: SetMuted.self)(webView, selector, muted ? 1 : 0)
    }

    /// Waits until WebKit has sent the page its visibility change; the next script is ordered behind it.
    func activityStateApplied(timeout: Double = 1) async {
        let selector = NSSelectorFromString("_doAfterActivityStateUpdate:")
        guard webView.responds(to: selector) else { return }
        typealias Call = @convention(c) (AnyObject, Selector, @escaping @convention(block) () -> Void) -> Void
        let call = unsafeBitCast(webView.method(for: selector), to: Call.self)
        _ = try? await withTimeout(timeout, "waking the tab") { [webView] in
            await withCheckedContinuation { continuation in call(webView, selector) { continuation.resume() } }
        }
    }

    /// When the running command started, in ms since 1970, the clock the page's network hook stamps calls with.
    @ObservationIgnored var commandStart = 0.0
    /// The last input an agent and the person gave this tab, which decides whose clipboard a page's copy reaches
    /// (ClipboardRouting.swift). The agent's: each command on the tab and each native click or key it sends.
    @ObservationIgnored var agentInputAt = Date.distantPast
    @ObservationIgnored var personInputAt = Date.distantPast

    /// After an action that may navigate: give it a moment to start, then wait for it to settle, and for the fetch
    /// and XHR calls it started, so the next snapshot sees the page's answer. Older calls (long polls) don't count.
    func settle() async {
        try? await Task.sleep(for: .milliseconds(150))
        let deadline = Date().addingTimeInterval(15)
        while webView.isLoading, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let network = Date().addingTimeInterval(5)
        var waited = false, first = true
        while Date() < network {
            if (try? await call(PageScripts.busySince, ["since": commandStart, "first": first], world: .page)) == "true" {
                first = false
                waited = true
            } else if Date().timeIntervalSince(passkeyAt) < 0.3 {
                // A passkey was just answered; the page sends it to its server next.
                waited = true
            } else {
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        // The page renders the answer just after the call ends.
        if waited { try? await Task.sleep(for: .milliseconds(50)) }
    }

    func finishLoad(_ error: Error?) {
        expected = nil
        loadTimeout?.cancel()
        guard let waiter = loadWaiter else { return }
        loadWaiter = nil
        if let error { waiter.resume(throwing: error) } else { waiter.resume() }
    }

    private func isExpected(_ navigation: WKNavigation?) -> Bool { expected == nil || navigation === expected }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        commits += 1
        resubmitAllowed = false
        postedPage = loadingMethod == "POST"
        // However it got here (the toolbar's reload, a load that bypassed loadIfPending), the page is back.
        unloaded = false
        // A reopened tab starts with its saved title; on a page with none, the title never changes, so KVO never fires.
        title = webView.title ?? ""
        // Input given to the last page is not this one's: it can't use the clipboard until it gets some.
        agentInputAt = .distantPast
        personInputAt = .distantPast
        frameRefs.removeAll()
        refLabels.removeAll()
        console.removeAll()
        unreadErrors = 0
        liveCaptures = 0
        Passkeys.shared.pageGone(self, "the page changed")
        browser?.updateLoginBar(self)
    }

    /// Answers a Basic or Digest login from the workspace's, once: a refused one shows the 401 page (default handling
    /// would resend WebKit's cached one forever). Everything else (proxies, certificates) is left to WebKit, as without
    /// this method. Never a permanent credential: WebKit would save it in the Keychain.
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        let origin = Address.origin(scheme: space.protocol ?? "", host: space.host, port: space.port)
        // A server offering Negotiate or NTLM first (IIS) gets to its Basic offer only if those are turned down.
        if [NSURLAuthenticationMethodNegotiate, NSURLAuthenticationMethodNTLM].contains(space.authenticationMethod), !space.isProxy(),
           workspace.basicAuth[origin].map({ !$0.refused }) == true {
            return completionHandler(.rejectProtectionSpace, nil)
        }
        guard !space.isProxy(), [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest].contains(space.authenticationMethod) else {
            return completionHandler(.performDefaultHandling, nil)
        }
        // Refused is set by the page's 401 (decidePolicyFor navigationResponse), not a fetch's under another realm.
        guard let login = workspace.basicAuth[origin], !login.refused, challenge.previousFailureCount == 0 else {
            // A user:pass@ address is still WebKit's to answer, once; no credential renders the 401 page.
            let fresh = workspace.basicAuth[origin] == nil && challenge.previousFailureCount == 0
            return completionHandler(fresh ? .performDefaultHandling : .useCredential, nil)
        }
        completionHandler(.useCredential, URLCredential(user: login.user, password: login.password, persistence: .forSession))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if isExpected(navigation) { finishLoad(nil) }
        browser?.captureAfterLoad(self)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadFailed(navigation, error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        resubmitAllowed = false
        loadFailed(navigation, error)
    }

    private func loadFailed(_ navigation: WKNavigation?, _ error: Error) {
        // Cancelled means another navigation replaced this one, and that one reports the outcome: a later `load`, or
        // the page's own redirect (location.replace in its head), which nobody expected by name.
        if (error as NSError).code == NSURLErrorCancelled {
            if navigation === expected { expected = nil }
            return
        }
        // As Playwright's does, the error names the URL that failed, which after a redirect is not the one asked for.
        // macOS 15's proxy refusal (POSIX EAUTH) names none: the page asked for, then.
        let url = ((error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.absoluteString
            ?? webView.url?.absoluteString ?? requestedURL?.absoluteString
        guard isExpected(navigation) else { return }
        let note = workspace.profile.flatMap(Profiles.routeNote)
        // What a proxy answers to missing or wrong credentials; WebKit's text names no proxy. macOS 15 reports it as
        // POSIX EAUTH ("Authentication error").
        let nsError = error as NSError
        let refused = nsError.code == NSURLErrorUserAuthenticationRequired || (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(EAUTH))
        let reason = refused && Profiles.proxied(workspace.profile)
            ? "the proxy asked for a username and password, or refused the saved ones" : error.localizedDescription
        finishLoad(Failure("navigation failed: \(reason)" + (url.map { " at \($0)" } ?? "") + (note.map { " (\($0))" } ?? "")))
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler outer: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        // navigator.platform has no other per-tab switch; the user agent is the web view's own.
        if phone != nil, navigationAction.targetFrame?.isMainFrame == true {
            let setter = NSSelectorFromString("_setCustomNavigatorPlatform:")
            if preferences.responds(to: setter) {
                typealias SetString = @convention(c) (AnyObject, Selector, NSString) -> Void
                unsafeBitCast(preferences.method(for: setter), to: SetString.self)(preferences, setter, Phone.platform as NSString)
            }
        }
        let decisionHandler = { (policy: WKNavigationActionPolicy) in outer(policy, preferences) }
        // Loopback, link-local and the Mac's own addresses skip the blackhole proxy an unreadable one gets.
        if Profiles.refusal(workspace.profile) != nil { return decisionHandler(.cancel) }
        // A popup gets its opener's action again; only the tab the link was in opens it elsewhere.
        if Self.opensInBackground(navigationAction), navigationAction.sourceFrame.webView === webView,
           let url = navigationAction.request.url, let browser {
            events.append("opened in tab \(browser.openInBackground(url, from: self)): \(url.absoluteString)")
            return decisionHandler(.cancel)
        }
        if navigationAction.targetFrame?.isMainFrame == true {
            if navigationAction.navigationType == .formResubmitted, lostPages, !resubmitAllowed {
                events.append("agweb did not send the form again: that history entry is a form's result, gone since the tab was unloaded or crashed, so go-back stops there; goto the page you want (agweb history lists them), or fill and submit the form again")
                return decisionHandler(.cancel)
            }
        }
        // Only a load that goes ahead: a cancelled or downloaded one doesn't replace the page whose method this records.
        if !navigationAction.shouldPerformDownload, navigationAction.targetFrame?.isMainFrame == true {
            loadingMethod = navigationAction.request.httpMethod
        }
        decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        let http = navigationResponse.response as? HTTPURLResponse
        let attachment = http?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased().hasPrefix("attachment") ?? false
        let download = attachment || !navigationResponse.canShowMIMEType
        if navigationResponse.isForMainFrame, !download {
            requests.removeAll()
            blocked.removeAll()
            challengedURL = http?.value(forHTTPHeaderField: "cf-mitigated")?.lowercased() == "challenge" ? http?.url : nil
            authWallSeen = nil
            if let http, http.statusCode == 401, let header = http.value(forHTTPHeaderField: "WWW-Authenticate"), let url = http.url,
               let scheme = url.scheme, let host = url.host {
                let origin = Address.origin(scheme: scheme, host: host, port: url.port)
                authWallSeen = Address.authChallenge(header).map { AuthWall(url: url, origin: origin, scheme: $0.scheme, realm: $0.realm) }
                // The page itself still asks with a login stored: refused, and never sent again.
                if authWallSeen != nil { workspace.basicAuth[origin]?.refused = true }
            }
        }
        if download, navigationResponse.isForMainFrame { pageDownloads += 1 }
        if let http {
            requests.append(["kind": navigationResponse.isForMainFrame ? "document" : "frame", "method": "GET", "url": http.url?.absoluteString ?? "",
                             "status": http.statusCode, "statusText": HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
                             "responseHeaders": http.allHeaderFields.reduce(into: [String: String]()) { $0["\($1.key)".lowercased()] = "\($1.value)" }])
        }
        decisionHandler(download ? .download : .allow)
    }

    /// WebKit's private WKNavigationDelegate callback for content rule lists: the ad blocker stopped a load.
    @objc(_webView:contentRuleListWithIdentifier:performedAction:forURL:)
    func contentRuleList(_ webView: WKWebView, identifier: String, performedAction action: NSObject, forURL url: URL) {
        let blockedLoad = NSSelectorFromString("blockedLoad")
        guard action.responds(to: blockedLoad) else { return }
        typealias GetBool = @convention(c) (AnyObject, Selector) -> Bool
        guard unsafeBitCast(action.method(for: blockedLoad), to: GetBool.self)(action, blockedLoad) else { return }
        blocked.append(url.absoluteString)
        if blocked.count > 500 { blocked.removeFirst(blocked.count - 500) }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
        if navigationResponse.isForMainFrame {
            pageDownloadsStarted += 1
            pageDownloadNumbers[ObjectIdentifier(download)] = pageDownloadsStarted
        }
    }

    // MARK: Downloads: saved without a panel, to `download --filename`, else the workspace's download folder.

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping @MainActor (URL?) -> Void) {
        let folder = workspace.downloadDir ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        var url = downloadPath ?? folder.appendingPathComponent(suggestedFilename)
        // An explicit --filename replaces the file there, as Playwright's saveAs does, but only once the new one is
        // complete; WebKit refuses to write over a file, so it goes to a free name first.
        var isFolder: ObjCBool = false
        let replaces = downloadPath != nil && FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) && !isFolder.boolValue ? url : nil
        downloadPath = nil
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var n = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = url.deletingLastPathComponent().appendingPathComponent("\(base) (\(n))" + (ext.isEmpty ? "" : ".\(ext)"))
            n += 1
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        downloads[ObjectIdentifier(download)] = (url, replaces)
        downloadsStarted += 1
        completionHandler(url)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let entry = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        var url = entry.url
        if let target = entry.replaces, (try? FileManager.default.replaceItemAt(target, withItemAt: url)) != nil { url = target }
        events.append("downloaded \(url.path)")
        downloadsEnded.append(.success(url.path))
        if let number = pageDownloadNumbers.removeValue(forKey: ObjectIdentifier(download)) { pageDownloadResults[number] = .success(url.path) }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let url = downloads.removeValue(forKey: ObjectIdentifier(download))?.url
        events.append("download of \(url?.lastPathComponent ?? "a file") failed: \(error.localizedDescription)")
        downloadsEnded.append(.failure(Failure("download failed: \(error.localizedDescription)")))
        if let number = pageDownloadNumbers.removeValue(forKey: ObjectIdentifier(download)) {
            pageDownloadResults[number] = .failure(Failure("download failed: \(error.localizedDescription)"))
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Unload.swift killed it on purpose: the next use reloads it.
        if awaitingExit {
            awaitingExit = false
            return
        }
        finishLoad(Failure("page crashed while loading"))
        // A page that crashes as it loads would otherwise reload forever in a tab nobody watches.
        let now = ProcessInfo.processInfo.systemUptime
        defer { lastCrash = now }
        if let lastCrash, now - lastCrash < 30 {
            events.append("page crashed again; not reloading (agweb reload)")
            return
        }
        lostPages = true
        events.append("page crashed (web content process ended); reloaded")
        // A form's result comes back by its address, as an unloaded one does: a reload would send the form again.
        if postedPage, let address = URL(string: url) { webView.load(URLRequest(url: address)) } else { webView.reload() }
    }

    // MARK: Things that would normally pop up

    /// Cmd-click or a middle click on a link, which WebKit numbers 4 here.
    private static func opensInBackground(_ action: WKNavigationAction) -> Bool {
        action.navigationType == .linkActivated && (action.buttonNumber == 4 || action.modifierFlags.contains(.command))
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let browser else { return nil }
        if Self.opensInBackground(navigationAction), let url = navigationAction.request.url {
            events.append("opened in tab \(browser.openInBackground(url, from: self)): \(url.absoluteString)")
            return nil
        }
        let popup = browser.addPopup(to: workspace, configuration: configuration, opener: self)
        let index = workspace.tabs.firstIndex { $0 === popup } ?? -1
        events.append("popup opened as tab \(index): \(navigationAction.request.url?.absoluteString ?? "")")
        return popup.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        browser?.closeTab(self)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        events.append("alert: \(message)")
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let accept = workspace.acceptDialogs
        events.append("confirm \(accept ? "accepted" : "dismissed"): \(message)")
        completionHandler(accept)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let accept = workspace.acceptDialogs
        let answer = workspace.promptText ?? defaultText ?? ""
        events.append("prompt \(accept ? "answered with \(answer.debugDescription)" : "dismissed"): \(prompt)")
        completionHandler(accept ? answer : nil)
    }

    /// WebKit's private UI delegate hook for context menus; a nil menu shows nothing.
    @objc(_webView:getContextMenuFromProposedMenu:forElement:userInfo:completionHandler:)
    func contextMenu(_ webView: WKWebView, proposedMenu menu: NSMenu, forElement element: AnyObject?, userInfo: AnyObject?,
                     completionHandler: @escaping (NSMenu?) -> Void) {
        if suppressMenus || workspace.busy {
            events.append("context menu suppressed")
            completionHandler(nil)
        } else {
            completionHandler(menu)
        }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        chooserOpened = true
        if let files = pendingUpload {
            pendingUpload = nil
            events.append("file chooser got \(files.map(\.lastPathComponent))")
            completionHandler(files)
            return
        }
        // Only a person using the window gets a real panel; an agent's stray chooser is cancelled.
        guard !workspace.busy, NSApp.isActive, let window = webView.window else {
            events.append("file chooser cancelled (use: agweb upload <ref> <file>)")
            completionHandler(nil)
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.beginSheetModal(for: window) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    // MARK: JavaScript

    /// Runs a function body; the body must return a string. It runs in `frame`, else in the frame of the `target`
    /// argument's ref, else in the page.
    /// `timeout`: a script sent to a page as it is replaced can get no answer at all; polls use a short one.
    func call(_ body: String, _ arguments: [String: Any] = [:], world: WKContentWorld? = nil, frame: Frame? = nil, timeout: Double = 30) async throws -> String {
        let world = world ?? Tab.agentWorld
        let info = (frame ?? (arguments["target"] as? String).flatMap { frameRefs[$0] })?.info
        var arguments = arguments
        if arguments["refSeed"] == nil { arguments["refSeed"] = workspace.refSeed }
        return try await withTimeout(timeout, "page script") { [webView, arguments, workspace, weak self] in
            try await withCheckedThrowingContinuation { continuation in
                webView.callAsyncJavaScript(body, arguments: arguments, in: info, in: world) { result in
                    switch result {
                    case .success(let value): continuation.resume(returning: value as? String ?? "\(value)")
                    case .failure where MainActor.assumeIsolated({ self?.closed != false }):
                        continuation.resume(throwing: Failure("the tab was closed"))
                    case .failure(let error as WKError) where error.code == .javaScriptInvalidFrameTarget:
                        continuation.resume(throwing: Failure("\((arguments["target"] as? String).map { "ref \($0) not found: " } ?? "")"
                                                              + "its frame reloaded or closed; take a new snapshot"))
                    case .failure(let error):
                        let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
                        // An error listing matches hands out refs too; the next page must not reuse them.
                        let refs = message.components(separatedBy: "ref=e").dropFirst().compactMap { Int($0.prefix { $0.isNumber }) }
                        if let highest = refs.max() { MainActor.assumeIsolated { workspace.refSeed = max(workspace.refSeed, highest) } }
                        // Replies already start with "Error: ".
                        continuation.resume(throwing: Failure(message.hasPrefix("Error: ") ? String(message.dropFirst(7)) : message))
                    }
                }
            }
        }
    }

    /// Every frame below the page, through WebKit's private frame tree: cross-origin ones can't be reached from the page.
    func subframes() async -> [WKFrameInfo] {
        let selector = NSSelectorFromString("_frames:"), childFrames = NSSelectorFromString("childFrames"), info = NSSelectorFromString("info")
        guard webView.responds(to: selector) else { return [] }
        typealias Frames = @convention(c) (AnyObject, Selector, @escaping @convention(block) (AnyObject?) -> Void) -> Void
        let call = unsafeBitCast(webView.method(for: selector), to: Frames.self)
        // A stuck web process may never answer; then no frame is reachable, as before.
        let root: AnyObject? = try? await withTimeout(2, "frame tree") { [webView] in
            await withCheckedContinuation { continuation in
                call(webView, selector) { node in continuation.resume(returning: node) }
            }
        }
        func below(_ node: AnyObject) -> [WKFrameInfo] {
            guard node.responds(to: childFrames) else { return [] }
            let children = node.perform(childFrames)?.takeUnretainedValue() as? [AnyObject] ?? []
            return children.flatMap { child in
                (child.responds(to: info) ? child.perform(info)?.takeUnretainedValue() as? WKFrameInfo : nil).map { [$0] + below(child) } ?? []
            }
        }
        return root.map(below) ?? []
    }

    /// The frame below the page that has the keyboard focus, if one does: keys typed go there.
    func focusedFrame() async -> Frame? {
        await subframes().first(where: Tab.isFocused).map { Frame(info: $0, parent: nil, element: "") }
    }

    func snapshot(_ config: WKSnapshotConfiguration? = nil, timeout: Double = 10) async throws -> NSImage {
        try await withTimeout(timeout, "snapshot") { [webView] in
            try await withCheckedThrowingContinuation { continuation in
                webView.takeSnapshot(with: config) { image, error in
                    if let image { continuation.resume(returning: image) } else {
                        continuation.resume(throwing: error ?? Failure("snapshot failed"))
                    }
                }
            }
        }
    }
}

/// A cross-origin frame: scripts run in it through its handle. `element` is the iframe's ref in `parent` (nil: the page),
/// which places the frame on screen.
final class Frame {
    let info: WKFrameInfo
    let parent: Frame?
    let element: String
    init(info: WKFrameInfo, parent: Frame?, element: String) {
        self.info = info
        self.parent = parent
        self.element = element
    }
}

/// Resumes with whichever finishes first, the body or the deadline. A task group can't do this: it waits
/// for every child, and WebKit callbacks ignore cancellation, so a hung callback would hang the group.
@MainActor
func withTimeout<T>(_ seconds: Double, _ what: String, _ body: @escaping @MainActor () async throws -> T) async throws -> T {
    let once = Once()
    return try await withCheckedThrowingContinuation { continuation in
        let work = Task { @MainActor in
            do {
                let value = try await body()
                if !once.done { once.done = true; continuation.resume(returning: value) }
            } catch {
                if !once.done { once.done = true; continuation.resume(throwing: error) }
            }
            once.timer?.cancel()
        }
        once.timer = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            if !once.done {
                once.done = true
                work.cancel()
                continuation.resume(throwing: Failure("\(what) timed out after \(Int(seconds))s"))
            }
        }
    }
}

private final class Once {
    var done = false
    var timer: Task<Void, Never>?
}

final class ConsoleSink: NSObject, WKScriptMessageHandler {
    weak var browser: Browser?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard let tab = browser?.tab(for: message.webView) else { return }
            if let text = message.body as? String {
                tab.console.append(text)
                tab.consoleTotal += 1
                if tab.console.count > 500 { tab.console.removeFirst(tab.console.count - 500) }
                if text.hasPrefix("error") || text.hasPrefix("pageerror") { tab.unreadErrors += 1 }
            } else if let body = message.body as? [String: Any] {
                if let origin = body["stored"] as? String {
                    tab.workspace.pendingStorage[origin] = nil
                } else if let origin = body["seeded"] as? String {
                    tab.seeded(origin)
                } else {
                    tab.requests.append(body)
                    if tab.requests.count > 500 { tab.requests.removeFirst(tab.requests.count - 500) }
                }
            }
        }
    }
}
