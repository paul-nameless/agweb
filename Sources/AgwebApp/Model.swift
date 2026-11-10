import AppKit
import CryptoKit
import Observation
import WebKit
import AgwebCore

@Observable @MainActor
final class BrowserModel {
    var workspaces: [Workspace] = []
    var displayedTabID: Int?
    @ObservationIgnored var onDisplay: ((Int) -> Void)?
    @ObservationIgnored var onCloseTab: ((Tab) -> Void)?
    @ObservationIgnored var onCloseWorkspace: ((Workspace) -> Void)?
    @ObservationIgnored var onNewTab: ((Workspace?) -> Void)?

    func display(_ id: Int) {
        displayedTabID = id
        onDisplay?(id)
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
    /// True while an agent command runs. Commands on one workspace are serialized, so this is exact.
    var busy = false
    @ObservationIgnored var acceptDialogs = false
    /// Where downloads nobody named go: the last command's `--download-dir`, by default its caller's `.agweb/`.
    @ObservationIgnored var downloadDir: URL?
    /// The tab ids and current tab the agent last saw in a reply, so unchanged tabs aren't listed again.
    @ObservationIgnored var tabsShown: [Int] = []
    /// The running command's reply is printed --raw, without the tab list.
    @ObservationIgnored var rawReply = false
    /// What `dialog-accept <text>` answers prompt() with; nil answers with the prompt's default.
    @ObservationIgnored var promptText: String?
    @ObservationIgnored var recorder: Recorder?
    @ObservationIgnored let dataStore: WKWebsiteDataStore
    @ObservationIgnored let contentController = WKUserContentController()
    @ObservationIgnored var routes: [Route] = [] { didSet { installScripts() } }
    /// localStorage from `state-load` by origin, set when the origin next loads.
    @ObservationIgnored var pendingStorage: [String: [[String]]] = [:] { didSet { installScripts() } }

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

    init(name: String, profile: String?, console: WKScriptMessageHandler) {
        self.name = name
        self.profile = profile
        dataStore = Profiles.store(profile)
        // One controller per workspace: popups get a copy of the opener's configuration, and registering
        // a message handler twice on a shared controller throws.
        for handler in Self.handlers { contentController.add(console, name: handler) }
        installScripts()
    }

    static let handlers = ["agwebConsole", "agwebPage"]

    /// User scripts apply to the next load; live pages get the new routes directly.
    private func installScripts() {
        contentController.removeAllUserScripts()
        let routesJSON = String(decoding: (try? JSONEncoder().encode(routes)) ?? Data("[]".utf8), as: UTF8.self)
        let setRoutes = "window.__agwebRoutes = \(routesJSON);"
        contentController.addUserScript(WKUserScript(source: PageScripts.consoleHook, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        contentController.addUserScript(WKUserScript(source: setRoutes + PageScripts.networkHook, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        if !pendingStorage.isEmpty, let json = try? JSONEncoder().encode(pendingStorage) {
            contentController.addUserScript(WKUserScript(source: PageScripts.pendingStorage(String(decoding: json, as: UTF8.self)),
                                                         injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        for tab in tabs { tab.webView.evaluateJavaScript(setRoutes) }
    }

    func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        config.userContentController = contentController
        // Off: only a click opens a window, so an ad's timer can't hand the agent a new tab.
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        // Only hidden tabs are affected (see Visibility.swift): after about 4 minutes hidden WebKit frees their memory
        // and suspends the process; any command wakes it in milliseconds.
        config.preferences.inactiveSchedulingPolicy = .suspend
        // Without a Safari token Google sign-in and bot checks treat the browser as unknown.
        config.applicationNameForUserAgent = "Version/\(Self.safariVersion) Safari/605.1.15"
        return config
    }

    private static let safariVersion: String = {
        let plist = NSDictionary(contentsOfFile: "/Applications/Safari.app/Contents/Info.plist")
        return plist?["CFBundleShortVersionString"] as? String ?? "18.0"
    }()

}

/// Named profiles: persistent website data stores shared by every workspace naming them. WebKit keys a store
/// by a UUID that can't be turned back into the name, so the names live in a file of their own.
@MainActor
enum Profiles {
    private static let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/agweb/profiles.json")
    private static var stores: [String: WKWebsiteDataStore] = [:]

    static var names: [String] { (try? JSONDecoder().decode([String].self, from: Data(contentsOf: file))) ?? [] }

    static func store(_ name: String?) -> WKWebsiteDataStore {
        guard let name else { return .nonPersistent() }
        holdInUse(name)
        if let store = stores[name] { return store }
        // Registered first: another instance's launch sweep removes folders of names it can't find.
        if !names.contains(name) { update { $0.contains(name) ? $0 : $0 + [name] } }
        let store = WKWebsiteDataStore(forIdentifier: identifier(name))
        stores[name] = store
        return store
    }

    static func delete(_ name: String) async throws {
        guard names.contains(name) else { throw Failure("no profile \(name); see agweb profile-list") }
        if let fd = inUse.removeValue(forKey: name) { close(fd) }
        let probe = open(inUseFile(name).path, O_CREAT | O_RDWR, 0o600)
        defer { if probe >= 0 { close(probe) } }
        guard probe < 0 || flock(probe, LOCK_EX | LOCK_NB) == 0 else {
            if stores[name] != nil { holdInUse(name) }
            throw Failure("profile \(name) is open in another agweb instance; quit it or close its workspaces first")
        }
        // WebKit refuses to remove a store it still holds, which it does for a while after the store's last tab
        // closes, and crashes removing one before any web view exists. Wiping its data works in both cases.
        let store = stores.removeValue(forKey: name) ?? WKWebsiteDataStore(forIdentifier: identifier(name))
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        try? await WKWebsiteDataStore.remove(forIdentifier: identifier(name))
        restoring[name] = nil
        try? FileManager.default.removeItem(at: sessionCookies(name))
        try? FileManager.default.removeItem(at: inUseFile(name))
        update { $0.filter { $0 != name } }
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
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/WebKit/\(Agweb.bundleIdentifier)/WebsiteDataStore")
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

    // Every instance holding a profile's store keeps a shared lock on its file, so another instance (a test one on
    // its own socket) can't delete a profile the person's browser has open.
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
        file.deletingLastPathComponent().appendingPathComponent("profile-locks/\(identifier(name)).lock")
    }

    private static func sessionCookies(_ name: String) -> URL {
        file.deletingLastPathComponent().appendingPathComponent("session-cookies/\(identifier(name)).plist")
    }

    /// Stable forever: changing it would orphan every saved login.
    private static func identifier(_ name: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data("agweb.profile.\(name)".utf8)).prefix(16))
        return digest.withUnsafeBufferPointer { NSUUID(uuidBytes: $0.baseAddress!) as UUID }
    }

    /// Locked: instances on other sockets share the registry, and two read-modify-writes at once lose a name.
    private static func update(_ change: ([String]) -> [String]) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lock = open(file.path + ".lock", O_CREAT | O_RDWR, 0o600)
        defer { if lock >= 0 { close(lock) } }
        if lock >= 0 { flock(lock, LOCK_EX) }
        try? JSONEncoder().encode(change(names).sorted()).write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

@Observable @MainActor
final class Tab: NSObject, Identifiable, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    static let agentWorld = WKContentWorld.world(name: "agweb")

    nonisolated let id: Int
    var title = ""
    var url = ""
    /// Strong on purpose: a closed tab can still get page callbacks, and closeTab breaks the cycle.
    @ObservationIgnored let workspace: Workspace
    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored weak var browser: Browser?
    @ObservationIgnored weak var opener: Tab?
    @ObservationIgnored var console: [String] = []
    /// Console errors since the agent last read the console, for the hint under ### Page.
    @ObservationIgnored var unreadErrors = 0
    /// Documents, fetch and XHR calls since the page loaded: the hook's messages, as dictionaries.
    @ObservationIgnored var requests: [[String: Any]] = []
    @ObservationIgnored var events: [String] = []
    /// Keys and a button the agent is holding down (keydown, mousedown).
    @ObservationIgnored var held = NativeInput.Held()
    /// A fixed viewport from `resize`, in CSS pixels; nil fills the window.
    @ObservationIgnored var viewportSize: CGSize?
    /// While true, a context menu the page asks for is dropped: it would pop up on the person's screen.
    @ObservationIgnored var suppressMenus = false
    /// Where the next download goes; nil is the workspace's download folder.
    /// A tab reopened at launch: where it was, loaded on first use.
    @ObservationIgnored var pendingURL: URL?
    @ObservationIgnored var downloadPath: URL?
    @ObservationIgnored var downloadsStarted = 0
    /// Saved paths, or why a download failed, in the order they ended.
    @ObservationIgnored var downloadsEnded: [Result<String, Failure>] = []
    @ObservationIgnored private var downloads: [ObjectIdentifier: URL] = [:]
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
                Task { @MainActor in self?.title = webView.title ?? "" }
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
        if let url = pendingURL {
            pendingURL = nil
            initialLoad = Task { if await self.load(url) { try await self.waitForLoad() } }
        }
        guard let task = initialLoad else { return }
        defer { if initialLoad == task { initialLoad = nil } }
        try await task.value
    }

    /// A tab opened behind the current one: a command that later selects it waits for this load like a reopened tab's.
    func loadInBackground(_ url: URL) {
        initialLoad = Task { if await self.load(url) { try await self.waitForLoad() } }
    }

    /// A closed tab: a load waiting on the cookie restore must not start in its detached web view.
    func cancelLoads() {
        loadGeneration += 1
        initialLoad = nil
    }

    func goto(_ url: URL) async throws {
        pendingURL = nil
        initialLoad = nil
        // A fragment-only change is a same-document navigation; WebKit sends no didFinish for it.
        if let current = webView.url, Self.sameDocument(current, url) {
            webView.load(URLRequest(url: url))
            try? await Task.sleep(for: .milliseconds(100))
            return
        }
        guard await load(url) else { return }
        try await waitForLoad()
        // The title arrives just after didFinish; agents read it from the reply.
        for _ in 0..<5 where (webView.title ?? "").isEmpty { try? await Task.sleep(for: .milliseconds(60)) }
    }

    /// Every first load goes through here, so a profile's saved session cookies are back before any page asks.
    /// After the tab exists: WebKit never answers a cookie store in a process that has no web view yet.
    /// False when a later load replaced this one while the cookies were coming back.
    @discardableResult
    func load(_ url: URL) async -> Bool {
        loadGeneration += 1
        let generation = loadGeneration
        if let profile = workspace.profile { await Profiles.restoreSessionCookies(profile) }
        guard generation == loadGeneration else { return false }
        expected = url.isFileURL
            ? webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            : webView.load(URLRequest(url: url))
        return true
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

    /// The tab stays visible until then after its agent's last command; see Visibility.swift.
    @ObservationIgnored var awakeUntil = Date.distantPast

    /// Waits until the web process has applied a visibility change, so the next script sees the page visible.
    func activityStateApplied() async {
        let selector = NSSelectorFromString("_doAfterActivityStateUpdate:")
        guard webView.responds(to: selector) else { return }
        typealias Call = @convention(c) (AnyObject, Selector, @escaping @convention(block) () -> Void) -> Void
        let call = unsafeBitCast(webView.method(for: selector), to: Call.self)
        _ = try? await withTimeout(1, "waking the tab") { [webView] in
            await withCheckedContinuation { continuation in call(webView, selector) { continuation.resume() } }
        }
    }

    /// When the running command started, in ms since 1970, the clock the page's network hook stamps calls with.
    @ObservationIgnored var commandStart = 0.0

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
        while Date() < network, (try? await call(PageScripts.busySince, ["since": commandStart, "first": first], world: .page)) == "true" {
            first = false
            waited = true
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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if isExpected(navigation) { finishLoad(nil) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadFailed(navigation, error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadFailed(navigation, error)
    }

    private func loadFailed(_ navigation: WKNavigation?, _ error: Error) {
        // Cancelled means another navigation replaced this one, and that one reports the outcome: a later `load`, or
        // the page's own redirect (location.replace in its head), which nobody expected by name.
        if (error as NSError).code == NSURLErrorCancelled {
            if navigation === expected { expected = nil }
            return
        }
        if isExpected(navigation) { finishLoad(Failure("navigation failed: \(error.localizedDescription)")) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // A popup gets its opener's action again; only the tab the link was in opens it elsewhere.
        if Self.opensInBackground(navigationAction), navigationAction.sourceFrame.webView === webView,
           let url = navigationAction.request.url, let browser {
            events.append("opened in tab \(browser.openInBackground(url, from: self)): \(url.absoluteString)")
            return decisionHandler(.cancel)
        }
        decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        let http = navigationResponse.response as? HTTPURLResponse
        let attachment = http?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased().hasPrefix("attachment") ?? false
        let download = attachment || !navigationResponse.canShowMIMEType
        if navigationResponse.isForMainFrame, !download { requests.removeAll() }
        if let http {
            requests.append(["kind": navigationResponse.isForMainFrame ? "document" : "frame", "method": "GET", "url": http.url?.absoluteString ?? "",
                             "status": http.statusCode, "statusText": HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
                             "responseHeaders": http.allHeaderFields.reduce(into: [String: String]()) { $0["\($1.key)".lowercased()] = "\($1.value)" }])
        }
        decisionHandler(download ? .download : .allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    // MARK: Downloads: saved without a panel, to `download --filename`, else the workspace's download folder.

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping @MainActor (URL?) -> Void) {
        let folder = workspace.downloadDir ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        var url = downloadPath ?? folder.appendingPathComponent(suggestedFilename)
        downloadPath = nil
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var n = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = url.deletingLastPathComponent().appendingPathComponent("\(base) (\(n))" + (ext.isEmpty ? "" : ".\(ext)"))
            n += 1
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        downloads[ObjectIdentifier(download)] = url
        downloadsStarted += 1
        completionHandler(url)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let url = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        events.append("downloaded \(url.path)")
        downloadsEnded.append(.success(url.path))
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let url = downloads.removeValue(forKey: ObjectIdentifier(download))
        events.append("download of \(url?.lastPathComponent ?? "a file") failed: \(error.localizedDescription)")
        downloadsEnded.append(.failure(Failure("download failed: \(error.localizedDescription)")))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finishLoad(Failure("page crashed while loading"))
        // A page that crashes as it loads would otherwise reload forever in a tab nobody watches.
        let now = ProcessInfo.processInfo.systemUptime
        defer { lastCrash = now }
        if let lastCrash, now - lastCrash < 30 {
            events.append("page crashed again; not reloading (agweb reload)")
            return
        }
        events.append("page crashed (web content process ended); reloaded")
        webView.reload()
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

    /// Runs a function body; the body must return a string.
    func call(_ body: String, _ arguments: [String: Any] = [:], world: WKContentWorld? = nil) async throws -> String {
        let world = world ?? Tab.agentWorld
        return try await withTimeout(30, "page script") { [webView] in
            try await withCheckedThrowingContinuation { continuation in
                webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: world) { result in
                    switch result {
                    case .success(let value): continuation.resume(returning: value as? String ?? "\(value)")
                    case .failure(let error):
                        let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
                        // Replies already start with "Error: ".
                        continuation.resume(throwing: Failure(message.hasPrefix("Error: ") ? String(message.dropFirst(7)) : message))
                    }
                }
            }
        }
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
                if tab.console.count > 500 { tab.console.removeFirst(tab.console.count - 500) }
                if text.hasPrefix("error") || text.hasPrefix("pageerror") { tab.unreadErrors += 1 }
            } else if let body = message.body as? [String: Any] {
                if let origin = body["stored"] as? String {
                    tab.workspace.pendingStorage[origin] = nil
                } else {
                    tab.requests.append(body)
                    if tab.requests.count > 500 { tab.requests.removeFirst(tab.requests.count - 500) }
                }
            }
        }
    }
}
