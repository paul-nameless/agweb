import AppKit
import WebKit
import AgwebCore

@MainActor
final class Browser {
    let model = BrowserModel()
    private(set) lazy var mainWindow = MainWindow(model: model)
    private let console = ConsoleSink()
    private var queues: [String: Task<Response, Never>] = [:]
    private var nextTabID = 1

    /// Tabs a person opens from the window, when no agent tab is displayed, live in this workspace.
    static let userWorkspace = "user"

    init() {
        console.browser = self
        model.onDisplay = { [weak self] id in
            guard let self, let tab = self.model.displayedTab, tab.id == id else { return }
            self.mainWindow.bringToTop(tab.webView)
        }
        model.onCloseTab = { [weak self] tab in self?.closeTab(tab) }
        model.onCloseWorkspace = { [weak self] workspace in self?.closeWorkspace(workspace) }
        model.onNewTab = { [weak self] workspace in self?.newTabFromUser(in: workspace) }
    }

    // MARK: Workspaces and tabs

    func tab(for webView: WKWebView?) -> Tab? {
        model.workspaces.lazy.flatMap(\.tabs).first { $0.webView === webView }
    }

    private func existingOrNewWorkspace(named name: String, profile: String?) throws -> Workspace {
        if let workspace = model.workspaces.first(where: { $0.name == name }) {
            if let profile, profile != workspace.profile {
                throw Failure("workspace \(name) already uses \(Self.describe(profile: workspace.profile)); close it first to switch")
            }
            return workspace
        }
        let workspace = Workspace(name: name, profile: profile, console: console)
        model.workspaces.append(workspace)
        return workspace
    }

    private func makeTab(in workspace: Workspace, configuration: WKWebViewConfiguration?, opener: Tab?) -> Tab {
        let tab = Tab(id: nextTabID, workspace: workspace, configuration: configuration ?? workspace.makeConfiguration(), browser: self, opener: opener)
        nextTabID += 1
        if let opener, let index = workspace.tabs.firstIndex(where: { $0 === opener }) {
            workspace.tabs.insert(tab, at: index + 1)
        } else {
            workspace.tabs.append(tab)
        }
        mainWindow.add(tab.webView)
        return tab
    }

    @discardableResult
    func addTab(to workspace: Workspace) -> Tab {
        let tab = makeTab(in: workspace, configuration: nil, opener: nil)
        drive(tab)
        return tab
    }

    /// A popup becomes the agent's tab only when the agent's own command opened it; an ad or a timer-opened
    /// window must not redirect the agent's next commands.
    func addPopup(to workspace: Workspace, configuration: WKWebViewConfiguration, opener: Tab) -> Tab {
        let tab = makeTab(in: workspace, configuration: configuration, opener: opener)
        if workspace.busy {
            drive(tab)
        } else if NSApp.isActive, model.displayedTabID == opener.id {
            model.display(tab.id)
        }
        return tab
    }

    /// Makes `tab` the one its agent drives. The window follows only when someone is already watching that
    /// workspace, so one agent never yanks the view away from another.
    private func drive(_ tab: Tab) {
        let watching = model.displayedTab.map { $0.workspace === tab.workspace } ?? true
        tab.workspace.currentID = tab.id
        if watching { model.display(tab.id) }
    }

    func closeTab(_ tab: Tab) {
        let workspace = tab.workspace
        guard let index = workspace.tabs.firstIndex(where: { $0 === tab }) else { return }
        tab.finishLoad(Failure("the tab was closed"))
        tab.webView.stopLoading()
        tab.webView.navigationDelegate = nil
        tab.webView.uiDelegate = nil
        tab.webView.removeFromSuperview()
        workspace.tabs.remove(at: index)
        if workspace.currentID == tab.id {
            let opener = tab.opener.flatMap { opener in workspace.tabs.contains { $0 === opener } ? opener : nil }
            workspace.currentID = opener?.id ?? (workspace.tabs.indices.contains(index) ? workspace.tabs[index] : workspace.tabs.last)?.id
        }
        if model.displayedTabID == tab.id {
            if let next = workspace.current ?? model.workspaces.lazy.flatMap(\.tabs).first {
                model.display(next.id)
            } else {
                model.displayedTabID = nil
            }
        }
    }

    private(set) var preparedToQuit = false

    /// Finishes every recording, since an MP4 without its index is unplayable, and saves session cookies.
    func prepareToQuit() async -> [String] {
        var videos: [String] = []
        for workspace in model.workspaces { videos += await describeStop(workspace) }
        await Profiles.saveSessionCookies()
        preparedToQuit = true
        return videos
    }

    private func describeStop(_ workspace: Workspace) async -> [String] {
        do {
            return try await workspace.stopRecording().map { [$0] } ?? []
        } catch {
            return ["### Video\nrecording failed: \(error)"]
        }
    }

    func closeWorkspace(_ workspace: Workspace) {
        // From the sidebar, outside the workspace's queue; an agent's close has already stopped it.
        if workspace.recorder != nil { Task { _ = await describeStop(workspace) } }
        for tab in workspace.tabs { closeTab(tab) }
        workspace.contentController.removeScriptMessageHandler(forName: "agwebConsole")
        model.workspaces.removeAll { $0 === workspace }
    }

    private func newTabFromUser(in workspace: Workspace?) {
        guard let workspace = workspace ?? model.displayedTab?.workspace ?? (try? existingOrNewWorkspace(named: Self.userWorkspace, profile: nil)) else { return }
        let tab = makeTab(in: workspace, configuration: nil, opener: nil)
        model.display(tab.id)
        mainWindow.focusAddress()
    }

    private var windowHidden: Bool { !MainWindow.isRendering(mainWindow.window) }

    // MARK: Commands

    /// Commands for one workspace run one at a time, in arrival order; different workspaces run concurrently.
    func handle(_ request: Request) async -> Response {
        let previous = queues[request.workspace]
        let work = Task { @MainActor () -> Response in
            _ = await previous?.value
            return await self.execute(request)
        }
        queues[request.workspace] = work
        return await work.value
    }

    private func execute(_ request: Request) async -> Response {
        defer { model.workspaces.first { $0.name == request.workspace }?.busy = false }
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
            if model.workspaces.isEmpty { return "no workspaces" }
            return model.workspaces.map { "- \($0.name) (\(Self.describe(profile: $0.profile)), \($0.tabs.count) tabs)" }.joined(separator: "\n")
        case "close-all":
            var lines: [String] = []
            for workspace in model.workspaces {
                lines += await describeStop(workspace)
                closeWorkspace(workspace)
                lines.append("workspace \(workspace.name) closed")
            }
            return lines.isEmpty ? "no workspaces" : lines.joined(separator: "\n")
        case "profile-list":
            let names = Profiles.names
            if names.isEmpty { return "no named profiles; open a workspace with -p NAME to create one" }
            return names.map { name in
                let users = model.workspaces.filter { $0.profile == name }.map(\.name)
                return "- \(name)" + (users.isEmpty ? "" : ": " + users.joined(separator: ", "))
            }.joined(separator: "\n")
        case "profile-delete":
            let name = try arg(0, "name")
            let users = model.workspaces.filter { $0.profile == name }.map(\.name)
            guard users.isEmpty else { throw Failure("profile \(name) is in use by \(users.joined(separator: ", ")); close them first") }
            try await Profiles.delete(name)
            return "profile \(name) deleted"
        case "quit":
            let videos = await prepareToQuit()
            // Not from a main-queue block: terminate would spin the run loop inside it, starving the main queue.
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0.2)
            return (["bye"] + videos).joined(separator: "\n")
        case "open":
            let workspace = try existingOrNewWorkspace(named: request.workspace, profile: request.options["profile"])
            workspace.busy = true
            mainWindow.showQuietly()
            let tab = workspace.current ?? addTab(to: workspace)
            // Once per profile per run, before its first page loads. After the tab exists: WebKit never answers a
            // cookie store in a process that has no web view yet.
            if let profile = workspace.profile { await Profiles.restoreSessionCookies(profile) }
            if let url = args.first { try await tab.goto(try Address.url(url)) }
            return describe(tab)
        default:
            break
        }

        guard let workspace = model.workspaces.first(where: { $0.name == request.workspace }) else {
            throw Failure("no workspace '\(request.workspace)'; start it with: agweb -w \(request.workspace) open [url]")
        }
        workspace.busy = true

        switch request.command {
        case "close":
            let video = await describeStop(workspace)
            closeWorkspace(workspace)
            return (["workspace \(workspace.name) closed"] + video).joined(separator: "\n")
        case "dialog-accept", "dialog-dismiss":
            workspace.acceptDialogs = request.command == "dialog-accept"
            return "confirm() and prompt() will be \(workspace.acceptDialogs ? "accepted" : "dismissed")"
        case "tab-list":
            return tabList(workspace)
        case "tab-new":
            let tab = addTab(to: workspace)
            if let url = args.first { try await tab.goto(try Address.url(url)) }
            return tabList(workspace)
        case "tab-select":
            drive(try tabAt(try arg(0, "index"), in: workspace))
            return tabList(workspace)
        case "tab-close":
            guard let tab = try args.first.map({ try tabAt($0, in: workspace) }) ?? workspace.current else {
                throw Failure("no tab to close")
            }
            closeTab(tab)
            return tabList(workspace)
        case "video-start":
            if let recorder = workspace.recorder { throw Failure("already recording to \(recorder.url.path); run video-stop first") }
            let maxIdle = try request.options["max-idle"].map { text -> Double in
                guard let value = Double(text), value >= 0, value.isFinite else { throw Failure("--max-idle takes seconds, 0 for none") }
                return value
            } ?? 1.5
            let recorder = try Recorder(workspace: workspace, url: URL(fileURLWithPath: try arg(0, "path")), maxIdle: maxIdle)
            workspace.recorder = recorder
            return "recording \(workspace.name) to \(recorder.url.path)"
        case "video-stop":
            guard let video = try await workspace.stopRecording() else { throw Failure("not recording; run video-start") }
            return video
        case "show":
            // Shows the agent's tab inside the window; never raises or activates the app.
            guard let tab = workspace.current else { throw Failure("workspace has no tabs") }
            model.display(tab.id)
            mainWindow.showQuietly()
            return describe(tab)
        default:
            break
        }

        guard let tab = workspace.current else { throw Failure("workspace has no tabs; run tab-new") }
        let webView = tab.webView
        let instant = request.options["instant"] != nil

        switch request.command {
        case "goto":
            try await tab.goto(try Address.url(try arg(0, "url")))
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
        case "click", "dblclick":
            try await click(tab, target: try arg(0, "ref"), js: request.options["js"] != nil, forUpload: false, instant: instant,
                            clicks: request.command == "dblclick" ? 2 : 1)
            await tab.settle()
        case "drag":
            try await drag(tab, from: try arg(0, "from"), to: try arg(1, "to"), instant: instant)
            await tab.settle()
        case "mousewheel":
            guard let dx = Double(try arg(0, "dx")), let dy = Double(try arg(1, "dy")), dx.isFinite, dy.isFinite else {
                throw Failure("use: agweb mousewheel <dx> <dy> in CSS pixels; positive dy scrolls down")
            }
            try await wheel(tab, dx: dx, dy: dy, instant: instant)
        case "hover":
            try await hover(tab, target: try arg(0, "ref"), instant: instant)
        case "mousemove":
            let viewport = try await viewportSize(tab)
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
            let combo = try arg(0, "key")
            let focused = try await tab.call(PageScripts.focusedKind)
            if Self.pickerKinds.contains(focused), Self.pickerKeys.contains(combo.lowercased().components(separatedBy: "+").last ?? "") {
                throw Failure("\(combo) would open the focused \(focused)'s native picker; use: agweb fill <ref> <value>")
            }
            let window = mainWindow.window
            var previous = window.firstResponder
            if let editor = previous as? NSTextView, editor.isFieldEditor { previous = editor.delegate as? NSResponder }
            // Another agent's press may have left its hidden tab first responder; the person types in the displayed one.
            if previous is WKWebView { previous = model.displayedTab?.webView }
            try NativeInput.press(webView, combo: combo)
            // Give the keyboard back right away, not after the page settles: the person may be typing.
            try? await Task.sleep(for: .milliseconds(50))
            if let previous, previous !== webView, window.firstResponder === webView { window.makeFirstResponder(previous) }
            await tab.settle()
        case "eval":
            let result = try await tab.call(PageScripts.evaluate(try arg(0, "code")), world: .page)
            return "### Result\n\(result)\n" + describe(tab)
        case "screenshot":
            if windowHidden { throw Failure(MainWindow.notRendering) }
            let path = try arg(0, "path")
            let image = try await tab.snapshot()
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

    private func tabAt(_ text: String, in workspace: Workspace) throws -> Tab {
        guard let index = Int(text), workspace.tabs.indices.contains(index) else {
            throw Failure("no tab \(text); tabs are 0...\(workspace.tabs.count - 1)")
        }
        return workspace.tabs[index]
    }

    // Controls that open native pickers (select menus, date and colour panels) would pop up on the person's
    // screen if clicked natively, so they go through fill instead.
    private static let pickerKinds: Set = ["select", "date", "time", "datetime-local", "month", "week", "color"]
    private static let pickerKeys: Set = ["space", " ", "enter", "arrowup", "arrowdown", "arrowleft", "arrowright"]

    private func click(_ tab: Tab, target: String, js: Bool, forUpload: Bool, instant: Bool, clicks: Int = 1) async throws {
        if js {
            _ = try await tab.call(PageScripts.jsClick, ["target": target])
            return
        }
        let spot = try await locate(tab, target)
        // The element under the point counts too: a see-through select over styled text is common.
        if let picker = [spot.kind, spot.hitKind].first(where: Self.pickerKinds.contains) {
            throw Failure("\(picker) opens a native picker; use: agweb fill \(target) <value>")
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
        for count in 1...clicks {
            if count > 1, !instant { try await Task.sleep(for: .seconds(tab.motion.jitter(0.09, 0.02))) }
            try NativeInput.button(tab.webView, down: true, at: point, viewportHeight: landed.viewport.height, clickCount: count)
            tab.lastClick = (point, ProcessInfo.processInfo.systemUptime)
            // A short timeout: the press waits on this frame.
            if !instant { await tab.workspace.recorder?.capture(timeout: 0.3) }
            if !instant { try await Task.sleep(for: .seconds(tab.motion.jitter(0.095, 0.015))) }
            try NativeInput.button(tab.webView, down: false, at: point, viewportHeight: landed.viewport.height, clickCount: count)
        }
    }

    /// Press on `source`, move to `target` with the button held, release. An HTML5-draggable source would make
    /// WebKit start an AppKit drag session, which tracks the person's real mouse, so those get DOM drag events.
    private func drag(_ tab: Tab, from source: String, to target: String, instant: Bool) async throws {
        if try await tab.call(PageScripts.isDraggable, ["target": source]) == "true" {
            _ = try await tab.call(PageScripts.html5Drag, ["from": source, "to": target])
            tab.events.append("\(source) is HTML5-draggable: dropped with DOM drag events, not the pointer")
            return
        }
        let start = try await locate(tab, source)
        if start.size.width == 0 || start.size.height == 0 { throw Failure("\(source) has no size on screen; snapshot again") }
        let (from, landed) = try await glide(tab, onto: source, from: start, instant: instant)
        let end = try await locate(tab, target, scroll: false)
        guard (0...end.viewport.width).contains(end.center.x), (0...end.viewport.height).contains(end.center.y) else {
            throw Failure("\(target) is off screen while \(source) is on it; drag in steps")
        }
        try NativeInput.button(tab.webView, down: true, at: from, viewportHeight: landed.viewport.height)
        tab.lastClick = (from, ProcessInfo.processInfo.systemUptime)
        if !instant { try await Task.sleep(for: .seconds(tab.motion.jitter(0.12, 0.03))) }
        let to = instant ? end.center : tab.motion.aim(center: end.center, size: end.size)
        // Drag code usually needs several moves to start, so even --instant takes a few straight steps.
        let path = instant ? (1...6).map { i in (CGPoint(x: from.x + (to.x - from.x) * Double(i) / 6, y: from.y + (to.y - from.y) * Double(i) / 6), 0.0) }
                           : tab.motion.path(from: from, to: to, targetSize: min(end.size.width, end.size.height))
        for (step, pause) in path {
            try NativeInput.drag(tab.webView, to: step, viewportHeight: end.viewport.height)
            tab.pointer = step
            if pause > 0 { try await Task.sleep(for: .seconds(pause)) }
        }
        if !instant { try await Task.sleep(for: .seconds(tab.motion.jitter(0.1, 0.03))) }
        try NativeInput.button(tab.webView, down: false, at: to, viewportHeight: end.viewport.height)
    }

    /// Scroll events at the pointer, in a person's wheel ticks of about 60 px unless `instant`.
    private func wheel(_ tab: Tab, dx: Double, dy: Double, instant: Bool) async throws {
        let viewport = try await viewportSize(tab)
        let at = tab.pointer ?? CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        let ticks = instant ? 1 : max(1, Int((max(abs(dx), abs(dy)) / 60).rounded(.up)))
        var sentX = 0.0, sentY = 0.0
        for i in 1...ticks {
            let x = (dx * Double(i) / Double(ticks)).rounded(), y = (dy * Double(i) / Double(ticks)).rounded()
            try NativeInput.wheel(tab.webView, at: at, viewportHeight: viewport.height, dx: Int32(x - sentX), dy: Int32(y - sentY))
            sentX = x
            sentY = y
            if !instant { try await Task.sleep(for: .seconds(tab.motion.jitter(0.035, 0.01))) }
        }
        try await Task.sleep(for: .milliseconds(150))
    }

    private func viewportSize(_ tab: Tab) async throws -> CGSize {
        let json = try await tab.call(PageScripts.viewport)
        let size = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Double] ?? [:]
        return CGSize(width: size["viewportWidth"] ?? 0, height: size["viewportHeight"] ?? 0)
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
        var hitKind = ""
        var covered: String?
    }

    private func locate(_ tab: Tab, _ target: String, scroll: Bool = true) async throws -> Spot {
        let json = try await tab.call(PageScripts.locate, ["target": target, "scroll": scroll])
        let spot = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] ?? [:]
        func number(_ key: String) -> Double { spot[key] as? Double ?? 0 }
        return Spot(center: CGPoint(x: number("x"), y: number("y")), size: CGSize(width: number("width"), height: number("height")),
                    viewport: CGSize(width: number("viewportWidth"), height: number("viewportHeight")),
                    kind: spot["kind"] as? String ?? "", hitKind: spot["hitKind"] as? String ?? "", covered: spot["covered"] as? String)
    }

    // MARK: Output

    private func describe(_ tab: Tab) -> String {
        var out = "### Page\n- URL: \(tab.webView.url?.absoluteString ?? "about:blank")\n- Title: \(tab.webView.title ?? "")"
        if windowHidden { out += "\n- Note: the window is closed or minimized; pages may pause (agweb show)" }
        if tab.workspace.tabs.count > 1 { out += "\n" + tabList(tab.workspace) }
        if !tab.events.isEmpty {
            out += "\n### Events\n" + tab.events.map { "- \($0)" }.joined(separator: "\n")
            tab.events.removeAll()
        }
        let errors = tab.console.filter { $0.hasPrefix("error") || $0.hasPrefix("pageerror") }.count
        if errors > 0 { out += "\n- \(errors) console errors (agweb console)" }
        return out
    }

    static func describe(profile: String?) -> String { profile.map { "profile \($0)" } ?? "fresh profile" }

    private func tabList(_ workspace: Workspace) -> String {
        "### Tabs\n" + workspace.tabs.enumerated().map { index, tab in
            let current = tab.id == workspace.currentID ? " (current)" : ""
            return "- \(index):\(current) [\(tab.webView.title ?? "")](\(tab.webView.url?.absoluteString ?? "about:blank"))"
        }.joined(separator: "\n")
    }
}
