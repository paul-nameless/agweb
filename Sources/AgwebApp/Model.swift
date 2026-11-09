import AppKit
import CryptoKit
import Observation
import WebKit
import AgwebCore

@Observable @MainActor
final class BrowserModel {
    var sessions: [Session] = []
    var displayedTabID: Int?
    @ObservationIgnored var onDisplay: ((Int) -> Void)?
    @ObservationIgnored var onCloseTab: ((Tab) -> Void)?
    @ObservationIgnored var onCloseSession: ((Session) -> Void)?
    @ObservationIgnored var onNewTab: ((Session?) -> Void)?

    func display(_ id: Int) {
        displayedTabID = id
        onDisplay?(id)
    }

    var displayedTab: Tab? {
        sessions.lazy.flatMap(\.tabs).first { $0.id == self.displayedTabID }
    }
}

/// One agent's workspace: its tabs, which one it drives, and the profile (website data store) behind them.
@Observable @MainActor
final class Session: Identifiable {
    nonisolated let name: String
    let profile: String
    var tabs: [Tab] = []
    var currentID: Int?
    /// True while an agent command runs. Commands on one session are serialized, so this is exact.
    var busy = false
    @ObservationIgnored var acceptDialogs = false
    @ObservationIgnored var recorder: Recorder?
    @ObservationIgnored let dataStore: WKWebsiteDataStore
    @ObservationIgnored let contentController = WKUserContentController()

    nonisolated var id: String { name }
    var current: Tab? { tabs.first { $0.id == currentID } }

    /// Finishes the recording, if any, and describes the file.
    func stopRecording() async throws -> String? {
        guard let recorder else { return nil }
        self.recorder = nil
        return try await recorder.stop()
    }

    init(name: String, profile: String, dataStore: WKWebsiteDataStore, console: WKScriptMessageHandler) {
        self.name = name
        self.profile = profile
        self.dataStore = dataStore
        // One controller per session: popups get a copy of the opener's configuration, and registering
        // a message handler twice on a shared controller throws.
        contentController.addUserScript(WKUserScript(source: PageScripts.consoleHook, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        contentController.add(console, name: "agwebConsole")
    }

    func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        config.userContentController = contentController
        // Off: only a click opens a window, so an ad's timer can't hand the agent a new tab.
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        // Keep timers alive in tabs nobody is looking at.
        config.preferences.inactiveSchedulingPolicy = .none
        // Without a Safari token Google sign-in and bot checks treat the browser as unknown.
        config.applicationNameForUserAgent = "Version/\(Self.safariVersion) Safari/605.1.15"
        return config
    }

    private static let safariVersion: String = {
        let plist = NSDictionary(contentsOfFile: "/Applications/Safari.app/Contents/Info.plist")
        return plist?["CFBundleShortVersionString"] as? String ?? "18.0"
    }()

    /// The same profile name always maps to the same persistent store, so sessions can share logins.
    /// "ephemeral" gets a fresh in-memory store every time.
    static func dataStore(for profile: String) -> WKWebsiteDataStore {
        if profile == "ephemeral" { return .nonPersistent() }
        if let store = stores[profile] { return store }
        let digest = Array(SHA256.hash(data: Data("agweb.profile.\(profile)".utf8)).prefix(16))
        let uuid = digest.withUnsafeBufferPointer { NSUUID(uuidBytes: $0.baseAddress!) as UUID }
        let store = WKWebsiteDataStore(forIdentifier: uuid)
        stores[profile] = store
        return store
    }

    private static var stores: [String: WKWebsiteDataStore] = [:]
}

@Observable @MainActor
final class Tab: NSObject, Identifiable, WKNavigationDelegate, WKUIDelegate {
    static let agentWorld = WKContentWorld.world(name: "agweb")

    nonisolated let id: Int
    var title = ""
    var url = ""
    /// Strong on purpose: a closed tab can still get page callbacks, and closeTab breaks the cycle.
    @ObservationIgnored let session: Session
    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored weak var browser: Browser?
    @ObservationIgnored weak var opener: Tab?
    @ObservationIgnored var console: [String] = []
    @ObservationIgnored var events: [String] = []
    @ObservationIgnored var pendingUpload: [URL]?
    @ObservationIgnored var chooserOpened = false
    /// Where the agent's pointer last went, in CSS pixels of the viewport; nil until the first move.
    @ObservationIgnored var pointer: CGPoint?
    @ObservationIgnored var motion = Motion()
    /// For the click ring in recordings.
    @ObservationIgnored var lastClick: (point: CGPoint, time: Double)?
    @ObservationIgnored private var loadWaiter: CheckedContinuation<Void, Error>?
    @ObservationIgnored private var loadTimeout: Task<Void, Never>?
    @ObservationIgnored private var lastCrash: Double?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    init(id: Int, session: Session, configuration: WKWebViewConfiguration, browser: Browser, opener: Tab?) {
        self.id = id
        self.session = session
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
                Task { @MainActor in if let url = webView.url { self?.url = url.absoluteString } }
            },
        ]
    }

    // MARK: Loading

    func goto(_ url: URL) async throws {
        // A fragment-only change is a same-document navigation; WebKit sends no didFinish for it.
        if let current = webView.url, Self.sameDocument(current, url) {
            webView.load(URLRequest(url: url))
            try? await Task.sleep(for: .milliseconds(100))
            return
        }
        load(url)
        try await waitForLoad()
        // The title arrives just after didFinish; agents read it from the reply.
        for _ in 0..<5 where (webView.title ?? "").isEmpty { try? await Task.sleep(for: .milliseconds(60)) }
    }

    func load(_ url: URL) {
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
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

    /// After an action that may navigate: give it a moment to start, then wait for it to settle.
    func settle() async {
        try? await Task.sleep(for: .milliseconds(150))
        let deadline = Date().addingTimeInterval(15)
        while webView.isLoading, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    func finishLoad(_ error: Error?) {
        loadTimeout?.cancel()
        guard let waiter = loadWaiter else { return }
        loadWaiter = nil
        if let error { waiter.resume(throwing: error) } else { waiter.resume() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoad(nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadFailed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadFailed(error)
    }

    private func loadFailed(_ error: Error) {
        // Cancelled means another navigation replaced this one; that one reports the outcome.
        if (error as NSError).code == NSURLErrorCancelled { return }
        finishLoad(Failure("navigation failed: \(error.localizedDescription)"))
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

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let browser else { return nil }
        let popup = browser.addPopup(to: session, configuration: configuration, opener: self)
        let index = session.tabs.firstIndex { $0 === popup } ?? -1
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
        let accept = session.acceptDialogs
        events.append("confirm \(accept ? "accepted" : "dismissed"): \(message)")
        completionHandler(accept)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let accept = session.acceptDialogs
        events.append("prompt \(accept ? "answered with default" : "dismissed"): \(prompt)")
        completionHandler(accept ? defaultText ?? "" : nil)
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
        guard !session.busy, NSApp.isActive, let window = webView.window else {
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
        guard let text = message.body as? String else { return }
        MainActor.assumeIsolated {
            guard let tab = browser?.tab(for: message.webView) else { return }
            tab.console.append(text)
            if tab.console.count > 500 { tab.console.removeFirst(tab.console.count - 500) }
        }
    }
}
