import AppKit
import WebKit
import AgwebCore

@MainActor
final class Browser {
    let model = BrowserModel()
    private(set) lazy var mainWindow = MainWindow(model: model)
    private let console = ConsoleSink()
    private var stores: [String: WKWebsiteDataStore] = [:]
    private var queues: [String: Task<Void, Never>] = [:]
    private var nextTabID = 1

    /// Tabs a person opens from the window, when no agent tab is displayed, live in this session.
    static let userSession = "user"

    init() {
        console.browser = self
        model.onDisplay = { [weak self] id in
            guard let self, let tab = self.model.displayedTab, tab.id == id else { return }
            self.mainWindow.bringToTop(tab.webView)
        }
        model.onCloseTab = { [weak self] tab in self?.closeTab(tab) }
        model.onCloseSession = { [weak self] session in self?.closeSession(session) }
        model.onNewTab = { [weak self] session in self?.newTabFromUser(in: session) }
    }

    // MARK: Sessions and tabs

    func tab(for webView: WKWebView?) -> Tab? {
        model.sessions.lazy.flatMap(\.tabs).first { $0.webView === webView }
    }

    private func session(named name: String, profile: String?) throws -> Session {
        if let session = model.sessions.first(where: { $0.name == name }) {
            if let profile, profile != session.profile {
                throw Failure("session \(name) already uses profile \(session.profile); close it first to switch")
            }
            return session
        }
        let profile = profile ?? name
        let store: WKWebsiteDataStore
        if profile == "ephemeral" {
            store = Session.dataStore(for: profile)
        } else {
            store = stores[profile] ?? Session.dataStore(for: profile)
            stores[profile] = store
        }
        let session = Session(name: name, profile: profile, dataStore: store, console: console)
        model.sessions.append(session)
        return session
    }

    private func makeTab(in session: Session, configuration: WKWebViewConfiguration?, opener: Tab?) -> Tab {
        let tab = Tab(id: nextTabID, session: session, configuration: configuration ?? session.makeConfiguration(), browser: self, opener: opener)
        nextTabID += 1
        if let opener, let index = session.tabs.firstIndex(where: { $0 === opener }) {
            session.tabs.insert(tab, at: index + 1)
        } else {
            session.tabs.append(tab)
        }
        mainWindow.add(tab.webView)
        return tab
    }

    @discardableResult
    func addTab(to session: Session) -> Tab {
        let tab = makeTab(in: session, configuration: nil, opener: nil)
        drive(tab)
        return tab
    }

    /// A popup becomes the agent's tab only when the agent's own command opened it; an ad or a timer-opened
    /// window must not redirect the agent's next commands.
    func addPopup(to session: Session, configuration: WKWebViewConfiguration, opener: Tab) -> Tab {
        let tab = makeTab(in: session, configuration: configuration, opener: opener)
        if session.busy {
            drive(tab)
        } else if NSApp.isActive, model.displayedTabID == opener.id {
            model.display(tab.id)
        }
        return tab
    }

    /// Makes `tab` the one its agent drives. The window follows only when someone is already watching that
    /// session, so one agent never yanks the view away from another.
    private func drive(_ tab: Tab) {
        let watching = model.displayedTab.map { $0.session === tab.session } ?? true
        tab.session.currentID = tab.id
        if watching { model.display(tab.id) }
    }

    func closeTab(_ tab: Tab) {
        let session = tab.session
        guard let index = session.tabs.firstIndex(where: { $0 === tab }) else { return }
        tab.finishLoad(Failure("the tab was closed"))
        tab.webView.stopLoading()
        tab.webView.removeFromSuperview()
        session.tabs.remove(at: index)
        if session.currentID == tab.id {
            let opener = tab.opener.flatMap { opener in session.tabs.contains { $0 === opener } ? opener : nil }
            session.currentID = opener?.id ?? (session.tabs.indices.contains(index) ? session.tabs[index] : session.tabs.last)?.id
        }
        if model.displayedTabID == tab.id {
            if let next = session.current ?? model.sessions.lazy.flatMap(\.tabs).first {
                model.display(next.id)
            } else {
                model.displayedTabID = nil
            }
        }
    }

    func closeSession(_ session: Session) {
        if let recorder = session.recorder {
            session.recorder = nil
            Task { _ = try? await recorder.stop() }
        }
        for tab in session.tabs { closeTab(tab) }
        session.contentController.removeScriptMessageHandler(forName: "agwebConsole")
        model.sessions.removeAll { $0 === session }
    }

    private func newTabFromUser(in session: Session?) {
        guard let session = session ?? model.displayedTab?.session ?? (try? self.session(named: Self.userSession, profile: nil)) else { return }
        let tab = makeTab(in: session, configuration: nil, opener: nil)
        model.display(tab.id)
        mainWindow.focusAddress()
    }

    private var windowHidden: Bool {
        !mainWindow.window.isVisible || mainWindow.window.isMiniaturized
    }

    // MARK: Commands

    /// Commands for one session run one at a time, in arrival order; different sessions run concurrently.
    func handle(_ request: Request) async -> Response {
        let previous = queues[request.session]
        let work = Task { @MainActor () -> Response in
            await previous?.value
            return await self.execute(request)
        }
        queues[request.session] = Task { _ = await work.value }
        return await work.value
    }

    private func execute(_ request: Request) async -> Response {
        defer { model.sessions.first { $0.name == request.session }?.busy = false }
        do {
            return Response(ok: true, output: try await run(request))
        } catch {
            return Response(ok: false, output: "Error: \(error)")
        }
    }

    private func run(_ request: Request) async throws -> String {
        let args = request.args
        func arg(_ i: Int, _ name: String) throws -> String {
            guard args.indices.contains(i) else { throw Failure("missing <\(name)>") }
            return args[i]
        }

        switch request.command {
        case "list":
            if model.sessions.isEmpty { return "no sessions" }
            return model.sessions.map { "- \($0.name) (profile \($0.profile), \($0.tabs.count) tabs)" }.joined(separator: "\n")
        case "quit":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
            return "bye"
        case "open":
            let session = try session(named: request.session, profile: request.options["profile"])
            session.busy = true
            mainWindow.showQuietly()
            let tab = session.current ?? addTab(to: session)
            if let url = args.first { try await tab.goto(try Self.url(url)) }
            return describe(tab)
        default:
            break
        }

        guard let session = model.sessions.first(where: { $0.name == request.session }) else {
            throw Failure("no session '\(request.session)'; start it with: agweb -s=\(request.session) open [url]")
        }
        session.busy = true

        switch request.command {
        case "close":
            closeSession(session)
            return "session \(session.name) closed"
        case "dialog":
            switch try arg(0, "accept|dismiss") {
            case "accept": session.acceptDialogs = true
            case "dismiss": session.acceptDialogs = false
            default: throw Failure("use: agweb dialog accept|dismiss")
            }
            return "confirm() and prompt() will be \(session.acceptDialogs ? "accepted" : "dismissed")"
        case "tab-list":
            return tabList(session)
        case "tab-new":
            let tab = addTab(to: session)
            if let url = args.first { try await tab.goto(try Self.url(url)) }
            return tabList(session)
        case "tab-select":
            drive(try tabAt(try arg(0, "index"), in: session))
            return tabList(session)
        case "tab-close":
            guard let tab = try args.first.map({ try tabAt($0, in: session) }) ?? session.current else {
                throw Failure("no tab to close")
            }
            closeTab(tab)
            return tabList(session)
        case "video-start":
            if let recorder = session.recorder { throw Failure("already recording to \(recorder.url.path); run video-stop first") }
            let maxIdle = try request.options["max-idle"].map { text -> Double in
                guard let value = Double(text), value >= 0, value.isFinite else { throw Failure("--max-idle takes seconds, 0 for none") }
                return value
            } ?? 1.5
            let recorder = try Recorder(session: session, url: URL(fileURLWithPath: try arg(0, "path")), maxIdle: maxIdle)
            session.recorder = recorder
            recorder.start()
            return "recording \(session.name) to \(recorder.url.path)"
        case "video-stop":
            guard let recorder = session.recorder else { throw Failure("not recording; run video-start") }
            session.recorder = nil
            return try await recorder.stop()
        case "show":
            // Shows the agent's tab inside the window; never raises or activates the app.
            guard let tab = session.current else { throw Failure("session has no tabs") }
            model.display(tab.id)
            mainWindow.showQuietly()
            return describe(tab)
        default:
            break
        }

        guard let tab = session.current else { throw Failure("session has no tabs; run tab-new") }
        let webView = tab.webView
        let instant = request.options["instant"] != nil

        switch request.command {
        case "goto":
            try await tab.goto(try Self.url(try arg(0, "url")))
        case "reload":
            webView.reload()
            await tab.settle()
        case "go-back":
            webView.goBack()
            await tab.settle()
        case "go-forward":
            webView.goForward()
            await tab.settle()
        case "snapshot":
            let tree = try await tab.call(PageScripts.snapshot)
            return describe(tab) + "\n### Snapshot\n" + tree
        case "click":
            try await click(tab, target: try arg(0, "ref"), js: request.options["js"] != nil, forUpload: false, instant: instant)
            await tab.settle()
        case "hover":
            try await hover(tab, target: try arg(0, "ref"), instant: instant)
        case "mousemove":
            let json = try await tab.call(PageScripts.viewport)
            let size = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Double] ?? [:]
            let viewport = CGSize(width: size["viewportWidth"] ?? 0, height: size["viewportHeight"] ?? 0)
            guard let x = Double(try arg(0, "x")), let y = Double(try arg(1, "y")), (0...viewport.width).contains(x), (0...viewport.height).contains(y) else {
                throw Failure("use: agweb mousemove <x> <y> with a point inside the \(Int(viewport.width))x\(Int(viewport.height)) viewport")
            }
            try await movePointer(tab, to: CGPoint(x: x, y: y), targetSize: 44, viewport: viewport, instant: instant)
        case "upload":
            let target = try arg(0, "ref")
            guard args.count > 1 else { throw Failure("missing <file>") }
            tab.pendingUpload = args.dropFirst().map { URL(fileURLWithPath: $0) }
            tab.chooserOpened = false
            // Whatever happens, the files must not linger for the next chooser on this tab.
            defer { tab.pendingUpload = nil }
            try await click(tab, target: target, js: request.options["js"] != nil, forUpload: true, instant: instant)
            for _ in 0..<30 where !tab.chooserOpened { try await Task.sleep(for: .milliseconds(100)) }
            guard tab.chooserOpened else {
                throw Failure("no file chooser opened; target the <input type=file> or the button that opens it")
            }
            await tab.settle()
        case "fill":
            _ = try await tab.call(PageScripts.fill, ["target": try arg(0, "ref"), "text": try arg(1, "text")])
        case "type":
            let text = try arg(0, "text")
            if instant || text.isEmpty {
                _ = try await tab.call(PageScripts.insertText, ["text": text])
            } else {
                for (i, char) in text.enumerated() {
                    // A tab closed mid-word still runs scripts; the rest must not go nowhere and report success.
                    guard tab.webView.window != nil else { throw Failure("the tab was closed after \(i) of \(text.count) characters") }
                    do {
                        _ = try await tab.call(PageScripts.insertText, ["text": String(char)])
                    } catch {
                        throw Failure("typed \(i) of \(text.count) characters: \(error)")
                    }
                    if i < text.count - 1 { try await Task.sleep(for: .seconds(tab.motion.keyDelay(after: char))) }
                }
            }
        case "press":
            let window = mainWindow.window
            var previous = window.firstResponder
            if let editor = previous as? NSTextView, editor.isFieldEditor { previous = editor.delegate as? NSResponder }
            try NativeInput.press(webView, combo: try arg(0, "key"))
            await tab.settle()
            // Give the keyboard back to whatever the person was using.
            if let previous, previous !== webView, window.firstResponder === webView { window.makeFirstResponder(previous) }
        case "eval":
            let result = try await tab.call(PageScripts.evaluate(try arg(0, "code")), world: .page)
            return "### Result\n\(result)\n" + describe(tab)
        case "screenshot":
            if windowHidden { throw Failure("the window is closed or minimized, so pages are not rendering; run: agweb show") }
            let path = try arg(0, "path")
            let image = try await tab.screenshot()
            guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                throw Failure("could not encode screenshot")
            }
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: URL(fileURLWithPath: path))
            return "### Screenshot\n\(path)\n" + describe(tab)
        case "console":
            let lines = tab.console
            tab.console.removeAll()
            return lines.isEmpty ? "no console messages" : lines.joined(separator: "\n")
        default:
            throw Failure("unknown command '\(request.command)'; run agweb help")
        }
        return describe(tab)
    }

    private func tabAt(_ text: String, in session: Session) throws -> Tab {
        guard let index = Int(text), session.tabs.indices.contains(index) else {
            throw Failure("no tab \(text); tabs are 0...\(session.tabs.count - 1)")
        }
        return session.tabs[index]
    }

    // Controls that open native pickers (select menus, date and colour panels) would pop up on the person's
    // screen if clicked natively, so they go through fill instead.
    private static let pickerKinds: Set = ["select", "date", "time", "datetime-local", "month", "week", "color"]

    private func click(_ tab: Tab, target: String, js: Bool, forUpload: Bool, instant: Bool) async throws {
        if js {
            _ = try await tab.call(PageScripts.jsClick, ["target": target])
            return
        }
        let spot = try await locate(tab, target)
        if Self.pickerKinds.contains(spot.kind) {
            throw Failure("\(spot.kind) opens a native picker; use: agweb fill \(target) <value>")
        }
        // Hidden file inputs styled away to nothing have no point to click; a script click still counts as
        // a user gesture in WKWebView.
        if spot.size.width == 0 || spot.size.height == 0 {
            if forUpload || spot.kind == "file" {
                _ = try await tab.call(PageScripts.jsClick, ["target": target])
                return
            }
            throw Failure("\(target) has no size on screen; snapshot again or use --js")
        }
        let (point, landed) = try await glide(tab, onto: target, from: spot, instant: instant)
        if let covered = landed.covered { tab.events.append("click target was covered by <\(covered)>") }
        if !instant { try await Task.sleep(for: .seconds(tab.motion.jitter(0.12, 0.04))) }
        try NativeInput.button(tab.webView, down: true, at: point, viewportHeight: landed.viewport.height)
        tab.lastClick = (point, ProcessInfo.processInfo.systemUptime)
        if !instant { try await Task.sleep(for: .seconds(tab.motion.jitter(0.095, 0.015))) }
        try NativeInput.button(tab.webView, down: false, at: point, viewportHeight: landed.viewport.height)
    }

    private func hover(_ tab: Tab, target: String, instant: Bool) async throws {
        let spot = try await locate(tab, target)
        if spot.size.width == 0 || spot.size.height == 0 { throw Failure("\(target) has no size on screen; snapshot again") }
        let landed = try await glide(tab, onto: target, from: spot, instant: instant).spot
        if let covered = landed.covered { tab.events.append("hover target is covered by <\(covered)>") }
    }

    /// Puts the pointer on the target and returns where it is and the target's latest position. A glide takes
    /// up to a second, in which the page can move the target, so it is located again and corrected once.
    private func glide(_ tab: Tab, onto target: String, from spot: Spot, instant: Bool) async throws -> (point: CGPoint, spot: Spot) {
        if instant {
            try await movePointer(tab, to: spot.center, targetSize: 0, viewport: spot.viewport, instant: true)
            return (spot.center, spot)
        }
        var point = tab.motion.aim(center: spot.center, size: spot.size)
        try await movePointer(tab, to: point, targetSize: min(spot.size.width, spot.size.height), viewport: spot.viewport, instant: false)
        let now = try await locate(tab, target)
        guard now.size.width > 0, now.size.height > 0 else { throw Failure("\(target) disappeared while the pointer moved to it") }
        if !CGRect(x: now.center.x - now.size.width / 2, y: now.center.y - now.size.height / 2, width: now.size.width, height: now.size.height).contains(point) {
            point = tab.motion.aim(center: now.center, size: now.size)
            try await movePointer(tab, to: point, targetSize: min(now.size.width, now.size.height), viewport: now.viewport, instant: false)
        }
        return (point, now)
    }

    /// Glides the pointer to `point` through native mouse moves, so hover states follow it; `instant` jumps.
    private func movePointer(_ tab: Tab, to point: CGPoint, targetSize: Double, viewport: CGSize, instant: Bool) async throws {
        let start = tab.pointer ?? CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        let path = instant ? [(point, 0)] : tab.motion.path(from: start, to: point, targetSize: targetSize)
        for (step, pause) in path {
            try NativeInput.move(tab.webView, to: step, viewportHeight: viewport.height)
            tab.pointer = step
            if pause > 0 { try await Task.sleep(for: .seconds(pause)) }
        }
    }

    private struct Spot {
        var center: CGPoint
        var size: CGSize
        var viewport: CGSize
        var kind = ""
        var covered: String?
    }

    private func locate(_ tab: Tab, _ target: String) async throws -> Spot {
        let json = try await tab.call(PageScripts.locate, ["target": target])
        let spot = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] ?? [:]
        func number(_ key: String) -> Double { spot[key] as? Double ?? 0 }
        return Spot(center: CGPoint(x: number("x"), y: number("y")), size: CGSize(width: number("width"), height: number("height")),
                    viewport: CGSize(width: number("viewportWidth"), height: number("viewportHeight")),
                    kind: spot["kind"] as? String ?? "", covered: spot["covered"] as? String)
    }

    // MARK: Output

    private func describe(_ tab: Tab) -> String {
        var out = "### Page\n- URL: \(tab.webView.url?.absoluteString ?? "about:blank")\n- Title: \(tab.webView.title ?? "")"
        if windowHidden { out += "\n- Note: the window is closed or minimized; pages may pause (agweb show)" }
        if tab.session.tabs.count > 1 { out += "\n" + tabList(tab.session) }
        if !tab.events.isEmpty {
            out += "\n### Events\n" + tab.events.map { "- \($0)" }.joined(separator: "\n")
            tab.events.removeAll()
        }
        let errors = tab.console.filter { $0.hasPrefix("error") || $0.hasPrefix("pageerror") }.count
        if errors > 0 { out += "\n- \(errors) console errors (agweb console)" }
        return out
    }

    private func tabList(_ session: Session) -> String {
        "### Tabs\n" + session.tabs.enumerated().map { index, tab in
            let current = tab.id == session.currentID ? " (current)" : ""
            return "- \(index):\(current) [\(tab.webView.title ?? "")](\(tab.webView.url?.absoluteString ?? "about:blank"))"
        }.joined(separator: "\n")
    }

    /// Accepts what people type: full URLs, absolute paths, `localhost:3000/x`, `192.168.1.5:8080`,
    /// `example.com`. Local hosts get http, everything else https.
    static func url(_ text: String) throws -> URL {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("/") { return URL(fileURLWithPath: text) }
        let hostPort = text.range(of: "^[^:/?#\\s]+:\\d+([/?#]|$)", options: .regularExpression) != nil
        let hasScheme = !hostPort && text.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*:", options: .regularExpression) != nil
        if hasScheme {
            guard let url = URL(string: text) else { throw Failure("bad url \(text)") }
            return url
        }
        let host = text.prefix { !":/?#".contains($0) }.lowercased()
        let local = host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host == "[::1]"
            || host.range(of: "^\\d+\\.\\d+\\.\\d+\\.\\d+$", options: .regularExpression) != nil
        guard !host.isEmpty, let url = URL(string: (local ? "http://" : "https://") + text) else { throw Failure("bad url \(text)") }
        return url
    }
}
