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
    var saveTask: Task<Void, Never>?

    /// Tabs a person opens from the window, when no agent tab is displayed, live in this workspace.
    static let userWorkspace = "user"

    init() {
        console.browser = self
        model.onDisplay = { [weak self] id in
            guard let self, let tab = self.model.displayedTab, tab.id == id else { return }
            self.mainWindow.bringToTop(tab.webView)
            self.updateVisibility()
            Task { try? await tab.loadIfPending() }
            self.scheduleSave()
        }
        model.onCloseTab = { [weak self] tab in self?.closeTab(tab) }
        model.onCloseWorkspace = { [weak self] workspace in self?.closeWorkspace(workspace) }
        model.onNewTab = { [weak self] workspace in self?.newTabFromUser(in: workspace) }
    }

    // MARK: Workspaces and tabs

    func tab(for webView: WKWebView?) -> Tab? {
        model.workspaces.lazy.flatMap(\.tabs).first { $0.webView === webView }
    }

    func existingOrNewWorkspace(named name: String, profile: String?) throws -> Workspace {
        if let profile, profile.trimmingCharacters(in: .whitespaces) != profile || profile.isEmpty {
            throw Failure("profile names can't be empty or start or end with spaces")
        }
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
        updateVisibility()
        scheduleSave()
        return tab
    }

    /// `display: false` only adds it, for tabs reopened at launch.
    @discardableResult
    func addTab(to workspace: Workspace, display: Bool = true, lazy: Bool = false) -> Tab {
        let tab = makeTab(in: workspace, configuration: lazy ? workspace.makeConfiguration(lazy: true) : nil, opener: nil)
        if display { drive(tab) }
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

    /// A link opened with Cmd-click or the middle button: a tab after `opener` that loads without becoming current,
    /// as in any browser. Returns its index.
    func openInBackground(_ url: URL, from opener: Tab) -> Int {
        let tab = makeTab(in: opener.workspace, configuration: nil, opener: opener)
        tab.loadInBackground(url)
        return opener.workspace.tabs.firstIndex { $0 === tab } ?? -1
    }

    /// Makes `tab` the one its agent drives. The window follows only when someone is already watching that
    /// workspace, so one agent never yanks the view away from another.
    private func drive(_ tab: Tab) {
        let watching = model.displayedTab.map { $0.workspace === tab.workspace } ?? true
        tab.workspace.currentID = tab.id
        if watching { model.display(tab.id) }
        updateVisibility()
    }

    func closeTab(_ tab: Tab) {
        let workspace = tab.workspace
        guard let index = workspace.tabs.firstIndex(where: { $0 === tab }) else { return }
        tab.cancelLoads()
        tab.finishLoad(Failure("the tab was closed"))
        tab.webView.stopLoading()
        tab.webView.navigationDelegate = nil
        tab.webView.uiDelegate = nil
        mainWindow.remove(tab.webView)
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
        updateVisibility()
        scheduleSave()
    }

    private(set) var preparedToQuit = false

    /// Finishes every recording, since an MP4 without its index is unplayable, and saves session cookies.
    func prepareToQuit() async -> [String] {
        var videos: [String] = []
        for workspace in model.workspaces { videos += await describeStop(workspace) }
        await Profiles.saveSessionCookies()
        saveWorkspaces()
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
        for handler in Workspace.handlers { workspace.contentController.removeScriptMessageHandler(forName: handler) }
        model.workspaces.removeAll { $0 === workspace }
        if let profile = workspace.profile, !model.workspaces.contains(where: { $0.profile == profile }) { Profiles.release(profile) }
        scheduleSave()
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
        defer {
            if let workspace = model.workspaces.first(where: { $0.name == request.workspace }) {
                workspace.busy = false
                // Only after a command that acted on a page (`list` or `cookie-list` polling must not keep a tab awake),
                // and the tab it left current: a popup or tab-select moves the agent on.
                if workspace.actedOn != nil, let tab = workspace.current { keepAwakeAfterCommand(tab) }
                workspace.actedOn = nil
                updateVisibility()
            }
            scheduleSave()
        }
        do {
            return Response(ok: true, output: try await run(request))
        } catch {
            return Response(ok: false, output: "Error: \(error)")
        }
    }

    private func run(_ request: Request) async throws -> String {
        let args = request.args
        let options = request.options
        func arg(_ i: Int, _ name: String) throws -> String {
            guard args.indices.contains(i) else { throw Failure("missing <\(name)>") }
            return args[i]
        }

        switch request.command {
        case "list":
            if options["json"] != nil {
                let list = model.workspaces.map { workspace -> [String: Any] in
                    ["name": workspace.name, "profile": workspace.profile ?? NSNull(), "busy": workspace.busy,
                     "tabs": workspace.tabs.enumerated().map { index, tab in
                         ["index": index, "url": tab.currentURL, "title": tab.currentTitle, "current": tab.id == workspace.currentID,
                          "state": tab.state]
                     }]
                }
                return String(decoding: try JSONSerialization.data(withJSONObject: ["workspaces": list], options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
            }
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
            let workspace = try existingOrNewWorkspace(named: request.workspace, profile: options["profile"])
            workspace.downloadDir = options["download-dir"].map { URL(fileURLWithPath: $0) } ?? workspace.downloadDir
            workspace.busy = true
            mainWindow.showQuietly()
            let tab = workspace.current ?? addTab(to: workspace)
            await wake(tab)
            if let url = args.first { try await tab.goto(try Address.url(url)) } else { try await tab.loadIfPending() }
            return describe(tab)
        default:
            break
        }

        guard let workspace = model.workspaces.first(where: { $0.name == request.workspace }) else {
            guard Commands.all.contains(request.command) else { throw Failure(Commands.unknown(request.command)) }
            throw Failure("no workspace '\(request.workspace)'; start it with: agweb -w \(request.workspace) open [url]")
        }
        workspace.downloadDir = options["download-dir"].map { URL(fileURLWithPath: $0) } ?? workspace.downloadDir
        workspace.rawReply = options["raw"] != nil
        workspace.busy = true

        switch request.command {
        case "close":
            let video = await describeStop(workspace)
            closeWorkspace(workspace)
            return (["workspace \(workspace.name) closed"] + video).joined(separator: "\n")
        case "dialog-accept", "dialog-dismiss":
            workspace.acceptDialogs = request.command == "dialog-accept"
            workspace.promptText = workspace.acceptDialogs ? args.first : nil
            return "confirm() and prompt() will be \(workspace.acceptDialogs ? "accepted" : "dismissed")"
                + (workspace.promptText.map { "; prompt() gets \($0.debugDescription)" } ?? "")
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
            let maxIdle = try options["max-idle"].map { text -> Double in
                guard let value = Double(text), value >= 0, value.isFinite else { throw Failure("--max-idle takes seconds, 0 for none") }
                return value
            } ?? 1.5
            let size = try options["size"].map { text -> CGSize in
                let parts = text.lowercased().split(separator: "x").compactMap { Int($0) }
                guard parts.count == 2, (16...4096).contains(parts[0]), (16...4096).contains(parts[1]) else { throw Failure("--size is WIDTHxHEIGHT, like 1280x720") }
                return CGSize(width: parts[0], height: parts[1])
            }
            let recorder = try Recorder(workspace: workspace, url: URL(fileURLWithPath: try arg(0, "path")), maxIdle: maxIdle, frameSize: size)
            workspace.recorder = recorder
            return "recording \(workspace.name) to \(recorder.url.path)"
        case "video-chapter":
            guard let recorder = workspace.recorder else { throw Failure("not recording; run video-start") }
            let seconds = try options["duration"].map { text -> Double in
                guard let ms = Double(text), (0...60_000).contains(ms) else { throw Failure("--duration is milliseconds, up to 60000") }
                return ms / 1000
            } ?? 2
            recorder.showChapter(try arg(0, "title"), description: options["description"], seconds: seconds)
            // The card stays in the video only while the workspace is busy; idle time is cut.
            try await Task.sleep(for: .seconds(seconds))
            return "chapter \(args[0].debugDescription)"
        case "video-stop":
            guard let video = try await workspace.stopRecording() else { throw Failure("not recording; run video-start") }
            return video
        case "show":
            // Shows the agent's tab inside the window; never raises or activates the app.
            guard let tab = workspace.current else { throw Failure("workspace has no tabs") }
            model.display(tab.id)
            mainWindow.showQuietly()
            return describe(tab)
        case "route":
            var route = Workspace.Route(pattern: try arg(0, "pattern"))
            route.status = try options["status"].map { text in
                guard let status = Int(text), (100...599).contains(status) else { throw Failure("--status is an HTTP status code") }
                return status
            }
            route.body = options["body"]
            route.contentType = options["content-type"]
            for line in (options["header"] ?? "").split(separator: "\n") {
                guard let colon = line.firstIndex(of: ":") else { throw Failure("--header is \"name: value\"") }
                route.headers[line[..<colon].trimmingCharacters(in: .whitespaces)] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            workspace.routes = workspace.routes.filter { $0.pattern != route.pattern } + [route]
            return "fetch and XHR calls matching \(route.pattern) get \(route.status ?? 200)\n" + routeList(workspace)
        case "route-list":
            return routeList(workspace)
        case "unroute":
            let before = workspace.routes.count
            workspace.routes = args.first.map { pattern in workspace.routes.filter { $0.pattern != pattern } } ?? []
            return "removed \(before - workspace.routes.count) routes\n" + routeList(workspace)
        case "cookie-list", "cookie-get", "cookie-set", "cookie-delete", "cookie-clear":
            return try await cookies(request, in: workspace)
        default:
            break
        }

        guard let tab = workspace.current else {
            guard Commands.all.contains(request.command) else { throw Failure(Commands.unknown(request.command)) }
            throw Failure("workspace has no tabs; run tab-new")
        }
        tab.commandStart = Date().timeIntervalSince1970 * 1000
        await wake(tab)
        // A tab reopened at launch loads on first use.
        if request.command != "goto" { try await tab.loadIfPending() }
        let webView = tab.webView
        let instant = options["instant"] != nil

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
            let tree = try await tab.call(PageScripts.snapshot, ["target": args.first ?? ""])
            return describe(tab) + "\n### Snapshot\n" + tree
        case "text":
            return "### Result\n" + (try await pageText(tab, target: args.first)) + "\n" + describe(tab)
        case "click", "dblclick":
            try await click(tab, target: try arg(0, "target"), button: try MouseButton(args.count > 1 ? args[1] : nil), js: options["js"] != nil,
                            forUpload: false, instant: instant, clicks: request.command == "dblclick" ? 2 : 1)
            await tab.settle()
        case "check", "uncheck":
            let target = try arg(0, "target")
            let want = request.command == "check" ? "checked" : "unchecked"
            let state = try await tab.call(PageScripts.checkedState, ["target": target])
            if state == "none" { throw Failure("\(target) is not a checkbox, radio or switch") }
            if state != want {
                try await click(tab, target: target, button: .left, js: options["js"] != nil, forUpload: false, instant: instant)
                await tab.settle()
                if try await tab.call(PageScripts.checkedState, ["target": target]) != want { throw Failure("clicked \(target) but it is still \(state)") }
            }
        case "drag":
            try await drag(tab, from: try arg(0, "from"), to: try arg(1, "to"), instant: instant)
            await tab.settle()
        case "mousewheel":
            guard let dx = Double(try arg(0, "dx")), let dy = Double(try arg(1, "dy")), dx.isFinite, dy.isFinite else {
                throw Failure("use: agweb mousewheel <dx> <dy> in CSS pixels; positive dy scrolls down")
            }
            try await wheel(tab, dx: dx, dy: dy, instant: instant)
        case "hover":
            try await hover(tab, target: try arg(0, "target"), instant: instant)
        case "mousemove":
            let viewport = try await viewportSize(tab)
            guard let x = Double(try arg(0, "x")), let y = Double(try arg(1, "y")), (0...viewport.width).contains(x), (0...viewport.height).contains(y) else {
                throw Failure("use: agweb mousemove <x> <y> with a point inside the \(Int(viewport.width))x\(Int(viewport.height)) viewport")
            }
            try await movePointer(tab, to: CGPoint(x: x, y: y), targetSize: 44, viewport: viewport, instant: instant)
        case "mousedown", "mouseup":
            let button = try MouseButton(args.first)
            let down = request.command == "mousedown"
            if down, let held = tab.held.button { throw Failure("the \(held) button is already down; mouseup first") }
            if !down, tab.held.button != button { throw Failure("the \(button) button is not down") }
            let viewport = try await viewportSize(tab)
            let at = tab.pointer ?? CGPoint(x: viewport.width / 2, y: viewport.height / 2)
            if button == .right { suppressMenus(tab) }
            try NativeInput.button(webView, button, down: down, at: at, viewportHeight: viewport.height, held: tab.held)
            tab.held.button = down ? button : nil
            if down { tab.lastClick = (at, ProcessInfo.processInfo.systemUptime) }
            if !down { await tab.settle() }
        case "upload":
            let target = try arg(0, "target")
            guard args.count > 1 else { throw Failure("missing <file>") }
            tab.pendingUpload = args.dropFirst().map { URL(fileURLWithPath: $0) }
            tab.chooserOpened = false
            // Whatever happens, the files must not linger for the next chooser on this tab.
            defer { tab.pendingUpload = nil }
            try await click(tab, target: target, button: .left, js: options["js"] != nil, forUpload: true, instant: instant)
            for _ in 0..<30 where !tab.chooserOpened { try await Task.sleep(for: .milliseconds(100)) }
            guard tab.chooserOpened else {
                throw Failure("no file chooser opened; target the <input type=file> or the button that opens it")
            }
            await tab.settle()
        case "download":
            return "### Download\n" + (try await download(tab, target: try arg(0, "target"), to: options["filename"], js: options["js"] != nil, instant: instant)) + "\n" + describe(tab)
        case "fill", "select":
            _ = try await tab.call(PageScripts.fill, ["target": try arg(0, "target"), "text": try arg(1, request.command == "select" ? "value" : "text"),
                                                      "onlySelect": request.command == "select"])
            if options["submit"] != nil { try await pressKey(tab, "Enter") }
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
            if options["submit"] != nil { try await pressKey(tab, "Enter") }
        case "press":
            try await pressKey(tab, try arg(0, "key"))
        case "keydown", "keyup":
            try await pressKey(tab, try arg(0, "key"), phases: [request.command == "keydown" ? .keyDown : .keyUp])
        case "eval":
            let mark = try await args.count > 1 ? tab.call(PageScripts.mark, ["target": args[1]]) : nil
            let result = try await tab.call(PageScripts.evaluate(try arg(0, "code"), mark: mark), world: .page)
            return "### Result\n\(result)\n" + describe(tab)
        case "highlight":
            guard options["hide"] != nil || !args.isEmpty else { throw Failure("missing <target>") }
            _ = try await tab.call(PageScripts.highlight, ["target": args.first ?? "", "hide": options["hide"] != nil, "style": options["style"] ?? ""])
        case "screenshot":
            let path = try options["filename"] ?? { throw Failure("missing --filename") }()
            let image = try await screenshot(tab, target: args.first, fullPage: options["full-page"] != nil)
            let jpeg = ["jpg", "jpeg"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
            guard let tiff = image.tiffRepresentation,
                  let data = NSBitmapImageRep(data: tiff)?.representation(using: jpeg ? .jpeg : .png, properties: jpeg ? [.compressionFactor: 0.85] : [:]) else {
                throw Failure("could not encode screenshot")
            }
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: path))
            return "### Screenshot\n\(path)\n" + describe(tab)
        case "wait":
            return try await wait(tab, args.first, options) + "\n" + describe(tab)
        case "emulate":
            guard let scheme = options["color-scheme"] else { throw Failure("use: agweb emulate --color-scheme dark|light|auto") }
            // prefers-color-scheme follows the view's appearance; only this tab changes.
            switch scheme.lowercased() {
            case "dark": webView.appearance = NSAppearance(named: .darkAqua)
            case "light": webView.appearance = NSAppearance(named: .aqua)
            case "auto", "no-preference": webView.appearance = nil
            default: throw Failure("--color-scheme is dark, light or auto")
            }
            try await Task.sleep(for: .milliseconds(100))
        case "pdf":
            let path = try options["filename"] ?? { throw Failure("missing --filename") }()
            try await pdf(tab, to: URL(fileURLWithPath: path), singlePage: options["single-page"] != nil, paper: options["format"])
            return "### PDF\n\(path)\n" + describe(tab)
        case "resize":
            guard let width = Int(try arg(0, "w")), let height = Int(try arg(1, "h")), (100...8192).contains(width), (100...8192).contains(height) else {
                throw Failure("use: agweb resize <w> <h>, each 100 to 8192 CSS pixels")
            }
            try await resize(tab, to: CGSize(width: width, height: height))
        case "console":
            let levels = ["debug": 0, "info": 1, "warning": 2, "error": 3]
            let minimum = try args.first.map { name -> Int in
                guard let level = levels[name.lowercased()] else { throw Failure("level is error, warning, info or debug") }
                return level
            } ?? 1
            let rank = ["debug": 0, "log": 1, "info": 1, "warn": 2, "error": 3, "pageerror": 3]
            let lines = tab.console.filter { rank[String($0.prefix { $0 != ":" })] ?? 1 >= minimum }
            tab.unreadErrors = 0
            if options["clear"] != nil { tab.console.removeAll() }
            return lines.isEmpty ? "no console messages" : lines.joined(separator: "\n")
        case "requests":
            return try await requestList(tab, filter: options["filter"], includeStatic: options["static"] != nil, clear: options["clear"] != nil)
        case "request", "request-headers", "request-body", "response-headers", "response-body":
            return try requestDetail(tab, try arg(0, "n"), part: request.command)
        case "state-save":
            return "### Result\n" + (try await stateSave(workspace)) + "\n" + describe(tab)
        case "state-load":
            return try await stateLoad(workspace, json: try arg(0, "state"))
        default:
            throw Failure(Commands.unknown(request.command))
        }
        return describe(tab)
    }

    /// A native key press (or only its down or up half) on the tab, giving the keyboard back to whoever had it.
    private func pressKey(_ tab: Tab, _ combo: String, phases: [NSEvent.EventType] = [.keyDown, .keyUp]) async throws {
        let focused = try await tab.call(PageScripts.focusedKind)
        if Self.pickerKinds.contains(focused), Self.pickerKeys.contains(combo.lowercased().components(separatedBy: "+").last ?? "") {
            throw Failure("\(combo) would open the focused \(focused)'s native picker; use: agweb fill <target> <value>")
        }
        let window = mainWindow.window
        var previous = window.firstResponder
        if let editor = previous as? NSTextView, editor.isFieldEditor { previous = editor.delegate as? NSResponder }
        // Another agent's press may have left its hidden tab first responder; the person types in the displayed one.
        if previous is WKWebView { previous = model.displayedTab?.webView }
        try NativeInput.press(tab.webView, combo: combo, phases: phases, held: &tab.held)
        // Give the keyboard back right away, not after the page settles: the person may be typing.
        try? await Task.sleep(for: .milliseconds(50))
        if let previous, previous !== tab.webView, window.firstResponder === tab.webView { window.makeFirstResponder(previous) }
        if phases.contains(.keyUp) { await tab.settle() }
    }

    /// A right click asks WebKit for a context menu, which would pop up on the person's screen.
    private func suppressMenus(_ tab: Tab) {
        tab.suppressMenus = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            tab.suppressMenus = false
        }
    }

    /// Clicks and waits for the download the click starts; returns the saved path.
    private func download(_ tab: Tab, target: String, to path: String?, js: Bool, instant: Bool) async throws -> String {
        tab.downloadPath = path.map { URL(fileURLWithPath: $0) }
        defer { tab.downloadPath = nil }
        let started = tab.downloadsStarted, ended = tab.downloadsEnded.count
        try await click(tab, target: target, button: .left, js: js, forUpload: false, instant: instant)
        for _ in 0..<100 where tab.downloadsStarted == started { try await Task.sleep(for: .milliseconds(100)) }
        guard tab.downloadsStarted > started else { throw Failure("no download started within 10 s of clicking \(target)") }
        for _ in 0..<1200 where tab.downloadsEnded.count == ended { try await Task.sleep(for: .milliseconds(100)) }
        guard let result = tab.downloadsEnded.dropFirst(ended).first else { throw Failure("the download did not finish within 2 minutes") }
        return try result.get()
    }

    private func screenshot(_ tab: Tab, target: String?, fullPage: Bool) async throws -> NSImage {
        if windowHidden { throw Failure(MainWindow.notRendering) }
        let scale = tab.webView.pageZoom * tab.webView.magnification
        if let target {
            let json = try await tab.call(PageScripts.box, ["target": target])
            let box = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Double] ?? [:]
            let rect = CGRect(x: box["x"] ?? 0, y: box["y"] ?? 0, width: box["width"] ?? 0, height: box["height"] ?? 0)
                .intersection(CGRect(x: 0, y: 0, width: box["viewportWidth"] ?? 0, height: box["viewportHeight"] ?? 0))
            guard !rect.isEmpty else { throw Failure("\(target) has no visible area") }
            let config = WKSnapshotConfiguration()
            // Snapshot rects are in view points from the top of the page, below the toolbar band.
            config.rect = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
            return try await tab.snapshot(config)
        }
        let viewport = try await viewportSize(tab)
        guard fullPage else {
            // The view's bounds include the toolbar band; the page is the viewport.
            let config = WKSnapshotConfiguration()
            config.rect = CGRect(x: 0, y: 0, width: viewport.width * scale, height: viewport.height * scale)
            return try await tab.snapshot(config)
        }
        // takeSnapshot renders only the view's bounds, so the view grows to the page's height for the shot.
        let height = try await tab.call("return String(Math.max(document.documentElement.scrollHeight, document.body?.scrollHeight ?? 0))", world: .page)
        let full = CGSize(width: viewport.width, height: min(Double(height) ?? viewport.height, 16_384))
        let previous = tab.viewportSize
        defer { mainWindow.setSize(tab.webView, previous) }
        mainWindow.setSize(tab.webView, CGSize(width: full.width * scale, height: full.height * scale))
        _ = try await tab.call("await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))); return 'ok'")
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(x: 0, y: 0, width: full.width * scale, height: full.height * scale)
        return try await tab.snapshot(config)
    }

    /// `wait 1500` sleeps; otherwise polls until the target shows (or with --gone, leaves), the text or URL appears,
    /// or with --load the page has loaded and no fetch/XHR has been in flight for half a second.
    private func wait(_ tab: Tab, _ arg: String?, _ options: [String: String]) async throws -> String {
        let timeout = try options["timeout"].map { text -> Double in
            guard let ms = Double(text), (0...110_000).contains(ms) else { throw Failure("--timeout is milliseconds, up to 110000") }
            return ms / 1000
        } ?? 30
        if let arg, let ms = Double(arg) {
            guard (0...110_000).contains(ms) else { throw Failure("wait takes up to 110000 ms") }
            try await Task.sleep(for: .milliseconds(ms))
            return "### Result\nwaited \(Int(ms)) ms"
        }
        let what: String
        let check: () async throws -> Bool
        if let target = arg {
            let gone = options["gone"] != nil
            what = gone ? "\(target) to go" : target
            check = { try await tab.call(PageScripts.present, ["target": target, "gone": gone]) == "true" }
        } else if let text = options["text"] {
            what = "text \(text.debugDescription)"
            check = { try await tab.call(PageScripts.hasText, ["text": text]) == "true" }
        } else if let url = options["url"] {
            what = "a URL containing \(url)"
            check = { tab.webView.url?.absoluteString.contains(url) ?? false }
        } else if options["load"] != nil {
            what = "the page to load and the network to go quiet"
            var quietSince: Double?
            check = {
                let loaded = try await tab.call(PageScripts.quiet, world: .page) == "true"
                let quiet = loaded && !tab.webView.isLoading
                let now = ProcessInfo.processInfo.systemUptime
                quietSince = quiet ? quietSince ?? now : nil
                return quietSince.map { now - $0 >= 0.5 } ?? false
            }
        } else {
            throw Failure("use: agweb wait <ms> | <target> [--gone] | --text=… | --url=… | --load  [--timeout=ms]")
        }
        let start = ProcessInfo.processInfo.systemUptime
        while true {
            // A navigation in progress makes page scripts fail; that is "not yet". A bad selector never will be.
            do { if try await check() { break } } catch let error as Failure where error.description.contains("invalid selector") { throw error } catch {}
            if ProcessInfo.processInfo.systemUptime - start > timeout { throw Failure("timed out after \(Int(timeout)) s waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(100))
        }
        return "### Result\nwaited \(String(format: "%.1f", ProcessInfo.processInfo.systemUptime - start)) s for \(what)"
    }

    /// Paginated like printing, with print styles, unless `singlePage`: then one page of the screen view.
    private func pdf(_ tab: Tab, to url: URL, singlePage: Bool, paper: String?) async throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if singlePage {
            let data = try await withTimeout(30, "pdf") { try await tab.webView.pdf(configuration: WKPDFConfiguration()) }
            try data.write(to: url)
            return
        }
        guard let window = tab.webView.window else { throw Failure(MainWindow.notRendering) }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        if let paper {
            let sizes = ["a4": NSSize(width: 595, height: 842), "letter": NSSize(width: 612, height: 792), "legal": NSSize(width: 612, height: 1008)]
            guard let size = sizes[paper.lowercased()] else { throw Failure("--format is A4, Letter or Legal") }
            info.paperSize = size
        }
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        for side in [\NSPrintInfo.topMargin, \.bottomMargin, \.leftMargin, \.rightMargin] { info[keyPath: side] = 36 }
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        let operation = tab.webView.printOperation(with: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        // WebKit lays out for print only once the operation's view has a size.
        operation.view?.frame = tab.webView.bounds
        try? FileManager.default.removeItem(at: url)
        let done = PrintDone()
        // run() returns blank pages for WKWebView; the window-modal variant prints, and with no panels shows nothing.
        operation.runModal(for: window, delegate: done, didRun: #selector(PrintDone.printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
        for _ in 0..<300 where !done.finished { try await Task.sleep(for: .milliseconds(100)) }
        guard done.finished, done.success, FileManager.default.fileExists(atPath: url.path) else { throw Failure("printing to PDF failed") }
    }

    /// Sizes the tab's web view so the page sees `size` CSS pixels, correcting once for whatever WebKit insets.
    private func resize(_ tab: Tab, to size: CGSize) async throws {
        let scale = tab.webView.pageZoom * tab.webView.magnification
        var points = CGSize(width: size.width * scale, height: size.height * scale)
        tab.viewportSize = points
        mainWindow.setSize(tab.webView, points)
        try await Task.sleep(for: .milliseconds(100))
        let got = try await viewportSize(tab)
        if got != size {
            points = CGSize(width: points.width + (size.width - got.width) * scale, height: points.height + (size.height - got.height) * scale)
            tab.viewportSize = points
            mainWindow.setSize(tab.webView, points)
            try await Task.sleep(for: .milliseconds(100))
        }
        tab.pointer = nil
        tab.events.append("viewport is \(Int(size.width))x\(Int(size.height))")
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

    private func click(_ tab: Tab, target: String, button: MouseButton, js: Bool, forUpload: Bool, instant: Bool, clicks: Int = 1) async throws {
        if js {
            _ = try await tab.call(PageScripts.jsClick, ["target": target])
            return
        }
        let spot = try await locate(tab, target)
        // The element under the point counts too: a see-through select over styled text is common.
        if let picker = [spot.kind, spot.hitKind].first(where: Self.pickerKinds.contains) {
            throw Failure("\(picker) opens a native picker; use: agweb \(picker == "select" ? "select" : "fill") \(target) <value>")
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
        if button == .right { suppressMenus(tab) }
        for count in 1...clicks {
            if count > 1, !instant { try await Task.sleep(for: .seconds(tab.motion.jitter(0.09, 0.02))) }
            try NativeInput.button(tab.webView, button, down: true, at: point, viewportHeight: landed.viewport.height, clickCount: count, held: tab.held)
            tab.lastClick = (point, ProcessInfo.processInfo.systemUptime)
            // A short timeout: the press waits on this frame.
            if !instant { await tab.workspace.recorder?.capture(timeout: 0.3) }
            if !instant { try await Task.sleep(for: .seconds(tab.motion.jitter(0.095, 0.015))) }
            try NativeInput.button(tab.webView, button, down: false, at: point, viewportHeight: landed.viewport.height, clickCount: count, held: tab.held)
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
        try NativeInput.button(tab.webView, down: true, at: from, viewportHeight: landed.viewport.height, held: tab.held)
        tab.lastClick = (from, ProcessInfo.processInfo.systemUptime)
        if !instant { try await Task.sleep(for: .seconds(tab.motion.jitter(0.12, 0.03))) }
        let to = instant ? end.center : tab.motion.aim(center: end.center, size: end.size)
        // Drag code usually needs several moves to start, so even --instant takes a few straight steps.
        let path = instant ? (1...6).map { i in (CGPoint(x: from.x + (to.x - from.x) * Double(i) / 6, y: from.y + (to.y - from.y) * Double(i) / 6), 0.0) }
                           : tab.motion.path(from: from, to: to, targetSize: min(end.size.width, end.size.height))
        for (step, pause) in path {
            try NativeInput.move(tab.webView, to: step, viewportHeight: end.viewport.height, held: NativeInput.Held(modifiers: tab.held.modifiers, button: .left))
            tab.pointer = step
            if pause > 0 { try await Task.sleep(for: .seconds(pause)) }
        }
        if !instant { try await Task.sleep(for: .seconds(tab.motion.jitter(0.1, 0.03))) }
        try NativeInput.button(tab.webView, down: false, at: to, viewportHeight: end.viewport.height, held: tab.held)
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
            try NativeInput.move(tab.webView, to: step, viewportHeight: viewport.height, held: tab.held)
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
        var out = "### Page\n- URL: \(tab.currentURL)\n- Title: \(tab.currentTitle)"
        if windowHidden { out += "\n- Note: the window is closed or minimized; pages are frozen between commands (agweb show)" }
        // Only when the tabs changed since the agent last saw them: a popup opened, a tab closed, another is current.
        // A --raw reply drops the list, so it doesn't count as seen.
        let workspace = tab.workspace
        if workspace.tabs.count > 1, workspace.tabsShown != tabsSeen(workspace) {
            let saved = workspace.tabsShown
            out += "\n" + tabList(workspace)
            if workspace.rawReply { workspace.tabsShown = saved }
        }
        if !tab.events.isEmpty {
            out += "\n### Events\n" + tab.events.map { "- \($0)" }.joined(separator: "\n")
            tab.events.removeAll()
        }
        if tab.unreadErrors > 0 { out += "\n- Console: \(tab.unreadErrors) new errors (agweb console error)" }
        return out
    }

    private final class PrintDone: NSObject {
        var finished = false
        var success = false
        @objc func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
            self.success = success
            finished = true
        }
    }

    static func describe(profile: String?) -> String { profile.map { "profile \($0)" } ?? "fresh profile" }

    private func tabsSeen(_ workspace: Workspace) -> [Int] { workspace.tabs.map(\.id) + [workspace.currentID ?? -1] }

    private func tabList(_ workspace: Workspace) -> String {
        workspace.tabsShown = tabsSeen(workspace)
        return "### Tabs\n" + workspace.tabs.enumerated().map { index, tab in
            let current = tab.id == workspace.currentID ? " (current)" : ""
            return "- \(index):\(current) [\(tab.currentTitle)](\(tab.currentURL))" + (tab.state == "visible" ? "" : " (\(tab.state))")
        }.joined(separator: "\n")
    }
}
