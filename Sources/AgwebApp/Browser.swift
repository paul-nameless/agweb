import AppKit
import ImageIO
import UniformTypeIdentifiers
import WebKit
import AgwebCore

@MainActor
final class Browser {
    let model = BrowserModel()
    private(set) lazy var mainWindow = MainWindow(model: model)
    private let console = ConsoleSink()
    /// Values filled with --secret-cmd or --secret-file, in memory only; every workspace's replies hide them,
    /// since a profile's pages are shared.
    private var secrets: Set<String> = []
    private var queues: [String: Task<Response, Never>] = [:]
    /// Each workspace's running command and when it started, for a queued one that gives up.
    private var running: [String: (command: String, since: Date)] = [:]
    /// Each workspace's queued commands, in order, until their turn.
    private var waiting: [String: [Turn]] = [:]
    /// Unload.swift: the memory pressure source it listens to, and until when its last warning holds.
    var memoryPressure: DispatchSourceMemoryPressure?
    var pressureUntil = Date.distantPast
    private var nextTabID = 1
    var saveTask: Task<Void, Never>?
    var dashboardTask: Task<Void, Never>?
    /// The dashboard loop's wait; the window being shown again ends it early.
    var dashboardNap: Task<Void, Never>?
    var dashboardObserver: NSObjectProtocol?
    var dashboardRetake: Task<Void, Never>?
    /// The window has one keyboard: an agent's key or insertion holds it, and the next waits (withKeyboard).
    private var keyboardBusy = false
    private var keyboardWaiters: [CheckedContinuation<Void, Never>] = []
    /// What had the person's focus in the displayed tab when the window was covered (Visibility.swift).
    weak var coveredResponder: NSView?
    /// The tab the person last saw in the window (Visibility.swift).
    weak var shownTab: Tab?
    let usageSampler = UsageSampler()

    /// Tabs a person opens from the window, when no agent tab is displayed, live in this workspace.
    static let userWorkspace = "user"

    init() {
        console.browser = self
        NativeInput.onInput = { [weak self] webView in self?.tab(for: webView)?.agentInputAt = Date() }
        Passkeys.shared.browser = self
        FakeDevices.shared.browser = self
        FakeDevices.sweep()
        model.onDisplay = { [weak self] id, used in
            guard let self, let tab = self.model.displayedTab, tab.id == id else { return }
            self.mainWindow.bringToTop(tab.webView)
            self.updateVisibility()
            Task { try? await tab.loadIfPending() }
            if used { tab.markUsed() }
            self.scheduleSave()
        }
        model.onDashboard = { [weak self] open in self?.dashboardChanged(open) }
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let window = note.object as? NSWindow, window === self.mainWindow.window else { return }
                // Covered or uncovered: the displayed tab hides or shows (Visibility.swift).
                self.updateVisibility()
            }
        }
        let check = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.releaseSecureInput() } }
        check.tolerance = 0.1
        // The person's switch away leaves no half second. Again on the next turn, in case WebKit's own update on the
        // window resigning key comes after this notice and turns it back on.
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseSecureInput() }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.releaseSecureInput() } }
        }
        model.onCloseTab = { [weak self] tab in self?.closeTab(tab) }
        model.onSound = { [weak self] tab, heard in
            guard let self else { return }
            // Unmuting what the person muted on a shown tab goes back to the workspace's rule; a hidden one is heard.
            tab.personSound = heard ? (self.needsVisible(tab) ? nil : true) : false
            self.updateVisibility()
        }
        model.onCloseWorkspace = { [weak self] workspace in self?.closeWorkspace(workspace) }
        model.onNewTab = { [weak self] workspace in self?.newTabFromUser(in: workspace) }
        model.onNewWorkspace = { [weak self] name, profile in
            guard let self else { return nil }
            do {
                newTabFromUser(in: try existingOrNewWorkspace(named: name, profile: profile))
                scheduleSave()
                return nil
            } catch { return "\(error)" }
        }
    }

    // MARK: Workspaces and tabs

    func tab(for webView: WKWebView?) -> Tab? {
        model.workspaces.lazy.flatMap(\.tabs).first { $0.webView === webView }
    }

    func existingOrNewWorkspace(named name: String, profile: String?) throws -> Workspace {
        if let profile { try Self.checkProfileName(profile) }
        if let workspace = model.workspaces.first(where: { $0.name == name }) {
            if let profile, profile != workspace.profile {
                throw Failure("workspace \(name) already uses \(Self.describe(profile: workspace.profile)); close it first to switch")
            }
            return workspace
        }
        // Never at launch, before any store exists, so reopened workspaces always come back.
        if let profile, let pending = Profiles.pending(profile) { throw Failure(pending) }
        let workspace = Workspace(name: name, profile: profile, console: console)
        model.workspaces.append(workspace)
        return workspace
    }

    static func checkProfileName(_ profile: String) throws {
        if profile.trimmingCharacters(in: .whitespaces) != profile || profile.isEmpty {
            throw Failure("profile names can't be empty or start or end with spaces")
        }
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
        if let phone = opener?.phone {
            tab.phone = (phone.userAgent, nil)
            tab.webView.customUserAgent = phone.userAgent
            tab.viewportSize = opener?.viewportSize
            mainWindow.setSize(tab.webView, tab.viewportSize, centered: true)
        }
        updateVisibility()
        scheduleSave()
        return tab
    }

    /// `display: false` only adds it, for tabs reopened at launch.
    @discardableResult
    func addTab(to workspace: Workspace, display: Bool = true, lazy: Bool = false, seeds: [String: [String: String]] = [:]) -> Tab {
        let configuration = lazy || !seeds.isEmpty ? workspace.makeConfiguration(lazy: lazy, ownController: !seeds.isEmpty) : nil
        let tab = makeTab(in: workspace, configuration: configuration, opener: nil)
        if !seeds.isEmpty {
            tab.ownController = configuration?.userContentController
            tab.session = seeds
            tab.pendingSeeds = seeds
            workspace.installScripts()
        }
        if display { drive(tab) }
        return tab
    }

    /// A popup becomes the agent's tab only when the agent's own command opened it; an ad or a timer-opened
    /// window must not redirect the agent's next commands.
    func addPopup(to workspace: Workspace, configuration: WKWebViewConfiguration, opener: Tab) -> Tab {
        let tab = makeTab(in: workspace, configuration: configuration, opener: opener)
        // A sign-in popup asking for a passkey by itself counts as its opener's: the same click or command opened it.
        (tab.passkeyInputAt, tab.agentUntil) = (opener.passkeyInputAt, opener.agentUntil)
        if workspace.busy {
            drive(tab)
            return tab
        }
        // Opened by the page itself, not used: as fresh as the click on the opener that may have opened it.
        (tab.lastUsed, tab.usedClock) = (opener.lastUsed, opener.usedClock)
        if NSApp.isActive, model.displayedTabID == opener.id {
            model.display(tab.id, used: false)
        }
        return tab
    }

    /// A link opened with Cmd-click or the middle button: a tab after `opener` that loads without becoming current,
    /// as in any browser. Returns its index.
    func openInBackground(_ url: URL, from opener: Tab) -> Int {
        let tab = makeTab(in: opener.workspace, configuration: nil, opener: opener)
        tab.markUsed()
        tab.loadInBackground(url)
        return opener.workspace.tabs.firstIndex { $0 === tab } ?? -1
    }

    /// Makes `tab` the one its agent drives. The window follows only when someone is already watching that
    /// workspace, so one agent never yanks the view away from another.
    private func drive(_ tab: Tab) {
        let watching = model.displayedTab.map { $0.workspace === tab.workspace } ?? true
        tab.workspace.currentID = tab.id
        tab.markUsed()
        if watching { model.display(tab.id) }
        updateVisibility()
    }

    func closeTab(_ tab: Tab) {
        let workspace = tab.workspace
        guard let index = workspace.tabs.firstIndex(where: { $0 === tab }) else { return }
        Passkeys.shared.pageGone(tab, "the tab was closed")
        tab.cancelLoads()
        tab.finishLoad(Failure("the tab was closed"))
        tab.webView.stopLoading()
        tab.webView.navigationDelegate = nil
        tab.webView.uiDelegate = nil
        // Its handlers hold the console sink; a workspace's own controller is cleaned up with the workspace.
        tab.ownController?.removeAllScriptMessageHandlers()
        mainWindow.remove(tab.webView)
        tab.closePage()
        workspace.tabs.remove(at: index)
        tab.thumbnailTask?.cancel()
        tab.commandPictures?.cancel()
        deleteThumbnail(tab)
        if workspace.currentID == tab.id {
            let opener = tab.opener.flatMap { opener in workspace.tabs.contains { $0 === opener } ? opener : nil }
            workspace.currentID = opener?.id ?? (workspace.tabs.indices.contains(index) ? workspace.tabs[index] : workspace.tabs.last)?.id
        }
        if model.displayedTabID == tab.id {
            if let next = workspace.current ?? model.workspaces.lazy.flatMap(\.tabs).first {
                model.display(next.id, used: false)
            } else {
                model.displayedTabID = nil
            }
        }
        updateVisibility()
        scheduleSave()
    }

    private(set) var preparedToQuit = false

    /// Finishes every recording, since an MP4 without its index is unplayable, and saves session cookies.
    /// Quits for the swapped-in app to start; returns what quitting saved (videos).
    func restartAfterUpdate() async throws -> [String] {
        try Updater.relaunchAfterExit()
        let videos = await prepareToQuit()
        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0.2)
        return videos
    }

    func prepareToQuit() async -> [String] {
        var videos: [String] = []
        for workspace in model.workspaces { videos += await describeStop(workspace) }
        for tab in model.workspaces.flatMap(\.tabs) { await tab.captureSession() }
        await Profiles.saveSessionCookies()
        await captureForQuit()
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

    /// Pages already open get the fake devices now (main frames; frames get them at their next load).
    private func injectDevices(_ workspace: Workspace) {
        guard let shim = workspace.devicesShim else {
            // The handler is gone, so the pages' own "stopped" messages can't arrive: nothing keeps their tabs awake.
            for tab in workspace.tabs { tab.liveCaptures = 0 }
            updateVisibility()
            return
        }
        for tab in workspace.tabs where tab.pendingURL == nil && !tab.unloaded {
            tab.webView.evaluateJavaScript(shim, in: nil, in: .page) { _ in }
        }
    }

    func closeWorkspace(_ workspace: Workspace) {
        // From the sidebar, outside the workspace's queue; an agent's close has already stopped it.
        if workspace.recorder != nil { Task { _ = await describeStop(workspace) } }
        for tab in workspace.tabs { closeTab(tab) }
        workspace.contentController.removeAllScriptMessageHandlers()
        for kind in ["camera", "mic"] { workspace.setMedia(kind, nil) }
        model.workspaces.removeAll { $0 === workspace }
        if let profile = workspace.profile, !model.workspaces.contains(where: { $0.profile == profile }) { Profiles.release(profile) }
        scheduleSave()
    }

    private func newTabFromUser(in workspace: Workspace?) {
        guard let workspace = workspace ?? model.displayedTab?.workspace ?? (try? existingOrNewWorkspace(named: Self.userWorkspace, profile: nil)) else { return }
        let tab = makeTab(in: workspace, configuration: nil, opener: nil)
        model.dashboardOpen = false
        model.display(tab.id)
        mainWindow.focusAddress()
    }

    /// A link opened from another app: a new tab in the person's own workspace, never an agent's. The person
    /// clicked it, so the window comes forward.
    func openFromOutside(_ url: URL) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let workspace = try? existingOrNewWorkspace(named: Self.userWorkspace, profile: nil) else { return }
        let tab = makeTab(in: workspace, configuration: nil, opener: nil)
        model.dashboardOpen = false
        model.display(tab.id)
        Task { _ = try? await tab.load(url) }
        let window = mainWindow.window
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private var windowHidden: Bool { !MainWindow.isRendering(mainWindow.window) }

    // MARK: Commands

    /// Commands for one workspace run one at a time, in arrival order; different workspaces run concurrently.
    func handle(_ request: Request) async -> Response {
        // agweb works in the background, where App Nap would throttle its timers and main thread: a goto after idle took
        // 0.75 s instead of 0.37 s. Only while a command waits or runs; idle pages may still nap.
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "an agent's command")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let turn = Turn(command: request.command)
        let response = await enqueue(request, turn)
        #if AGWEB_COMMAND_LOG
        // execute logs what ran; one that gave up in the queue never got there.
        if turn.gaveUp != nil { CommandLogFile.append(request, response, started: turn.arrived) }
        #endif
        return response
    }

    private func enqueue(_ request: Request, _ turn: Turn) async -> Response {
        let workspace = request.workspace
        let previous = queues[workspace]
        waiting[workspace, default: []].append(turn)
        let work = Task { @MainActor () -> Response in
            _ = await previous?.value
            self.waiting[workspace]?.removeAll { $0 === turn }
            if let reason = turn.gaveUp { return Response(ok: false, output: reason) }
            turn.started = true
            self.running[workspace] = (request.command, Date())
            defer { self.running[workspace] = nil }
            // The compiled rules from last time, found in milliseconds: the first page after a launch is filtered too.
            await AdBlock.shared.loading?.value
            return await self.execute(request)
        }
        queues[workspace] = work
        // Queued behind a long command (a background `wait`), it would outlast the CLI, which then knows only that no
        // answer came: it gives up 10 s before, without running, and says what holds the workspace (`runLate` ones say
        // they will still run).
        guard let timeout = request.timeout, running[workspace] != nil || (waiting[workspace]?.count ?? 0) > 1 else { return await work.value }
        let deadline = Task { _ = try? await Task.sleep(for: .seconds(max(1, timeout - 10))) }
        turn.deadline = deadline
        Task { _ = await work.value; deadline.cancel() }
        _ = await deadline.value
        // All on the main actor: nothing starts between these checks and giving up. With nothing running, its turn has
        // come.
        if let reason = turn.gaveUp { return Response(ok: false, output: reason) }
        if turn.started || running[workspace] == nil { return await work.value }
        let what = running[workspace].map { "its \($0.command) has run \(Int(Date().timeIntervalSince($0.since))) s" } ?? ""
        if Self.runLate.contains(request.command) {
            return Response(ok: true, output: "workspace \(workspace) is busy (\(what)), so \(request.command) waits its turn and runs when that ends")
        }
        turn.gaveUp = "Error: workspace \(workspace) is busy (\(what)), so \(request.command) did not run: a workspace runs one command at a time, in order; run it after that one ends"
        // The ones queued behind it would run on a page it never prepared.
        for later in (waiting[workspace] ?? []).drop(while: { $0 !== turn }).dropFirst()
        where later.gaveUp == nil && !Self.runLate.contains(later.command) {
            later.gaveUp = "Error: workspace \(workspace) is busy, and \(request.command) queued before \(later.command) did not run, so neither did it"
            later.deadline?.cancel()
        }
        return Response(ok: false, output: turn.gaveUp!)
    }

    /// Run late rather than give up, answering that they will: they end things (a workspace, a recording, the app) or don't use the workspace.
    static let runLate: Set = ["close", "close-all", "video-stop", "quit", "update", "list", "dashboard", "install-skill",
                               "install-cli", "adblock", "unload", "sound", "profile"]

    /// A queued command's place: it runs when the one before ends, unless it gave up first (and why).
    private final class Turn {
        let command: String
        let arrived = Date()
        var started = false
        var gaveUp: String?
        var deadline: Task<Void, Never>?
        init(command: String) { self.command = command }
    }

    private func execute(_ request: Request) async -> Response {
        defer {
            // A fill or click on a password field; the timer would also catch it, later if App Nap slows it.
            releaseSecureInput()
            if let workspace = model.workspaces.first(where: { $0.name == request.workspace }) {
                // Its own command ran (global ones like `list` leave it unbusy): an hour-long `ask` ends as use, for the
                // tab it acted on too.
                if workspace.busy {
                    workspace.lastUsed = Date()
                    workspace.actedOn?.lastUsed = workspace.lastUsed
                }
                workspace.busy = false
                if workspace.passkeyCommand { workspace.current?.agentUntil = Date().addingTimeInterval(Passkeys.grace) }
                // A command returning before it sets the flag (`list`) must not inherit the last one's.
                workspace.passkeyCommand = false
                // Only after a command that acted on a page (`list` or `cookie-list` polling must not keep a tab awake),
                // and the tab it left current: a popup or tab-select moves the agent on.
                if workspace.actedOn != nil, let tab = workspace.current {
                    keepAwakeAfterCommand(tab)
                    captureAfterCommand(tab)
                    Task { await tab.captureSession() }
                }
                workspace.actedOn = nil
                updateVisibility()
            }
            scheduleSave()
        }
        #if AGWEB_COMMAND_LOG
        let started = Date()
        #endif
        let response: Response
        do {
            var output = try await run(request)
            // After the Page section's Title line; a page's own text can't hold "### Page\n" (text escapes it).
            if let tab = model.workspaces.first(where: { $0.name == request.workspace })?.current, tab.challenged || tab.authWall != nil,
               let page = output.range(of: "### Page\n", options: .backwards),
               let title = output.range(of: "\n- Title: ", range: page.upperBound..<output.endIndex) {
                var note = ""
                if let wall = tab.authWall { note = authNote(tab, wall) } else { note = await challengeNote(tab) }
                let end = output[title.upperBound...].firstIndex(of: "\n") ?? output.endIndex
                output.insert(contentsOf: "\n- Note: " + note, at: end)
            }
            response = Response(ok: true, output: Self.hide(secrets, in: output))
        } catch {
            var message = "\(error)"
            // The ref's element is gone, so say what it was: the agent may have acted on it several replies ago.
            if let match = message.firstMatch(of: #/ref (e\d+) not found/#),
               let workspace = model.workspaces.first(where: { $0.name == request.workspace }),
               let label = (workspace.actedOn ?? workspace.current)?.refLabels[String(match.1)] {
                message.insert(contentsOf: " (\(label))", at: match.1.endIndex)
            }
            // A popup that opened meanwhile, or an alert: a success reply would have said so (describe), so a failure does too.
            if let workspace = model.workspaces.first(where: { $0.name == request.workspace }), workspace.actedOn != nil {
                if workspace.tabs.count > 1, workspace.tabsShown != tabsSeen(workspace) { message += "\n" + tabList(workspace) }
                if let tab = workspace.actedOn, !tab.events.isEmpty {
                    message += "\n### Events\n" + tab.events.map { "- \($0)" }.joined(separator: "\n")
                    tab.events.removeAll()
                }
            }
            response = Response(ok: false, output: Self.hide(secrets, in: "Error: " + message))
        }
        // A fill or script may have moved a rich editor's caret: kept as it left it, for the next key (another tab taking
        // the keyboard meanwhile would make WebKit put it at the start).
        if Self.caretCommands.contains(request.command), let tab = model.workspaces.first(where: { $0.name == request.workspace })?.actedOn {
            tab.caretKept = (try? await tab.call(PageScripts.keepSelection, ["mode": "save"], timeout: 2)) != nil
        }
        #if AGWEB_COMMAND_LOG
        CommandLogFile.append(request, response, started: started)
        #endif
        return response
    }

    private func run(_ request: Request) async throws -> String {
        let args = request.args
        let options = request.options
        func arg(_ i: Int, _ name: String) throws -> String {
            guard args.indices.contains(i) else { throw Failure("missing <\(name)>") }
            return args[i]
        }
        // These read no target as the whole page; an empty one is an unset shell variable, not that.
        if ["snapshot", "markdown", "highlight"].contains(request.command), let target = args.first, target.trimmingCharacters(in: .whitespaces).isEmpty {
            throw Failure("invalid selector \"\(target)\": \(PageScripts.emptyTarget)")
        }

        switch request.command {
        case "dashboard":
            model.dashboardOpen = options["hide"] == nil
            guard model.dashboardOpen else { return "dashboard hidden" }
            mainWindow.showQuietly()
            guard let path = options["filename"] else { return "dashboard shown" }
            // Pictures of the tabs an agent is on and of those without one first, then a moment for the grid to draw
            // them; at most 3 s, as tabs that don't answer (a minimized window, a stuck page) take 3 s each.
            _ = try? await withTimeout(3, "thumbnails") { await self.refreshThumbnails() }
            // The figures and clock too: the loop waits while the window is covered, as it often is here, and a first
            // sample after a wait has no CPU yet, so a second one half a second later.
            model.dashboardNow = Date()
            if Settings.store.bool(forKey: Settings.showUsage), model.processes.isEmpty || model.processes.values.contains(where: { $0.usage.cpu == nil }) {
                model.processes = usageSampler.sample()
                try await Task.sleep(for: .milliseconds(500))
                model.processes = usageSampler.sample()
            }
            try await Task.sleep(for: .milliseconds(300))
            guard let png = mainWindow.dashboardPNG() else { throw Failure("could not draw the dashboard") }
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: url)
            return "dashboard shown\n### Screenshot\n\(path)"
        case "list":
            if options["json"] != nil {
                let stamp = ISO8601DateFormatter()
                let list = model.workspaces.map { workspace -> [String: Any] in
                    ["name": workspace.name, "profile": workspace.profile ?? NSNull(), "busy": workspace.busy,
                     "lastUsed": stamp.string(from: workspace.lastUsed),
                     "tabs": workspace.tabs.enumerated().map { index, tab in
                         ["index": index, "url": tab.currentURL, "title": tab.currentTitle, "current": tab.id == workspace.currentID,
                          "state": tab.state, "asking": tab.asking ?? NSNull(), "lastUsed": stamp.string(from: tab.lastUsed)]
                     }]
                }
                return String(decoding: try JSONSerialization.data(withJSONObject: ["workspaces": list, "dashboard": model.dashboardOpen],
                                                                   options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
            }
            if model.workspaces.isEmpty { return "no workspaces" }
            // A tree: each profile, the workspaces on it, their tabs. A workspace has one profile for its life.
            let named = Dictionary(grouping: model.workspaces.filter { $0.profile != nil }, by: { $0.profile! })
            let groups = named.keys.sorted().map { ("profile \($0)", named[$0]!) }
                + [("fresh profile (each workspace its own, in memory)", model.workspaces.filter { $0.profile == nil })]
            return groups.filter { !$0.1.isEmpty }.map { title, workspaces in
                title + "\n" + workspaces.map { workspace in
                    "  - \(workspace.name) (\(workspace.tabs.count) tab\(workspace.tabs.count == 1 ? "" : "s"), used \(Clip.ago(Date().timeIntervalSince(workspace.lastUsed))))"
                        + workspace.tabs.enumerated().map { index, tab in
                            let current = tab.id == workspace.currentID ? " (current)" : ""
                            let notes = (tab.state == "visible" ? [] : [tab.state]) + ["used \(Clip.ago(Date().timeIntervalSince(tab.lastUsed)))"]
                            return "\n    - \(index):\(current) [\(tab.currentTitle)](\(tab.currentURL)) (\(notes.joined(separator: ", ")))"
                        }.joined()
                }.joined(separator: "\n")
            }.joined(separator: "\n")
        case "close-all":
            var lines: [String] = []
            for workspace in model.workspaces {
                lines += await describeStop(workspace)
                closeWorkspace(workspace)
                lines.append("workspace \(workspace.name) closed")
            }
            return lines.isEmpty ? "no workspaces" : lines.joined(separator: "\n")
        case "install-skill":
            if options["check"] != nil { return SkillInstaller.agents.map { "\($0.name): \(SkillInstaller.status($0.folder))" }.joined(separator: "\n") }
            return SkillInstaller.install().joined(separator: "\n")
        case "adblock":
            // Agents switch it for their own workspace only; the whole instance is the person's call, in Settings.
            let workspace = model.workspaces.first { $0.name == request.workspace }
            switch args.first {
            case nil, "status": break
            case "on", "off":
                guard let workspace else {
                    throw Failure("no workspace '\(request.workspace)'; adblock on|off applies to one open workspace: agweb -w NAME adblock off")
                }
                workspace.adBlockOff = args.first == "off"
                AdBlock.shared.apply()
            case "update":
                guard AdBlock.shared.enabled else { throw Failure("ad blocking is off in Settings") }
                await AdBlock.shared.update(force: true).value
            case let other?: throw Failure("adblock takes on, off, update or nothing, not \(other)")
            }
            return AdBlock.shared.status(for: workspace)
        case "unload", "sound":
            // Per workspace, kept across restarts: unload off keeps its pages loaded and its current tab running, sound on
            // lets them be heard hidden.
            let name = request.command
            guard let workspace = model.workspaces.first(where: { $0.name == request.workspace }) else {
                throw Failure("no workspace '\(request.workspace)'; \(name) on|off applies to one open workspace: agweb -w NAME \(name) \(name == "unload" ? "off" : "on")")
            }
            switch args.first {
            case nil, "status": break
            case "on", "off":
                let on = args.first == "on"
                if name == "unload" { workspace.unloadOff = !on } else { workspace.soundOn = on }
                updateVisibility()
                scheduleSave()
            case let other?: throw Failure("\(name) takes on or off, not \(other)")
            }
            return name == "unload"
                ? (workspace.unloadOff ? "unload off: this workspace's tabs keep their pages however long they sit unused, and its current tab keeps running unseen while the window is open" : "unload on: a tab unused for a while is unloaded to free memory and reloads when used")
                : (workspace.soundOn ? "sound on: this workspace's tabs are heard even while hidden" : "sound off: this workspace's tabs are muted while hidden")
        case "profile" where (args.first ?? "list") == "list":
            let names = Profiles.names
            if names.isEmpty { return "no named profiles; open a workspace with -p NAME to create one" }
            return names.map { name in
                let users = model.workspaces.filter { $0.profile == name }.map(\.name)
                return "- \(name)" + (Profiles.proxyNote(name).map { " (\($0))" } ?? "") + (users.isEmpty ? "" : ": " + users.joined(separator: ", "))
            }.joined(separator: "\n")
        case "profile" where args.first == "delete":
            let name = try arg(1, "name")
            let users = model.workspaces.filter { $0.profile == name }.map(\.name)
            guard users.isEmpty else { throw Failure("profile \(name) is in use by \(users.joined(separator: ", ")); close them first") }
            try await Profiles.delete(name)
            return "profile \(name) deleted"
        case "profile" where args.first == "set":
            let name = try arg(1, "name")
            try Self.checkProfileName(name)
            let key = try arg(2, "key")
            guard key == "proxy" else { throw Failure("unknown key \(key); keys: proxy") }
            let value = try arg(3, "url or off")
            var spec: ProxySpec?
            if value != "off" {
                spec = try ProxySpec.parse(value)
                // The CLI sends the password apart, as an option: arguments go into the command log.
                guard spec?.password == nil else { throw Failure("send the proxy's password through the agweb CLI, which keeps it out of the command's arguments") }
                spec?.password = options["proxy-password"]
                try spec?.validate()
            } else if !Profiles.names.contains(name), Profiles.savedRoute(name) == .direct {
                throw Failure("no profile \(name); see agweb profile list")
            }
            let saved = spec.map { "proxy \($0)" + ($0.password == nil ? "" : ", password saved") } ?? "no proxy"
            guard let old = try Profiles.setProxy(name, spec) else { return "profile \(name): \(saved)" }
            return "profile \(name): \(saved). It was opened in this run, so this applies when agweb next starts; until then its "
                + "workspaces keep \(old) and new workspaces on it are refused. Quitting agweb interrupts every agent's "
                + "workspaces, so leave that to the person"
        case "profile":
            throw Failure("profile takes list, set or delete, not \(args[0])")
        case "update":
            let release = try await Updater.latest()
            guard Version.isNewer(release.version, than: Updater.current) else { return "agweb \(Updater.current) is the latest" }
            if options["check"] != nil {
                return "agweb \(release.version) is out (you have \(Updater.current)): \(release.page.absoluteString)\n"
                    + (Updater.blocker() ?? "install it with: agweb update")
            }
            try await Updater.install(release)
            return (["updated to \(release.version); agweb restarts and reopens every workspace"] + (try await restartAfterUpdate())).joined(separator: "\n")
        case "quit":
            let videos = await prepareToQuit()
            // Not from a main-queue block: terminate would spin the run loop inside it, starving the main queue.
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0.2)
            return (["bye"] + videos).joined(separator: "\n")
        case "open":
            let workspace = try existingOrNewWorkspace(named: request.workspace, profile: options["profile"])
            if let refusal = Profiles.refusal(workspace.profile) { throw Failure(refusal) }
            workspace.downloadDir = options["download-dir"].map { URL(fileURLWithPath: $0) } ?? workspace.downloadDir
            workspace.rawReply = options["raw"] != nil
            workspace.lastCommand = Self.summary(request)
            workspace.lastCommandAt = Date()
            workspace.lastUsed = Date()
            workspace.passkeyCommand = Passkeys.commands.contains(request.command)
            workspace.busy = true
            mainWindow.showQuietly()
            let tab = workspace.current ?? addTab(to: workspace)
            tab.agentInputAt = Date()
            await wake(tab)
            if let text = args.first {
                let url = try Address.url(text)
                try storeBasicAuth(options, for: url, in: workspace)
                if let saved = try await goto(tab, url, headers: try headers(options), to: options["filename"]) {
                    return "### Download\n\(saved)\n" + describe(tab)
                }
            } else {
                try await tab.loadIfPending()
            }
            tab.markSeen()
            return describe(tab)
        default:
            break
        }

        guard let workspace = model.workspaces.first(where: { $0.name == request.workspace }) else {
            guard Commands.all.contains(request.command) else { throw Failure(Commands.unknown(request.command)) }
            throw Failure("no workspace '\(request.workspace)'; start it with: agweb -w \(request.workspace) open [url]")
        }
        if let profile = options["profile"], profile != workspace.profile {
            throw Failure("workspace \(workspace.name) uses \(Self.describe(profile: workspace.profile)), not profile \(profile); close it and open it with -p \(profile)")
        }
        // Its pages load nothing; a reopened tab would otherwise act on a blank page that still shows its saved URL.
        if let refusal = Profiles.refusal(workspace.profile), !["close", "tab-list", "tab-close"].contains(request.command) {
            throw Failure(refusal)
        }
        workspace.downloadDir = options["download-dir"].map { URL(fileURLWithPath: $0) } ?? workspace.downloadDir
        workspace.rawReply = options["raw"] != nil
        workspace.lastCommand = Self.summary(request)
        workspace.lastCommandAt = Date()
        workspace.lastUsed = Date()
        workspace.passkeyCommand = Passkeys.commands.contains(request.command)
        workspace.busy = true

        switch request.command {
        case "passkey" where (args.first ?? "list") == "list":
            let owner = PasskeyOwner(workspace)
            let whose = workspace.profile.map { "profile \($0)" } ?? "fresh workspace \(workspace.name), in memory"
            let off = Passkeys.shared.enabled ? "" : "\nPasskeys are off in Agweb's Settings: sites get no answer from agweb."
            let list = Passkeys.shared.list(owner)
            let key = Passkeys.shared.usesKey(owner) ? "\nSecurity keys on: sign-ups, and sign-ins none of these answer, go to the key plugged into this Mac (agweb passkey hardware)." : ""
            if list.isEmpty { return "no passkeys in \(whose); a site's sign-up or \"add a passkey\" button creates one" + key + off }
            let date = Date.FormatStyle(date: .numeric, time: .shortened)
            return "### Passkeys (\(whose))\n" + list.map { passkey in
                "- \(passkey.id): \(passkey.label), created \(passkey.created.formatted(date))"
                    + (passkey.lastUsed.map { ", last used \($0.formatted(date))" } ?? "")
            }.joined(separator: "\n") + key + off
        case "passkey" where args.first == "hardware":
            // Status only: the person switches security keys on, in Settings.
            if let wanted = args.dropFirst().first, wanted != "status" {
                throw Failure("only the person turns security keys \(wanted == "off" ? "off" : "on"), in Agweb's Settings ▸ Passkeys; agweb passkey hardware shows whether they're on")
            }
            return Passkeys.shared.keyStatus(workspace)
        case "passkey" where args.first == "delete":
            let id = try arg(1, "id")
            let removed = try Passkeys.shared.agentDelete(id, PasskeyOwner(workspace))
            return "deleted the passkey for \(removed.label); the site still lists it until it's removed in the account's settings there"
        case "passkey":
            throw Failure("use: agweb passkey list | passkey delete <id> | passkey hardware")
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
            if let url = args.first {
                // Loading it is the agent's work, though nothing wakes it: the green dot shows meanwhile.
                let address = try Address.url(url)
                workspace.working(on: tab)
                if let saved = try await goto(tab, address, to: options["filename"]) {
                    return "### Download\n\(saved)\n" + describe(tab)
                }
                // The list shows where it landed; left pending, the note would sit by the next command's URL.
                tab.events.removeAll { $0.hasPrefix("redirected") }
            }
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
        case "video-stop":
            guard let video = try await workspace.stopRecording() else { throw Failure("not recording; run video-start") }
            return video
        case "show":
            // Shows the agent's tab inside the window; never raises or activates the app.
            guard let tab = workspace.current else { throw Failure("workspace has no tabs") }
            model.display(tab.id)
            mainWindow.showQuietly(evenIfPutAway: true)
            return describe(tab)
        case "route":
            var route = Workspace.Route(pattern: try arg(0, "pattern"))
            route.status = try options["status"].map { text in
                guard let status = Int(text), (100...599).contains(status) else { throw Failure("--status is an HTTP status code") }
                return status
            }
            route.body = options["body"]
            route.contentType = options["content-type"]
            route.headers = try headers(options)
            workspace.routes = workspace.routes.filter { $0.pattern != route.pattern } + [route]
            return "fetch and XHR calls matching \(route.pattern) get \(route.status ?? 200)\n" + routeList(workspace)
        case "route-list":
            return routeList(workspace)
        case "media":
            if args.first == "off" {
                for kind in ["camera", "mic"] { workspace.setMedia(kind, nil) }
                injectDevices(workspace)
                return workspace.describeMedia()
            }
            if let other = args.first { throw Failure("media takes FILE, --camera FILE, --mic FILE, off or nothing, not \(other)") }
            var chosen: [String: FakeDevices.Source] = [:]
            if let path = options["file"] { chosen = try await FakeDevices.prepare(path, for: ["camera", "mic"]) }
            for kind in ["camera", "mic"] {
                guard let path = options[kind] else { continue }
                chosen.merge(try await FakeDevices.prepare(path, for: [kind])) { _, new in new }
            }
            for (kind, source) in chosen { workspace.setMedia(kind, source) }
            injectDevices(workspace)
            return workspace.describeMedia()
        case "geolocation":
            switch args.first {
            case nil: break
            case "off":
                workspace.geolocation = nil
                injectDevices(workspace)
            default:
                guard args.count == 2, let latitude = Double(args[0]), let longitude = Double(args[1]),
                      (-90...90).contains(latitude), (-180...180).contains(longitude) else {
                    throw Failure("geolocation takes a latitude (-90 to 90) and a longitude (-180 to 180), e.g. geolocation 51.5074 -0.1278, or off")
                }
                let accuracy = try options["accuracy"].map { text in
                    guard let meters = Double(text), meters > 0, meters <= 1_000_000 else { throw Failure("--accuracy is in meters, above 0 and up to 1000000") }
                    return meters
                } ?? 20
                workspace.geolocation = Geolocation(latitude: latitude, longitude: longitude, accuracy: accuracy)
                injectDevices(workspace)
            }
            guard let at = workspace.geolocation else { return "no geolocation set; pages are refused a position" }
            return "geolocation: \(at.latitude), \(at.longitude) (accuracy \(Int(at.accuracy)) m)"
        case "unroute":
            let before = workspace.routes.count
            workspace.routes = args.first.map { pattern in workspace.routes.filter { $0.pattern != pattern } } ?? []
            return "removed \(before - workspace.routes.count) routes\n" + routeList(workspace)
        case "cookie-list", "cookie-get", "cookie-set", "cookie-delete", "cookie-clear":
            return try await cookies(request, in: workspace)
        case "clipboard":
            return workspace.clipboard?.describe()
                ?? "### Result\n\"\"\n### Events\n- the workspace clipboard is empty: no page here copied anything yet (clipboard-set <text> puts text there)"
        case "clipboard-set":
            guard args.count == 1 else { throw Failure("clipboard-set takes one text; quote it: agweb clipboard-set 'two words'") }
            let text = try arg(0, "text")
            workspace.clipboard = Clip(items: [Clip.Item(type: "text/plain", value: text)], source: "clipboard-set")
            return "the workspace clipboard holds \(text.count) characters: press Meta+v pastes them at the focus, and the page's clipboard reads get them"
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
        // Their scripts run with a user gesture too (a --js click, eval), so the page may copy. After the load: a page
        // commit forgets the input given to the page before.
        if Self.reportsChanges.contains(request.command) || Self.mayRunPageCode.contains(request.command) { tab.agentInputAt = Date() }
        let webView = tab.webView
        // Otherwise a go-back from there lands on a page the agent never saw, with nothing saying why.
        if tab.movedSinceSeen {
            tab.events.append("the tab moved since your last command, to \(tab.currentURL) (a click in the window or the page itself); agweb history lists the way")
        }
        defer {
            tab.markSeen()
            if ["goto", "reload", "go-back", "go-forward"].contains(request.command) { tab.navigatedCommits = tab.commits }
        }
        let instant = options["instant"] != nil
        if options["js"] == nil {
            let targets = request.command == "drag" ? Array(args.prefix(2)) : request.command == "mousewheel" ? Array(args.dropFirst(2).prefix(1)) : Self.actsOnTarget.contains(request.command) ? Array(args.prefix(1)) : []
            for target in targets { try await awaitTarget(tab, target, request.command, options) }
            // Calls the page made while the action waited are not the action's.
            tab.commandStart = Date().timeIntervalSince1970 * 1000
        }
        // The page changed since the agent's snapshot (a goto, a reload, a redirect of its own): this action's Changes
        // start from the page as it is now, not from the old one, which would read as this action navigating.
        // Only for the agent's own goto, reload or history step: a page that moved on by itself after the last action
        // (a form sent by script) did navigate, and the reply says so. Not for wait, which may see such a load.
        if Self.reportsChanges.contains(request.command), tab.snapshots[""] != nil, tab.baselineCommits != tab.commits,
           tab.commits == tab.navigatedCommits {
            let commits = tab.commits
            tab.snapshots[""] = try? await snapshotTree(tab, "")
            tab.baselineCommits = commits
            // Calls the page made meanwhile are not the action's.
            tab.commandStart = Date().timeIntervalSince1970 * 1000
        }
        let urlBefore = tab.currentURL

        switch request.command {
        case "goto":
            let url = try Address.url(try arg(0, "url"))
            try storeBasicAuth(options, for: url, in: workspace)
            if let saved = try await goto(tab, url, headers: try headers(options), to: options["filename"]) {
                return "### Download\n\(saved)\n" + describe(tab)
            }
        case "reload":
            // Before the call: WebKit may ask about the navigation before reload() returns.
            tab.resubmitAllowed = true
            if webView.reload() == nil { tab.resubmitAllowed = false }
            await tab.settle()
        case "go-back":
            guard webView.goBack() != nil else { return describe(tab, note: "no earlier page in this tab, so go-back did nothing") }
            await tab.settle()
        case "go-forward":
            guard webView.goForward() != nil else { return describe(tab, note: "no later page in this tab, so go-forward did nothing") }
            await tab.settle()
        case "history":
            // WebKit leaves out, and go-back skips, a page that moved on or pushed an entry by script without a click.
            let length = (try? await tab.call("return String(history.length)", world: .page, timeout: 2)).flatMap { Int($0) }
            guard let limit = Int(options["max-results"] ?? "10"), limit > 0 else { throw Failure("--max-results is a number above 0") }
            return describe(tab) + "\n" + Self.history(webView.backForwardList, length: length, limit: limit)
        case "snapshot":
            let target = args.first ?? ""
            // --filename (the CLI writes the file) takes every line; past the cap it isn't kept for diffs, which compare capped trees.
            let whole = options["whole"] != nil && options["diff"] == nil
            let commits = tab.commits
            let snapshot = try await snapshotTree(tab, target, whole: whole)
            let last = tab.snapshots[target]
            if tab.snapshots.count > 8 { tab.snapshots = tab.snapshots.filter { $0.key.isEmpty } }
            if !whole || snapshot.tree.utf8.lazy.filter({ $0 == 10 }).count < PageScripts.maxSnapshotLines {
                tab.snapshots[target] = snapshot
                if target.isEmpty { tab.baselineCommits = commits }
            }
            let tree = snapshot.tree
            // Refs last as long as their element, so a line that didn't change is the same element.
            if options["diff"] != nil, let last, last.doc == snapshot.doc {
                return describe(tab) + "\n### Changes\n" + (Snapshot.diff(from: last.tree, to: tree) ?? "no changes since the last snapshot")
            }
            let note = options["diff"] != nil ? "no earlier snapshot of this page, so this is all of it" : nil
            return describe(tab, note: note) + "\n### Snapshot\n" + (tree.isEmpty ? "(nothing visible)" : tree)
        case "ask":
            return try await ask(tab, try arg(0, "message"), args.count > 1 ? args[1] : nil, options) + "\n" + describe(tab)
        case "find":
            let query = try arg(0, "text")
            guard let max = Int(options["max-results"] ?? "20"), max > 0 else { throw Failure("--max-results is a number above 0") }
            // The whole page, not the snapshot's first 2000 lines; --filename (the CLI writes the file) keeps every match.
            let toFile = options["whole"] != nil
            let tree = try await snapshotTree(tab, "", whole: true).tree
            guard let found = Snapshot.find(query, in: tree, max: toFile ? .max : max) else {
                throw Failure("nothing on the page matches \(query.debugDescription)")
            }
            var lines = found.tree.split(separator: "\n", omittingEmptySubsequences: false)
            if !toFile, lines.count > PageScripts.maxSnapshotLines {
                let more = lines.last.flatMap { $0.hasPrefix("- (") && $0.hasSuffix("more; --max-results to see them)") ? $0 : nil }
                lines = lines.prefix(PageScripts.maxSnapshotLines) + ["- (cut at \(PageScripts.maxSnapshotLines) lines; find --filename saves every match)"] + (more.map { [$0] } ?? [])
            }
            return describe(tab) + "\n### Found\n\(found.matches) line\(found.matches == 1 ? "" : "s") matching \(query.debugDescription)\n" + lines.joined(separator: "\n")
        case "markdown":
            let all = options["all"] != nil
            let text = try await pageText(tab, target: args.first, all: all)
            // An inactive tab panel or a closed menu: empty with nothing said looks like a broken page.
            let empty = args.first.flatMap { target in
                text.hidden ? "\(target) is hidden on the page (an inactive tab panel, a closed menu); show it first, e.g. click its tab"
                    : text.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "\(target) shows no text yet; it may fill once loaded (wait --text)" : nil }
            let note = empty ?? (all ? nil : text.huge > 0 ? "a very large page (\(text.huge) elements), so this is all of it, not only its article; markdown <target> reads one part"
                : text.whole ? "no article here, so this is the whole page"
                : text.shown > 300 && text.kept * 2 < text.shown ? "main content only: \(text.kept) of \(text.shown) words on the page; markdown --all for all of it" : nil)
            let images = text.dropped == 0 ? nil
                : "\(text.dropped) inline image\(text.dropped == 1 ? "" : "s") shortened to alt text (data: URLs); snapshot lists them with refs to screenshot"
            let notes = [note, images].compactMap { $0 }
            return "### Result\n" + Output.demoteTitles(text.markdown) + "\n" + describe(tab, note: notes.isEmpty ? nil : notes.joined(separator: "; "))
        case "click", "dblclick":
            try await click(tab, target: try arg(0, "target"), button: try MouseButton(args.count > 1 ? args[1] : nil), js: options["js"] != nil,
                            forUpload: false, instant: instant, clicks: request.command == "dblclick" ? 2 : 1, refuseCovered: coverPatience(options))
            await tab.settle()
        case "check", "uncheck":
            let target = try arg(0, "target")
            let want = request.command == "check" ? "checked" : "unchecked"
            let state = try await tab.call(PageScripts.checkedState, ["target": target])
            if state == "none" { throw Failure("\(target) is not a checkbox, radio or switch") }
            if state != want {
                if options["js"] == nil { try await awaitTarget(tab, target, request.command, options, enabled: true) }
                try await click(tab, target: target, button: .left, js: options["js"] != nil, forUpload: false, instant: instant)
                await tab.settle()
                if try await tab.call(PageScripts.checkedState, ["target": target]) != want { throw Failure("clicked \(target) but it is still \(state)") }
            }
        case "drag":
            try await drag(tab, from: try arg(0, "from"), to: try arg(1, "to"), instant: instant)
            await tab.settle()
        case "mousewheel":
            guard let dx = Double(try arg(0, "dx")), let dy = Double(try arg(1, "dy")), abs(dx) <= 1e6, abs(dy) <= 1e6 else {
                throw Failure("use: agweb mousewheel <dx> <dy> [target] in CSS pixels up to 1000000; positive dy scrolls down")
            }
            // A target gets the pointer first, so the wheel scrolls it (an editor, a list) rather than what the pointer was over.
            if args.count > 2 {
                var spot = try await locate(tab, args[2], instant: instant)
                if spot.size.width == 0 || spot.size.height == 0 { throw Failure("\(args[2]) has no size on screen; snapshot again") }
                // One taller or wider than the viewport: the pointer goes to the part that shows.
                let shown = CGRect(x: spot.center.x - spot.size.width / 2, y: spot.center.y - spot.size.height / 2, width: spot.size.width, height: spot.size.height)
                    .intersection(CGRect(origin: .zero, size: spot.viewport))
                if !shown.isNull, shown.width > 0, shown.height > 0 { spot.center = CGPoint(x: shown.midX, y: shown.midY); spot.size = shown.size }
                let landed = try await glide(tab, onto: args[2], from: spot, instant: instant).spot
                if let covered = landed.covered { tab.events.append("\(args[2]) is covered by \(covered), which the wheel scrolls instead") }
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
            try await withMouse(tab) { try NativeInput.button(webView, button, down: down, at: at, viewportHeight: viewport.height, held: tab.held) }
            tab.held.button = down ? button : nil
            if down { tab.lastClick = (at, ProcessInfo.processInfo.systemUptime) }
            if !down { await tab.settle() }
        case "upload":
            let target = try arg(0, "target")
            guard args.count > 1 else { throw Failure("missing <file>") }
            if let missing = args.dropFirst().first(where: { !FileManager.default.isReadableFile(atPath: $0) }) {
                throw Failure("no such file: \(missing)")
            }
            tab.pendingUpload = args.dropFirst().map { URL(fileURLWithPath: $0) }
            tab.chooserOpened = false
            // Whatever happens, the files must not linger for the next chooser on this tab.
            defer { tab.pendingUpload = nil }
            try await click(tab, target: target, button: .left, js: options["js"] != nil, forUpload: true, instant: instant)
            for _ in 0..<30 where !tab.chooserOpened { try await Task.sleep(for: .milliseconds(100)) }
            guard tab.chooserOpened else {
                // The click may have done something else (opened a dialog): the agent's snapshot is then stale.
                let changed = await changes(tab, urlBefore: urlBefore)
                throw Failure("no file chooser opened; the click on \(target) went through" + (changed.isEmpty ? "" : " and the page changed")
                              + "; target the <input type=file> or the button that opens it" + changed)
            }
            await tab.settle()
        case "download":
            return "### Download\n" + (try await download(tab, target: try arg(0, "target"), to: options["filename"], js: options["js"] != nil, instant: instant,
                                                         refuseCovered: coverPatience(options))) + "\n" + describe(tab)
        case "fill", "select":
            let secret = options["secret"] != nil
            if secret { secrets.insert(try arg(1, "text")) }
            _ = try await tab.call(PageScripts.fill, ["target": try arg(0, "target"), "text": try arg(1, request.command == "select" ? "value" : "text"),
                                                      "onlySelect": request.command == "select", "secret": secret])
            if options["submit"] != nil { try await pressKey(tab, "Enter", instant: instant) }
        case "type":
            // playwright-cli's type takes only text; a target in front would be typed as text.
            guard args.count == 1 else {
                throw Failure("type takes only the text and types where the focus is; to type into an element: fill <target> <text>, or click <target> then type <text>")
            }
            let text = try arg(0, "text")
            // Keys go to the focused frame, a cross-origin one included.
            let frame = await tab.focusedFrame()
            if instant || text.isEmpty {
                try await insertText(tab, text, frame: frame)
            } else {
                // Real key presses, so pages see keydown and keyup with a person's rhythm, not text appearing by itself;
                // a character with no US key is inserted as text.
                let focused = try await tab.call(PageScripts.focusedKind, frame: frame)
                if Self.pickerKinds.contains(focused) { throw Failure("typing would open the focused \(focused)'s native picker; use: agweb fill <target> <value>") }
                let chars = Array(text)
                for (i, char) in chars.enumerated() {
                    // A tab closed mid-word still runs scripts; the rest must not go nowhere and report success.
                    guard tab.webView.window != nil else { throw Failure("the tab was closed after \(i) of \(chars.count) characters") }
                    let hold = tab.motion.keyHold()
                    do {
                        if let combo = NativeInput.combo(for: char) {
                            try await stroke(tab, combo, hold: hold)
                        } else {
                            try await insertText(tab, String(char), frame: frame)
                        }
                    } catch {
                        throw Failure("typed \(i) of \(chars.count) characters: \(error)")
                    }
                    // The gap is press to press; the hold and the hand-back already took part of it.
                    if i < chars.count - 1 {
                        try await Task.sleep(for: .seconds(max(0.02, tab.motion.keyDelay(after: char, next: chars[i + 1]) - hold - 0.05)))
                    }
                }
            }
            if options["submit"] != nil { try await pressKey(tab, "Enter", instant: instant) }
        case "press":
            try await pressKey(tab, try arg(0, "key"), instant: instant)
        case "keydown", "keyup":
            try await pressKey(tab, try arg(0, "key"), phases: [request.command == "keydown" ? .keyDown : .keyUp])
        case "eval":
            let mark = try await args.count > 1 ? tab.call(PageScripts.mark, ["target": args[1]]) : nil
            let result: String
            let lines = tab.consoleTotal
            do {
                result = try await tab.call(PageScripts.evaluate(try arg(0, "code"), mark: mark), world: .page,
                                            frame: args.count > 1 ? tab.frameRefs[args[1]] : nil)
            } catch let failure as Failure where failure.description.contains("SyntaxError: Unexpected") || failure.description.contains("Expected ')'") {
                tab.forgetEvalError(since: lines)
                // The code goes in parentheses, so `a(); b()` fails with "Expected ')'", which says nothing about why.
                throw Failure((failure.description.hasSuffix(".") ? String(failure.description.dropLast()) : failure.description) + "; eval takes one expression or function: put statements in \"() => { ...; return value }\"")
            } catch let failure as Failure where failure.description.contains("SyntaxError") {
                tab.forgetEvalError(since: lines)
                throw failure
            }
            // `location.href = …` returns before the page goes; the next command must see the new one, not the old.
            try? await Task.sleep(for: .milliseconds(50))
            if tab.webView.isLoading { await tab.settle() }
            return "### Result\n\(result)\n" + describe(tab)
        case "scroll-into-view":
            let target = try arg(0, "target")
            let result = try await reveal(tab, target, instant: instant)
            if result == "no size" { throw Failure("\(target) has no size on screen") }
            return "### Result\n\(result)\n" + describe(tab)
        case "highlight":
            guard options["hide"] != nil || !args.isEmpty else { throw Failure("missing <target>") }
            _ = try await tab.call(PageScripts.highlight, ["target": args.first ?? "", "hide": options["hide"] != nil, "style": options["style"] ?? ""])
        case "screenshot":
            let path = try options["filename"] ?? { throw Failure("missing --filename") }()
            let fullResolution = options["full-resolution"] != nil
            let (image, shotNote) = try await screenshot(tab, target: args.first, fullPage: options["full-page"] != nil, fullResolution: fullResolution)
            let jpeg = ["jpg", "jpeg"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw Failure("could not encode screenshot") }
            // One pixel per CSS pixel opens at its size at 72 dpi; a full-resolution shot is tagged at the screen's density,
            // or a Retina shot opens twice its size.
            let dpi = fullResolution ? 72 * Double(cgImage.width) / max(1, image.size.width) : 72
            // Off the main thread: a full page's PNG takes about half a second, and every workspace's commands wait
            // on the main thread meanwhile.
            let data = try await Task.detached(priority: .userInitiated) { try Self.encode(cgImage, jpeg: jpeg, dpi: dpi) }.value
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: path))
            var note = shotNote
            if args.isEmpty, options["full-page"] == nil,
               let below = Int(try await tab.call("return String(document.documentElement.scrollHeight - scrollY - innerHeight)", world: .page)), below > 0 {
                note = "the page continues \(below) px below the viewport: --full-page for all of it, markdown eN to read a long element"
            }
            return "### Screenshot\n\(path)\n" + describe(tab, note: note)
        case "wait":
            let (result, found) = try await wait(tab, args.first, options)
            // A wait --url can end mid-redirect, and the snapshot for Changes would stall on the next page.
            let deadline = Date().addingTimeInterval(10)
            while found.webView.isLoading, Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
            // Matched in a tab the page opened: that tab's page, after the opener's events ("popup opened as tab 1").
            if found !== tab {
                found.events.insert(contentsOf: tab.events, at: 0)
                tab.events.removeAll()
                return result + "\n" + describe(found)
            }
            return result + "\n" + describe(tab) + (await changes(tab, urlBefore: urlBefore))
        case "emulate":
            let scheme = options["color-scheme"], device = options["device"]?.lowercased()
            guard scheme != nil || device != nil else { throw Failure("use: agweb emulate --color-scheme=dark|light|auto | --device=iphone|off") }
            guard device == nil || device == "iphone" || device == "off" else { throw Failure("--device is iphone or off") }
            // prefers-color-scheme follows the view's appearance; only this tab changes.
            switch scheme?.lowercased() {
            case nil: break
            case "dark": webView.appearance = NSAppearance(named: .darkAqua)
            case "light": webView.appearance = NSAppearance(named: .aqua)
            case "auto", "no-preference": webView.appearance = nil
            default: throw Failure("--color-scheme is dark, light or auto")
            }
            if let device { try await emulatePhone(tab, device == "iphone") }
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
        if Self.reportsChanges.contains(request.command) { return describe(tab) + (await changes(tab, urlBefore: urlBefore)) }
        return describe(tab)
    }

    /// Commands that can move a page's caret: it is kept again after them (reading ones, snapshot or wait, leave it).
    /// (A mouse press decides it itself, withMouse.)
    static let caretCommands: Set<String> = ["fill", "select", "eval", "js", "goto", "open", "reload", "go-back", "go-forward",
                                             "tab-select", "tab-new", "tab-close", "state-load"]

    /// A native key press (or only its down or up half) on the tab, giving the keyboard back to whoever had it.
    private func pressKey(_ tab: Tab, _ combo: String, phases: [NSEvent.EventType] = [.keyDown, .keyUp], instant: Bool = false) async throws {
        let focused = try await tab.call(PageScripts.focusedKind, frame: await tab.focusedFrame())
        if Self.pickerKinds.contains(focused), Self.pickerKeys.contains(combo.lowercased().components(separatedBy: "+").last ?? "") {
            throw Failure("\(combo) would open the focused \(focused)'s native picker; use: agweb fill <target> <value>")
        }
        let shortcut = phases.contains(.keyDown) ? NativeInput.editShortcut(combo, held: tab.held) : nil
        let frame = shortcut == nil ? nil : await tab.focusedFrame()
        // While the tab still has the keyboard: giving it back clears a contenteditable's selection.
        try await stroke(tab, combo, phases: phases, hold: instant ? 0 : tab.motion.keyHold()) {
            if let shortcut { try await self.editShortcut(tab, shortcut, in: frame) }
        }
        if phases.contains(.keyUp) { await tab.settle() }
    }

    /// ⌘A, ⌘C, ⌘X and ⌘V edit only when a person presses them (they are menu key equivalents), so the clipboard hook
    /// does what they would after the key, with the workspace clipboard: never the person's (ClipboardRouting.swift).
    private func editShortcut(_ tab: Tab, _ key: String, in frame: Frame?) async throws {
        let clip = tab.workspace.clipboard
        // Short: the person's typing goes to this tab until it returns.
        let done = try await tab.call(PageScripts.shortcut, ["key": key, "items": clip?.triples ?? []], world: .page, frame: frame, timeout: 3)
        switch (key, done) {
        case (_, "none"): tab.events.append("this frame has no clipboard hook (it loaded before agweb added one); reload the page")
        case (_, "key"): tab.events.append("the page's own keydown handler took Meta+\(key)")
        case (_, "denied"): tab.events.append("Meta+\(key) did nothing: the page had no user gesture")
        case ("v", "pasted"): tab.events.append("pasted \(clip?.summary ?? "") from the workspace clipboard")
        case ("v", "page") where clip?.text != nil: tab.events.append("pasted \(clip?.summary ?? ""): the page's paste handler took it")
        case ("v", _) where clip?.text == nil: tab.events.append("nothing pasted: the workspace clipboard has no text (agweb clipboard-set <text>)")
        case ("v", "nowhere"): tab.events.append("nothing pasted: the focus is not in a text field")
        default: break
        }
    }

    /// execCommand inserts text only where the page's selection is, and WebKit clears it when the tab's view gives up
    /// the keyboard (the window's first responder): after one of type's own key presses in a tab nobody shows, or
    /// another workspace's. So the tab takes the keyboard as a stroke does and hands it back after. Only "no field"
    /// is tried again, a few times while another workspace's key takes it back, never a timeout: a late script could
    /// insert twice.
    private func insertText(_ tab: Tab, _ text: String, frame: Frame?) async throws {
        try await withKeyboard(tab) { try await insertTextHolding(tab, text, frame: frame) }
    }

    private func insertTextHolding(_ tab: Tab, _ text: String, frame: Frame?) async throws {
        guard tab.webView.window != nil else { throw Failure("the tab was closed") }
        let window = mainWindow.window
        var previous = window.firstResponder
        if let editor = previous as? NSTextView, editor.isFieldEditor { previous = editor.delegate as? NSResponder }
        if previous is WKWebView { previous = model.displayedTab?.webView }
        // The person's keys landing here meanwhile are not theirs (NativeInput.stroking), as during a stroke.
        NativeInput.stroking.insert(ObjectIdentifier(tab.webView))
        defer { NativeInput.stroking.remove(ObjectIdentifier(tab.webView)) }
        var failure: Error?
        for attempt in 0..<5 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(50)) }
            await takeKeyboard(tab)
            do {
                // Long enough for a big text in a heavy editor: an agent retrying after a timeout would insert it twice.
                _ = try await tab.call(PageScripts.insertText, ["text": text], frame: frame, timeout: 10)
                failure = nil
                break
            } catch {
                failure = error
                guard "\(error)".contains("no editable element is focused") else { break }
            }
        }
        if let previous, previous !== tab.webView, window.firstResponder === tab.webView {
            tab.caretKept = (try? await tab.call(PageScripts.keepSelection, ["mode": "save"], timeout: 2)) != nil
            handBack(to: previous)
        }
        if let failure { throw failure }
    }

    /// The keyboard goes back to whoever had it, unless that left the window or was hidden meanwhile (the find bar
    /// closed). The person's own click or key meanwhile already took it (AgentWindow), so it is not the tab's to give.
    private func handBack(to previous: NSResponder) {
        (mainWindow.window as? AgentWindow)?.keyboardHolder = nil
        if let view = previous as? NSView, view.window !== mainWindow.window || view.isHiddenOrHasHiddenAncestor { return }
        mainWindow.window.makeFirstResponder(previous)
    }

    /// Makes the tab first responder, if it isn't, with a rich editor's caret where the last hand-back left it.
    private func takeKeyboard(_ tab: Tab) async {
        guard mainWindow.window.firstResponder !== tab.webView else { return }
        mainWindow.window.makeFirstResponder(tab.webView)
        // The restore must come after WebKit has handled the focus, which can take over a second when busy.
        await tab.activityStateApplied(timeout: 5)
        if tab.caretKept { _ = try? await tab.call(PageScripts.keepSelection, ["mode": "restore"], timeout: 2) }
    }

    /// Sends a key to the tab, held down for `hold` seconds when both phases are sent, as a finger holds it. The tab
    /// is first responder only while WebKit takes the key, and gets the keyboard back right away, not after the
    /// page settles: the person may be typing.
    private func stroke(_ tab: Tab, _ combo: String, phases: [NSEvent.EventType] = [.keyDown, .keyUp], hold: Double,
                        then: () async throws -> Void = {}) async throws {
        try await withKeyboard(tab) { try await strokeHolding(tab, combo, phases: phases, hold: hold, then: then) }
    }

    /// One agent's key or insertion at a time, across workspaces: another's landing between this one taking the
    /// keyboard and its key would move a rich editor's caret, or leave the text with no selection to go into.
    private func withKeyboard(_ tab: Tab, _ body: () async throws -> Void) async throws {
        while keyboardBusy { await withCheckedContinuation { keyboardWaiters.append($0) } }
        keyboardBusy = true
        (mainWindow.window as? AgentWindow)?.keyboardHolder = tab.webView
        defer {
            (mainWindow.window as? AgentWindow)?.keyboardHolder = nil
            keyboardBusy = false
            if !keyboardWaiters.isEmpty { keyboardWaiters.removeFirst().resume() }
        }
        try await body()
    }

    private func strokeHolding(_ tab: Tab, _ combo: String, phases: [NSEvent.EventType], hold: Double,
                               then: () async throws -> Void) async throws {
        let window = mainWindow.window
        var previous = window.firstResponder
        if let editor = previous as? NSTextView, editor.isFieldEditor { previous = editor.delegate as? NSResponder }
        // Another agent's press may have left its hidden tab first responder; the person types in the displayed one.
        if previous is WKWebView { previous = model.displayedTab?.webView }
        NativeInput.stroking.insert(ObjectIdentifier(tab.webView))
        defer { NativeInput.stroking.remove(ObjectIdentifier(tab.webView)) }
        guard tab.webView.window != nil else { throw Failure("tab has no window to receive input") }
        await takeKeyboard(tab)
        if phases.count == 2, hold > 0 {
            try NativeInput.press(tab.webView, combo: combo, phases: [.keyDown], held: &tab.held)
            try? await Task.sleep(for: .seconds(hold))
            try NativeInput.press(tab.webView, combo: combo, phases: [.keyUp], held: &tab.held)
        } else {
            try NativeInput.press(tab.webView, combo: combo, phases: phases, held: &tab.held)
        }
        var failure: Error?
        do { try await then() } catch { failure = error }
        // An answer from the page comes after WebKit has handed back any key it left alone (NativeInput.sentKeys).
        // It also keeps a rich editor's caret for the next key, before the keyboard goes back.
        tab.caretKept = (try? await tab.call(PageScripts.keepSelection, ["mode": "save"], timeout: 2)) != nil
        if tab.caretKept { NativeInput.settled(tab.webView) }
        try? await Task.sleep(for: .milliseconds(50))
        if let previous, previous !== tab.webView, window.firstResponder === tab.webView { handBack(to: previous) }
        if let failure { throw failure }
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
    private func download(_ tab: Tab, target: String, to path: String?, js: Bool, instant: Bool, refuseCovered: Double?) async throws -> String {
        tab.downloadPath = path.map { URL(fileURLWithPath: $0) }
        defer { tab.downloadPath = nil }
        let started = tab.downloadsStarted, ended = tab.downloadsEnded.count
        try await click(tab, target: target, button: .left, js: js, forUpload: false, instant: instant, refuseCovered: refuseCovered)
        for _ in 0..<100 where tab.downloadsStarted == started { try await Task.sleep(for: .milliseconds(100)) }
        guard tab.downloadsStarted > started else { throw Failure("no download started within 10 s of clicking \(target)") }
        for _ in 0..<1200 where tab.downloadsEnded.count == ended { try await Task.sleep(for: .milliseconds(100)) }
        guard let result = tab.downloadsEnded.dropFirst(ended).first else { throw Failure("the download did not finish within 2 minutes") }
        return try result.get()
    }

    /// Loads `url` in the tab (goto, open, tab-new). A URL that answers with a file (an attachment, a type WebKit can't
    /// show) is downloaded, to `path` if given, and WebKit stops the load ("Frame load interrupted"): then the saved
    /// path, once that download ends.
    private func goto(_ tab: Tab, _ url: URL, headers: [String: String] = [:], to path: String?) async throws -> String? {
        tab.downloadPath = path.map { URL(fileURLWithPath: $0) }
        defer { tab.downloadPath = nil }
        let (decided, started, address) = (tab.pageDownloads, tab.pageDownloadsStarted, tab.url)
        do {
            try await tab.goto(url, headers: headers)
            return nil
        } catch {
            guard tab.pageDownloads > decided else { throw error }
            // The page stays as it was: the file's address, which WebKit showed while asking, is not the tab's.
            tab.url = address
            for _ in 0..<50 where tab.pageDownloadsStarted == started { try await Task.sleep(for: .milliseconds(100)) }
            guard tab.pageDownloadsStarted > started else { throw error }
            let download = started + 1
            tab.pageDownloadResults = tab.pageDownloadResults.filter { $0.key >= download }
            for _ in 0..<1200 where tab.pageDownloadResults[download] == nil { try await Task.sleep(for: .milliseconds(100)) }
            guard let result = tab.pageDownloadResults.removeValue(forKey: download) else {
                throw Failure("\(url.lastPathComponent) did not finish downloading within 2 minutes; it goes on, and Events lists it once saved")
            }
            return try result.get()
        }
    }

    /// PNG, or JPEG at 0.85, straight from the CGImage: through a TIFF and an NSBitmapImageRep took most of the time.
    nonisolated private static func encode(_ image: CGImage, jpeg: Bool, dpi: Double) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, (jpeg ? UTType.jpeg : UTType.png).identifier as CFString, 1, nil) else {
            throw Failure("could not encode screenshot")
        }
        var properties: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        if jpeg { properties[kCGImageDestinationLossyCompressionQuality] = 0.85 }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure("could not encode screenshot") }
        return data as Data
    }

    /// The shot, and a note when part of what was asked for doesn't show in it.
    /// One pixel per CSS pixel unless `fullResolution`: a Retina shot has four times the pixels, and a model reading it pays
    /// four times the image tokens for sharper glyphs (Claude Code passes a 2160×1536 viewport through whole, about 4,300
    /// tokens), and its pixel positions are twice mousemove's CSS ones.
    private func screenshot(_ tab: Tab, target: String?, fullPage: Bool, fullResolution: Bool) async throws -> (image: NSImage, note: String?) {
        if windowHidden { throw Failure(MainWindow.notRendering(mainWindow.window)) }
        let scale = tab.webView.pageZoom * tab.webView.magnification
        let cap = 16_384.0
        func numbers(_ json: String) throws -> [String: Double] {
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Double] ?? [:]
        }
        // takeSnapshot renders only the view's bounds, so a shot taller than the viewport grows the view; shotStart keeps
        // the scroll positions the reflow moves, and they come back with the view's size.
        let previous = tab.viewportSize
        var grown = false
        func grow(_ size: CGSize) async throws {
            grown = true
            mainWindow.setSize(tab.webView, CGSize(width: size.width * scale, height: size.height * scale), centered: tab.phone != nil)
            _ = try await tab.call("await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))); return 'ok'")
        }
        func shot(_ rect: CGRect) async throws -> NSImage {
            let config = WKSnapshotConfiguration()
            // Snapshot rects are in view points from the top of the page, below the toolbar band.
            func points(_ rect: CGRect) -> CGRect {
                CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
            }
            config.rect = points(rect)
            let backing = tab.webView.window?.backingScaleFactor ?? 1
            guard !fullResolution, backing > 0 else { return try await tab.snapshot(config) }
            // snapshotWidth is in points, and the image comes at the screen's density, in whole points: on Retina a side
            // of odd CSS pixels would be resampled to an even one. So a rect padded to whole points, then cropped back.
            let size = CGSize(width: max(1, rect.width.rounded()), height: max(1, rect.height.rounded()))
            let padded = CGSize(width: (size.width / backing).rounded(.up) * backing, height: (size.height / backing).rounded(.up) * backing)
            config.rect = points(CGRect(x: rect.minX, y: rect.minY, width: rect.width + padded.width - size.width,
                                        height: rect.height + padded.height - size.height))
            config.snapshotWidth = NSNumber(value: padded.width / backing)
            let image = try await tab.snapshot(config)
            guard padded != size, let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let cropped = cgImage.cropping(to: CGRect(origin: .zero, size: size)) else { return image }
            return NSImage(cgImage: cropped, size: CGSize(width: size.width / backing, height: size.height / backing))
        }
        func take() async throws -> (image: NSImage, note: String?) {
            if let target {
                if tab.frameRefs[target] != nil { _ = try await reveal(tab, target, instant: true) }
                var box = try numbers(try await tab.call(PageScripts.box, ["target": target]))
                let origin = try await origin(tab, of: tab.frameRefs[target])
                var view = try await viewportSize(tab)
                var note: String?
                // Taller than the viewport: the view grows to fit it, and it goes to the top (in a chat, out from under the
                // composer, which stays at the bottom).
                if tab.frameRefs[target] == nil, let height = box["height"], height > view.height + 1 {
                    _ = try await tab.call(PageScripts.shotStart)
                    view.height = min(cap, view.height + height)
                    try await grow(view)
                    box = try numbers(try await tab.call(PageScripts.shotElement, ["target": target]))
                    // Its height now: it may have reflowed with the view.
                    if let shown = box["shown"], let height = box["height"], shown < height - 1 {
                        // Only the part that shows: the rest of the box would picture whatever lies past the cut.
                        box["y"] = box["shownY"]
                        box["height"] = shown
                        note = "\(target) is \(Int(height)) px tall and \(Int(shown)) px of it show"
                            + (view.height >= cap ? " (a screenshot stops at 16384 px)" : " (a scrolling box around it keeps its height)")
                            + ": markdown \(target) reads all of it"
                    }
                }
                let rect = CGRect(x: (box["x"] ?? 0) + origin.x, y: (box["y"] ?? 0) + origin.y, width: box["width"] ?? 0, height: box["height"] ?? 0)
                    .intersection(CGRect(origin: .zero, size: view))
                guard !rect.isEmpty else { throw Failure("\(target) has no visible area") }
                return (try await shot(rect), note)
            }
            let view = try await viewportSize(tab)
            // The view's bounds include the toolbar band; the page is the viewport.
            guard fullPage else { return (try await shot(CGRect(origin: .zero, size: view)), nil) }
            // The page's own height, plus what its scroller hides: a message list sized to the window grows with it.
            let first = try numbers(try await tab.call(PageScripts.shotStart))
            let page = first["page"] ?? view.height, hidden = first["hidden"] ?? 0
            var height = min(cap, page + hidden)
            try await grow(CGSize(width: view.width, height: height))
            var left = 0.0
            if hidden > 1 {
                var now = try numbers(try await tab.call(PageScripts.shotMeasure))
                if now["gone"] != nil {
                    left = 0
                } else if (now["scrollerHeight"] ?? 0) < (first["scrollerHeight"] ?? 0) + 1 {
                    // A scroller of fixed height: the page's own height, without an empty band below.
                    height = min(cap, page)
                    try await grow(CGSize(width: view.width, height: height))
                    left = hidden
                } else {
                    // A list sharing the window's height with other parts grows by less than the view: by that share.
                    var before = (view: view.height, scroller: first["scrollerHeight"] ?? 0)
                    for _ in 0..<3 {
                        guard let more = now["hidden"], more > 1, height < cap, let scroller = now["scrollerHeight"] else { break }
                        let share = (scroller - before.scroller) / max(1, height - before.view)
                        guard share > 0.05 else { break }
                        before = (height, scroller)
                        height = min(cap, (height + more / share).rounded(.up))
                        try await grow(CGSize(width: view.width, height: height))
                        now = try numbers(try await tab.call(PageScripts.shotMeasure))
                    }
                    left = max(0, now["hidden"] ?? 0)
                    // Still hiding some: it stopped growing (a max-height). Back to the least view that gives it that
                    // height if it took all the growth, not a blank band below it.
                    if left > 1, let size = now["scrollerHeight"] {
                        let fit = max(page, view.height + size - (first["scrollerHeight"] ?? 0)).rounded(.up)
                        if fit < height {
                            height = fit
                            try await grow(CGSize(width: view.width, height: height))
                            left = max(0, try numbers(try await tab.call(PageScripts.shotMeasure))["hidden"] ?? left)
                        }
                    }
                }
                // A document sized by its content ends above a view grown by a list's share: the shot ends with it.
                if let occupied = try numbers(try await tab.call(PageScripts.shotMeasure))["doc"], occupied < height {
                    height = max(page, occupied.rounded(.up))
                }
            }
            let cut = max(0, page - height) + (left > 1 ? left : 0)
            let note = left > 1 && height < cap ? "the page scrolls inside a box that doesn't grow with the window, and \(Int(left)) px of it don't show: markdown reads them"
                : height >= cap && cut > 1 ? "a screenshot stops at 16384 px: \(Int(cut)) px more of the page don't show" : nil
            return (try await shot(CGRect(x: 0, y: 0, width: view.width, height: height)), note)
        }
        func restore() async {
            guard grown else { return }
            mainWindow.setSize(tab.webView, previous, centered: tab.phone != nil)
            _ = try? await tab.call(PageScripts.shotEnd)
        }
        do {
            let result = try await take()
            await restore()
            return result
        } catch {
            await restore()
            throw error
        }
    }

    /// `wait 1500` sleeps; otherwise polls until the target shows (or with --gone, leaves), the text or URL appears,
    /// or with --load the page has loaded and no fetch/XHR has been in flight for half a second.
    /// Also the tab the match showed in: `tab`, or one the page opened meanwhile.
    private func wait(_ tab: Tab, _ arg: String?, _ options: [String: String]) async throws -> (result: String, tab: Tab) {
        let timeout = try options["timeout"].map { text -> Double in
            guard let ms = Double(text), (0...600_000).contains(ms) else { throw Failure("--timeout is milliseconds, up to 600000") }
            return ms / 1000
        } ?? 30
        if let arg, let ms = Double(arg) {
            guard (0...600_000).contains(ms) else { throw Failure("wait takes up to 600000 ms") }
            // A recording shows the whole wait: the agent paused so the viewer can read something.
            tab.workspace.recorder?.hold(ms / 1000)
            try await Task.sleep(for: .milliseconds(ms))
            return ("### Result\nwaited \(Int(ms)) ms", tab)
        }
        guard let condition = condition(tab, arg, options) else {
            throw Failure("use: agweb wait <ms> | <target> [--gone] | --text=… | --url=… | --load  [--timeout=ms]")
        }
        let waited: Double
        do {
            waited = try await poll(timeout, condition.what, condition.check)
            if condition.matched() !== tab { return ("### Result\nwaited \(String(format: "%.1f", waited)) s for \(condition.what)\(elsewhere(condition.matched(), tab))", condition.matched()) }
        } catch let error as Failure where error.description.hasPrefix("timed out") && arg != nil && options["gone"] == nil {
            guard let arg else { throw error }
            // Why the target still misses: a role= miss lists that role's visible elements, so the next try needs no snapshot.
            let now: String
            do {
                now = try await tab.call(PageScripts.find + "return visible(find(target)) ? 'ok' : 'hidden'", ["target": arg])
            } catch let miss as Failure {
                throw Failure("\(error.description); now: \(miss.description)")
            }
            if now == "hidden" { throw Failure("\(error.description); now: \(arg) is on the page but hidden") }
            throw error
        }
        // The first check runs before any sleep: an agent expecting new text usually matched old text.
        if waited < 0.1 {
            if let arg, options["gone"] != nil {
                return ("### Result\nalready true when wait started: nothing visible matches \(arg). If it was on screen, the selector is off (text=\"...\" is the element's whole text)", tab)
            }
            return ("### Result\nalready true when wait started: \(condition.what)", tab)
        }
        return ("### Result\nwaited \(String(format: "%.1f", waited)) s for \(condition.what)", tab)
    }

    /// What `wait` and `ask` wait for: a target to show (or go), text, a URL, or a quiet network; nil if none.
    /// A target, text or URL may also show in a tab the page opens meanwhile (Loom opens the share page in a new tab
    /// when an upload ends): `matched` is the tab it showed in. --gone and --load are about `tab` alone.
    private func condition(_ tab: Tab, _ arg: String?, _ options: [String: String])
        -> (what: String, check: () async throws -> Bool, matched: () -> Tab)? {
        final class Match { var tab: Tab; init(_ tab: Tab) { self.tab = tab } }
        let match = Match(tab), before = Set(tab.workspace.tabs.map(\.id))
        // `tab` first, so its errors (a bad selector) end the wait; a popup's (still loading, closed) only skip it.
        func anywhere(_ test: @escaping (Tab) async throws -> Bool) -> () async throws -> Bool {
            {
                if try await test(tab) { match.tab = tab; return true }
                for popup in tab.workspace.tabs where popup.opener === tab && !before.contains(popup.id) {
                    if (try? await test(popup)) == true, tab.workspace.tabs.contains(where: { $0 === popup }) { match.tab = popup; return true }
                }
                return false
            }
        }
        let what: String
        let check: () async throws -> Bool
        if let target = arg {
            let gone = options["gone"] != nil, enabled = options["enabled"] != nil
            what = gone ? "\(target) to go" : enabled ? "\(target) to be enabled" : target
            let test = { (tab: Tab) in try await tab.call(PageScripts.present, ["target": target, "gone": gone, "attached": false, "enabled": enabled], timeout: 3) == "true" }
            check = gone ? { try await test(tab) } : anywhere(test)
        } else if let text = options["text"] {
            what = "text \(text.debugDescription)"
            check = anywhere { try await $0.call(PageScripts.hasText, ["text": text], timeout: 3) == "true" }
        } else if let url = options["url"] {
            what = "a URL containing \(url)"
            check = anywhere { $0.webView.url?.absoluteString.contains(url) ?? false }
        } else if options["load"] != nil {
            what = "the page to load and the network to go quiet"
            var quietSince: Double?
            check = {
                let loaded = try await tab.call(PageScripts.quiet, world: .page, timeout: 3) == "true"
                let quiet = loaded && !tab.webView.isLoading
                let now = ProcessInfo.processInfo.systemUptime
                quietSince = quiet ? quietSince ?? now : nil
                return quietSince.map { now - $0 >= 0.5 } ?? false
            }
        } else {
            return nil
        }
        return (what, check, { match.tab })
    }

    /// Where a wait's match showed, when not in the tab it watched.
    private func elsewhere(_ found: Tab, _ tab: Tab) -> String {
        guard found !== tab, let index = found.workspace.tabs.firstIndex(where: { $0 === found }) else { return "" }
        return " in tab \(index), which the page opened" + (found.id == found.workspace.currentID ? " (now current)" : "; tab-select \(index) to drive it")
    }

    /// Hands the tab to the person: shows it, puts the message in a bar over it with a Done button and marks it in
    /// the sidebar and dashboard, all without activating the app. Ends when the person clicks Done, the condition
    /// holds, or the timeout passes; the bar and marks go in every case.
    private func ask(_ tab: Tab, _ message: String, _ target: String?, _ options: [String: String]) async throws -> String {
        guard let ms = Double(options["timeout"] ?? "600000"), (0...3_600_000).contains(ms) else {
            throw Failure("--timeout is milliseconds, up to 3600000")
        }
        let condition = condition(tab, target, options)
        final class Flag { var on = false }
        let done = Flag()
        tab.asking = message
        model.display(tab.id)
        mainWindow.showQuietly(evenIfPutAway: true)
        mainWindow.showAsk(on: tab.webView, message: message) { done.on = true }
        defer {
            tab.asking = nil
            mainWindow.hideAsk(on: tab.webView)
        }
        // Asked on a page wanting a Basic login and given no condition: done once a page without one has loaded.
        let wall = condition == nil ? tab.authWall?.origin : nil
        let waited = try await poll(ms / 1000, "the person (\(message))") {
            guard tab.webView.window != nil else { throw Failure("the tab was closed while asking the person") }
            if done.on { return true }
            if wall != nil { return tab.authWall == nil && !tab.webView.isLoading }
            return try await condition?.check() ?? false
        }
        let found = condition.map { elsewhere($0.matched(), tab) } ?? ""
        let how = done.on ? "the person clicked Done"
            : wall.map { "\($0) no longer asks for a login (the person didn't need to click Done)" }
            ?? "\(condition?.what ?? "")\(found) (the person didn't need to click Done)"
        return "### Result\n\(how) after \(String(format: "%.0f", waited)) s"
    }

    /// Checks every 100 ms until `check` holds; the seconds it took.
    private func poll(_ timeout: Double, _ what: String, _ check: () async throws -> Bool) async throws -> Double {
        let start = ProcessInfo.processInfo.systemUptime
        var ambiguousSince: Double?
        while true {
            // A navigation in progress makes page scripts fail; that is "not yet". A bad selector or a ref from an
            // old page never will be, and several matches fail once they outlast a re-render (an old and a new
            // dialog during a fade).
            do {
                if try await check() { break }
                ambiguousSince = nil
            } catch let error as Failure where error.description.contains("invalid selector") || error.description.contains("take a new snapshot")
                        || error.description.contains("was closed") {
                throw error
            } catch let error as Failure where error.description.contains("Be more specific") {
                let now = ProcessInfo.processInfo.systemUptime
                if now - (ambiguousSince ?? now) >= 1 { throw error }
                ambiguousSince = ambiguousSince ?? now
            } catch {
                ambiguousSince = nil
            }
            if ProcessInfo.processInfo.systemUptime - start > timeout { throw Failure("timed out after \(timeout < 10 ? String(format: "%.1f", timeout) : String(Int(timeout))) s waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(100))
        }
        return ProcessInfo.processInfo.systemUptime - start
    }

    /// Actions wait for their target to show, as Playwright's do: up to --timeout ms (5000 by default; 0 doesn't
    /// wait). Past that the action runs anyway, so its own error says what is wrong with the target.
    /// Fields only need to be there: a styled select or checkbox hides the native one it drives.
    /// As Playwright's do, actions that operate a control wait for it to be enabled too, since a click on a disabled
    /// button does nothing and says nothing; past --timeout they fail. `check` and `uncheck` ask only when they must
    /// click (a locked box already in the wanted state is fine), so they pass `enabled` themselves.
    private func awaitTarget(_ tab: Tab, _ target: String, _ command: String, _ options: [String: String],
                             enabled: Bool? = nil) async throws {
        guard let ms = Double(options["timeout"] ?? "5000"), (0...600_000).contains(ms) else { throw Failure("--timeout is milliseconds, up to 600000") }
        guard ms > 0 else { return }
        let attached = ["fill", "select", "check", "uncheck"].contains(command)
        let enabled = enabled ?? ["click", "dblclick", "fill", "select"].contains(command)
        let state = { try await tab.call(PageScripts.present, ["target": target, "gone": false, "attached": attached, "enabled": enabled], timeout: 3) }
        do {
            _ = try await poll(ms / 1000, target) { try await state() == "true" }
        } catch let error as Failure where error.description.hasPrefix("timed out") {
            if (try? await state()) == "disabled" {
                throw Failure("\(target) is disabled after \(Int(ms)) ms; wait for it with: wait <target> --enabled --timeout=<ms>, or act on it anyway with --timeout=0")
            }
        }
    }

    /// The page tree, and the document it came from; new elements number on from the workspace's last ref.
    private func snapshotTree(_ tab: Tab, _ target: String, whole: Bool = false) async throws -> (doc: String, tree: String) {
        var handles: [[Int]: WKFrameInfo]?
        let snapshot = try await snapshotTree(tab, target, in: tab.frameRefs[target], handles: &handles, limit: whole ? 0 : PageScripts.maxSnapshotLines)
        if tab.refLabels.count > 20_000 { tab.refLabels.removeAll() }
        // Role and name only: a value may be what the agent typed. Hidden before it is cut, or a secret across the cut
        // would show its first half; hide is slow, so only when there are secrets.
        for line in Output.lines(snapshot.tree) {
            guard let (label, ref) = Snapshot.refLabel(line) else { continue }
            tab.refLabels[String(ref)] = String((secrets.isEmpty ? String(label) : Self.hide(secrets, in: String(label))).prefix(80))
        }
        return snapshot
    }

    /// One frame's tree with each cross-origin frame in it put in under its iframe, one after another so refs stay
    /// unique. `handles`: the frames below the page by path, looked up once, when the first one shows.
    /// `path`: where the frame should be; one that moved since (an iframe added above it) is left out, not misplaced.
    private func snapshotTree(_ tab: Tab, _ target: String, in frame: Frame?, handles: inout [[Int]: WKFrameInfo]?, path: [Int]? = nil, limit: Int) async throws -> (doc: String, tree: String) {
        // A frame that never answers (mid-navigation) costs at most a few seconds; it then stays an empty iframe.
        let reply = try await tab.call(PageScripts.snapshot, ["target": target, "limit": limit], frame: frame, timeout: frame == nil ? 30 : 5)
        // JSONDecoder, not JSONSerialization: that hands back an NSString, which Swift walks character by character
        // through the bridge, so every split and search of a big tree crawled (a 165,000-line tree, a second a pass).
        let parsed = try JSONDecoder().decode(SnapshotReply.self, from: Data(reply.utf8))
        // Before anything is thrown away: the refs it handed out are taken either way.
        if let next = parsed.next { tab.workspace.refSeed = max(tab.workspace.refSeed, next) }
        if let path, parsed.path != path { throw Failure("the frame moved") }
        let tree = parsed.tree, frames = parsed.frames
        if let frame { for ref in parsed.refs ?? [] { tab.frameRefs[ref] = frame } }
        guard !frames.isEmpty else { return (parsed.doc ?? "", tree) }
        if handles == nil {
            // All at once: a page may have dozens of frames, and one mid-navigation takes the whole timeout.
            let asked = await tab.subframes().map { info in
                (info, Task { try? await tab.call(PageScripts.framePath, frame: Frame(info: info, parent: nil, element: ""), timeout: 2) })
            }
            var found: [[Int]: WKFrameInfo] = [:]
            for (info, answer) in asked {
                if let json = await answer.value, let path = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Int] { found[path] = info }
            }
            handles = found
        }
        var lines: [String] = []
        for line in tree.split(separator: "\n", omittingEmptySubsequences: false) {
            let indent = line.prefix { $0 == " " }
            guard line.dropFirst(indent.count).first == "\u{1}", let index = Int(line.dropFirst(indent.count + 1)), frames.indices.contains(index) else {
                lines.append(String(line))
                continue
            }
            // A frame that doesn't answer (still loading, or gone) stays an empty iframe, as before.
            guard let path = frames[index].path, let info = handles?[path],
                  let inner = try? await snapshotTree(tab, "", in: Frame(info: info, parent: frame, element: frames[index].ref), handles: &handles, path: path, limit: limit).tree,
                  !inner.isEmpty else { continue }
            lines += inner.split(separator: "\n").map { String(indent + $0) }
        }
        return (parsed.doc ?? "", lines.joined(separator: "\n"))
    }

    /// What PageScripts.snapshot returns; `refs` only from a cross-origin frame, whose refs the app must route to it.
    private struct SnapshotReply: Decodable {
        struct FrameMark: Decodable { let path: [Int]?; let ref: String }
        let tree: String, next: Int?, doc: String?, frames: [FrameMark], refs: [String]?, path: [Int]?
    }

    /// Where a frame's content starts in the top viewport (the page: zero): its iframe's content box, through every
    /// frame above it.
    private func origin(_ tab: Tab, of frame: Frame?) async throws -> CGPoint {
        guard let frame else { return .zero }
        let json = try await tab.call(PageScripts.frameOrigin, ["target": frame.element], frame: frame.parent)
        let box = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Double] ?? [:]
        let above = try await origin(tab, of: frame.parent)
        return CGPoint(x: (box["x"] ?? 0) + above.x, y: (box["y"] ?? 0) + above.y)
    }

    /// Paginated like printing, with print styles, unless `singlePage`: then one page of the screen view.
    private func pdf(_ tab: Tab, to url: URL, singlePage: Bool, paper: String?) async throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if singlePage {
            let data = try await withTimeout(30, "pdf") { try await tab.webView.pdf(configuration: WKPDFConfiguration()) }
            try data.write(to: url)
            return
        }
        guard let window = tab.webView.window else { throw Failure(MainWindow.notRendering(mainWindow.window)) }
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
        mainWindow.setSize(tab.webView, points, centered: tab.phone != nil)
        try await Task.sleep(for: .milliseconds(100))
        let got = try await viewportSize(tab)
        if got != size {
            points = CGSize(width: points.width + (size.width - got.width) * scale, height: points.height + (size.height - got.height) * scale)
            tab.viewportSize = points
            mainWindow.setSize(tab.webView, points, centered: tab.phone != nil)
            try await Task.sleep(for: .milliseconds(100))
        }
        tab.pointer = nil
        tab.events.append("viewport is \(Int(size.width))x\(Int(size.height))")
    }

    /// The user agent and navigator.platform reach the server and scripts only from the next load, so the page reloads.
    private func emulatePhone(_ tab: Tab, _ on: Bool) async throws {
        if on {
            let before = tab.phone
            if tab.phone == nil {
                let getter = NSSelectorFromString("_userAgent")
                typealias Get = @convention(c) (AnyObject, Selector) -> NSString?
                let desktop = tab.webView.responds(to: getter)
                    ? unsafeBitCast(tab.webView.method(for: getter), to: Get.self)(tab.webView, getter) as String? : nil
                tab.phone = (Phone.userAgent(desktop: desktop ?? ""), tab.viewportSize)
            }
            do {
                try await resize(tab, to: CGSize(width: Phone.viewport.width, height: Phone.viewport.height))
            } catch {
                // A failed command leaves the tab as it was, not an iPhone from its next load on.
                tab.phone = before
                throw error
            }
            tab.webView.customUserAgent = tab.phone?.userAgent
        } else {
            guard let phone = tab.phone else { return tab.events.append("no device was emulated in this tab") }
            tab.phone = nil
            tab.webView.customUserAgent = nil
            tab.viewportSize = phone.viewportBefore
            mainWindow.setSize(tab.webView, phone.viewportBefore)
            tab.pointer = nil
        }
        if tab.webView.url != nil {
            // A form's result comes back by its address, as an unloaded tab's does: a reload would send the form again.
            if tab.postedPage, let address = URL(string: tab.url) {
                tab.webView.load(URLRequest(url: address))
            } else {
                tab.resubmitAllowed = true
                if tab.webView.reload() == nil { tab.resubmitAllowed = false }
            }
            await tab.settle()
        }
        guard on else { return tab.events.append("device emulation off; page reloaded") }
        tab.events.append("emulating an iPhone: 390x844 viewport, iPhone Safari user agent, navigator.platform iPhone"
            + (tab.webView.url != nil ? "; page reloaded" : "")
            + ". Not emulated: touch events, (hover: none) and (pointer: coarse), devicePixelRatio, screen size")
        let viewportMeta = try? await tab.call("return String(!!document.querySelector('meta[name=viewport]'))", world: .page, timeout: 2)
        if viewportMeta == "false" {
            tab.events.append("this page has no <meta name=viewport>: an iPhone lays it out 980 px wide and zooms out, but here it is 390 px wide")
        }
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

    /// `refuseCovered`: fail, after waiting up to that many seconds, rather than click something covering the
    /// target; nil clicks anyway with an event, for controls styled over their native input (checkboxes, uploads).
    private func click(_ tab: Tab, target: String, button: MouseButton, js: Bool, forUpload: Bool, instant: Bool, clicks: Int = 1,
                       refuseCovered: Double? = nil) async throws {
        if js {
            _ = try await tab.call(PageScripts.jsClick, ["target": target])
            return
        }
        let spot = try await locate(tab, target, instant: instant)
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
        var (point, landed) = try await glide(tab, onto: target, from: spot, instant: instant)
        // A checkbox, radio or file input is usually hidden under its own styled box, which passes the click on.
        if let patience = refuseCovered, !["checkbox", "radio", "file"].contains(spot.kind) {
            // As Playwright does: never click what would land on something else, such as a cookie dialog's
            // backdrop. Scroll once in case a sticky header covers it, and wait out an overlay that is going away;
            // the page may have moved the target meanwhile.
            let deadline = ProcessInfo.processInfo.systemUptime + patience
            var rescrolled = false, waited = false
            while true {
                if let cover = try await coverAt(tab, target, point) {
                    if !rescrolled {
                        rescrolled = true
                        _ = try await tab.call(PageScripts.center, ["target": target])
                        (point, landed) = try await glide(tab, onto: target, from: try await locate(tab, target, scroll: false), instant: instant)
                        continue
                    }
                    guard ProcessInfo.processInfo.systemUptime < deadline else {
                        throw Failure("\(target) is covered by \(cover), which would get the click. Close it if it is a banner or dialog, wait if "
                                      + "the page is loading, or click the element by script with --js (--force clicks the spot anyway)")
                    }
                    waited = true
                    try await Task.sleep(for: .milliseconds(100))
                    continue
                }
                guard waited else { break }
                waited = false
                let now = try await locate(tab, target, scroll: false)
                if CGRect(x: now.center.x - now.size.width / 2, y: now.center.y - now.size.height / 2, width: now.size.width, height: now.size.height).contains(point) { break }
                (point, landed) = try await glide(tab, onto: target, from: now, instant: instant)
            }
        } else if let covered = try await coverAt(tab, target, point) {
            tab.events.append("click target was covered by \(covered)")
        }
        if !instant { try await Task.sleep(for: .seconds(tab.motion.dwell())) }
        if button == .right { suppressMenus(tab) }
        try await withMouse(tab) {
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
    }

    /// A press into a field makes WebKit give the tab the keyboard (the window's first responder), from another agent's
    /// tab mid-word: so a press waits its turn like a key. The tab keeps the keyboard after (a page's clipboard call the
    /// click started needs it), with the caret it set in a rich editor kept for the next key: taking the keyboard back
    /// after another tab had it puts the caret at the start.
    private func withMouse(_ tab: Tab, _ body: () async throws -> Void) async throws {
        try await withKeyboard(tab) {
            var failure: Error?
            do { try await body() } catch { failure = error }
            await tab.mouseEventsDelivered()
            // A press into a field asks for the keyboard from the page's process: the save's answer comes after it.
            tab.caretKept = (try? await tab.call(PageScripts.keepSelection, ["mode": "save"], timeout: 2)) != nil
            if let failure { throw failure }
        }
    }

    /// Press on `source`, move to `target` with the button held, release. An HTML5-draggable source would make
    /// WebKit start an AppKit drag session, which tracks the person's real mouse, so those get DOM drag events.
    private func drag(_ tab: Tab, from source: String, to target: String, instant: Bool) async throws {
        if try await tab.call(PageScripts.isDraggable, ["target": source]) == "true" {
            guard tab.frameRefs[source] === tab.frameRefs[target] else { throw Failure("\(source) is HTML5-draggable and \(target) is in another frame; drag within one frame") }
            _ = try await tab.call(PageScripts.html5Drag, ["from": source, "to": target], frame: tab.frameRefs[source])
            tab.events.append("\(source) is HTML5-draggable: dropped with DOM drag events, not the pointer")
            return
        }
        let start = try await locate(tab, source, instant: instant)
        if start.size.width == 0 || start.size.height == 0 { throw Failure("\(source) has no size on screen; snapshot again") }
        let (from, landed) = try await glide(tab, onto: source, from: start, instant: instant)
        let end = try await locate(tab, target, scroll: false)
        guard (0...end.viewport.width).contains(end.center.x), (0...end.viewport.height).contains(end.center.y) else {
            throw Failure("\(target) is off screen while \(source) is on it; drag in steps")
        }
        try await withMouse(tab) {
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
    }

    /// Scroll events at the pointer, in a person's wheel ticks of about 60 px unless `instant`.
    private func wheel(_ tab: Tab, dx: Double, dy: Double, instant: Bool) async throws {
        let viewport = try await viewportSize(tab)
        let at = tab.pointer ?? CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        // Ticks that speed up and slow down, as a finger flicks a wheel; the last one makes up any rounding.
        let distance = max(abs(dx), abs(dy), 1)
        let ticks = instant ? [(delta: distance, pause: 0.0)] : tab.motion.wheelTicks(distance)
        var sentX = 0.0, sentY = 0.0, done = 0.0
        for (i, tick) in ticks.enumerated() {
            done += tick.delta / distance
            let x = i == ticks.count - 1 ? dx : (dx * done).rounded(), y = i == ticks.count - 1 ? dy : (dy * done).rounded()
            try NativeInput.wheel(tab.webView, at: at, viewportHeight: viewport.height, dx: Int32(x - sentX), dy: Int32(y - sentY))
            sentX = x
            sentY = y
            if tick.pause > 0 { try await Task.sleep(for: .seconds(tick.pause)) }
        }
        try await Task.sleep(for: .milliseconds(150))
    }

    private func viewportSize(_ tab: Tab) async throws -> CGSize {
        let json = try await tab.call(PageScripts.viewport)
        let size = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Double] ?? [:]
        return CGSize(width: size["viewportWidth"] ?? 0, height: size["viewportHeight"] ?? 0)
    }

    /// What sits over the target at `point` and would take a click there, or nil.
    private func coverAt(_ tab: Tab, _ target: String, _ point: CGPoint) async throws -> String? {
        let frame = tab.frameRefs[target]
        let origin = try await origin(tab, of: frame)
        let json = try await tab.call(PageScripts.locate, ["target": target, "at": ["x": point.x - origin.x, "y": point.y - origin.y]])
        let covered = (try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])?["covered"] as? String
        if covered == nil, let frame { return try await coverAt(tab, frame.element, point) }
        return covered
    }

    /// How long a click waits for a covering element to go before refusing: --timeout if given, else 1 s; nil
    /// (click anyway) with --force.
    private func coverPatience(_ options: [String: String]) -> Double? {
        options["force"] != nil ? nil : options["timeout"].flatMap(Double.init).map { max(0, $0) / 1000 } ?? 1
    }

    private func hover(_ tab: Tab, target: String, instant: Bool) async throws {
        let spot = try await locate(tab, target, instant: instant)
        if spot.size.width == 0 || spot.size.height == 0 { throw Failure("\(target) has no size on screen; snapshot again") }
        let landed = try await glide(tab, onto: target, from: spot, instant: instant).spot
        if let covered = landed.covered { tab.events.append("hover target is covered by \(covered)") }
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
        // A pointer seen for the first time comes in from an edge; one that always starts in the middle is a bot tell.
        let start = tab.pointer ?? (instant ? point : tab.motion.entry(viewport: viewport))
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

    /// Brings the element into view unless all of it shows, gliding there unless `instant`; says what it did.
    @discardableResult
    private func reveal(_ tab: Tab, _ target: String, instant: Bool) async throws -> String {
        let result = try await tab.call(PageScripts.reveal, ["target": target, "smooth": !instant])
        // In a cross-origin frame that scrolled only the frame: each document above scrolls to the element's spot.
        guard var frame = tab.frameRefs[target], result != "no size" else { return result }
        let json = try await tab.call(PageScripts.box, ["target": target])
        let box = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Double] ?? [:]
        let size = ["width": box["width"] ?? 0, "height": box["height"] ?? 0]
        var point = ["x": (box["x"] ?? 0) + size["width"]! / 2, "y": (box["y"] ?? 0) + size["height"]! / 2]
        var moved = false
        while true {
            let json = try await tab.call(PageScripts.revealAt, ["target": frame.element, "at": point, "size": size], frame: frame.parent)
            let spot = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] ?? [:]
            point = ["x": spot["x"] as? Double ?? 0, "y": spot["y"] as? Double ?? 0]
            moved = moved || spot["moved"] as? Bool == true
            guard let parent = frame.parent else { break }
            frame = parent
        }
        // The frame's own answer saw the page before it scrolled.
        return moved ? "scrolled" : result
    }

    private func locate(_ tab: Tab, _ target: String, scroll: Bool = true, instant: Bool = true) async throws -> Spot {
        if scroll { try await reveal(tab, target, instant: instant) }
        let json = try await tab.call(PageScripts.locate, ["target": target])
        let spot = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] ?? [:]
        func number(_ key: String) -> Double { spot[key] as? Double ?? 0 }
        var found = Spot(center: CGPoint(x: number("x"), y: number("y")), size: CGSize(width: number("width"), height: number("height")),
                         viewport: CGSize(width: number("viewportWidth"), height: number("viewportHeight")),
                         kind: spot["kind"] as? String ?? "", hitKind: spot["hitKind"] as? String ?? "", covered: spot["covered"] as? String)
        // In a cross-origin frame: points are the top viewport's, and the iframe itself may be covered.
        if let frame = tab.frameRefs[target] {
            let origin = try await origin(tab, of: frame)
            found.center = CGPoint(x: found.center.x + origin.x, y: found.center.y + origin.y)
            found.viewport = try await viewportSize(tab)
            if found.covered == nil { found.covered = try await coverAt(tab, frame.element, found.center) }
        }
        return found
    }

    // MARK: Output

    /// Cloudflare passes some browsers at once and asks others to tick a checkbox, which sits in a closed shadow root
    /// in a cross-origin frame: snapshot, markdown and click can't reach it, a native click at its spot can.
    /// The checkbox appears by script after the load, so a reply right after goto may not have its spot yet.
    /// `--basic-auth` on open or goto: the login for the URL's origin, its password hidden in replies from now on.
    /// Repeated --header "name: value" options, which the CLI joins with newlines.
    private func headers(_ options: [String: String]) throws -> [String: String] {
        var headers: [String: String] = [:]
        for line in (options["header"] ?? "").split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":"), case let name = line[..<colon].trimmingCharacters(in: .whitespaces), !name.isEmpty else {
                throw Failure("--header is \"name: value\"")
            }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return headers
    }

    private func storeBasicAuth(_ options: [String: String], for url: URL, in workspace: Workspace) throws {
        guard let user = options["basic-auth"], let password = options["basic-auth-password"] else { return }
        guard let scheme = url.scheme, ["http", "https"].contains(scheme), let host = url.host else { throw Failure("--basic-auth needs an http or https URL") }
        workspace.basicAuth[Address.origin(scheme: scheme, host: host, port: url.port)] = (user, password, false)
        // Only one the agent never saw: hiding a typed `admin:admin` would hide "admin" in every reply.
        if options["basic-auth-secret"] != nil { hideBasicAuth(user, password) }
    }

    /// The password, and the header a page echoing its request (httpbin's /headers) would show.
    private func hideBasicAuth(_ user: String, _ password: String) {
        secrets.insert(password)
        secrets.insert(Data("\(user):\(password)".utf8).base64EncodedString())
    }

    private func authNote(_ tab: Tab, _ wall: Tab.AuthWall) -> String {
        let asks = "HTTP 401: \(wall.origin) asks for a \(wall.scheme) login" + (wall.realm.isEmpty ? "" : " (realm \"\(wall.realm)\")")
        if let login = tab.workspace.basicAuth[wall.origin], login.refused {
            return asks + " and refused the one for \(login.user) (not sent again; give another with goto --basic-auth)"
        }
        return asks + ": agweb -w \(tab.workspace.name) goto '\(wall.url.absoluteString)' --basic-auth USER --secret-cmd CMD, "
            + "or ask the person (the tab shows a login bar)"
    }

    /// The bar on a tab showing a 401 that asks for a Basic or Digest login; the person's login is kept like `--basic-auth`.
    func updateLoginBar(_ tab: Tab) {
        guard let wall = tab.authWall else { return mainWindow.hideLogin(on: tab.webView) }
        mainWindow.showLogin(on: tab.webView, site: wall.url.host ?? wall.origin, realm: wall.realm,
                             refused: tab.workspace.basicAuth[wall.origin].flatMap { $0.refused ? $0.user : nil }) { [weak self, weak tab] user, password in
            guard let self, let tab else { return }
            tab.workspace.basicAuth[wall.origin] = (user, password, false)
            self.hideBasicAuth(user, password)
            // By address: reload() would send a POST's form again.
            tab.webView.load(URLRequest(url: wall.url))
        }
    }

    private func challengeNote(_ tab: Tab) async -> String {
        let start = "Cloudflare check. If it is still here after about 10 s, it waits for a click on its \"Verify you are human\" "
            + "checkbox, which snapshot and text can't see"
        guard let json = try? await tab.call(PageScripts.challengeSpot),
              let spot = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Double],
              let x = spot["x"], let y = spot["y"] else { return start + "; run any command again then for its spot" }
        return start + ": mousemove \(Int(x.rounded())) \(Int(y.rounded())), then mousedown and mouseup. A named profile (-p) keeps the pass"
    }

    /// The tab's back-forward list, oldest first, numbered from the current entry: -1 is where go-back leads.
    /// The tab's back-forward list, oldest first, numbered from the current entry: -1 is where go-back leads. Only the
    /// `limit` entries around the current one; WebKit keeps up to 100.
    private static func history(_ list: WKBackForwardList, length: Int?, limit: Int) -> String {
        guard let current = list.currentItem else { return "### History\n(empty: the tab has loaded nothing)" }
        let back = list.backList, entries = back + [current] + list.forwardList
        let hidden = (length ?? 0) - entries.count
        // Centred on the current entry, sliding to the ends of the list when one side runs short.
        let start = max(0, min(back.count - (limit - 1) / 2, entries.count - limit)), end = min(entries.count, start + limit)
        let earlier = start, later = entries.count - end
        let lines = entries[start..<end].enumerated().map { index, item in
            let offset = start + index - back.count
            let redirect = item.initialURL == item.url ? "" : " (asked for \(item.initialURL.absoluteString))"
            return "- \(offset > 0 ? "+" : "")\(offset)\(offset == 0 ? " (current)" : ""): [\(item.title ?? "")](\(item.url.absoluteString))\(redirect)"
        }
        let left = [earlier > 0 ? "\(earlier) earlier" : nil, later > 0 ? "\(later) later" : nil].compactMap { $0 }
        return "### History\n" + lines.joined(separator: "\n")
            + (left.isEmpty ? "" : "\n- Note: \(left.joined(separator: " and ")) not shown; --max-results=100 for all")
            + (hidden > 0 ? "\n- Note: \(hidden) more entr\(hidden == 1 ? "y is" : "ies are") hidden and skipped by go-back: pages that moved on by script without a click" : "")
    }

    private func describe(_ tab: Tab, note: String? = nil) -> String {
        var out = "### Page\n- URL: \(tab.currentURL)\n- Title: \(tab.currentTitle)"
        if let note { out += "\n- Note: \(note)" }
        if windowHidden {
            out += "\n- Note: " + (MainWindow.putAway(mainWindow.window) ? "the person minimized or hid the window; pages are frozen (agweb show brings it back: only if they said to)"
                : "the window is closed; pages are frozen between commands (agweb show)")
        }
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
        if tab.unreadErrors > 0 {
            out += "\n- Console: \(tab.unreadErrors) new error\(tab.unreadErrors == 1 ? "" : "s") (agweb console error)"
            tab.unreadErrors = 0
        }
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

    /// Secrets as written, JSON-escaped (with and without `\/`, once or twice) and URL-encoded the way `encodeURIComponent` and
    /// form bodies do it, wherever a reply carries them (eval, console, request-body, errors), longest first so a
    /// secret inside another doesn't leave the rest of it showing. Very short ones would mangle unrelated text.
    static func hide(_ secrets: Set<String>, in output: String) -> String {
        let ascii = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        let uri = ascii.union(CharacterSet(charactersIn: "-_.!~*'()")), form = ascii.union(CharacterSet(charactersIn: "*-._ "))
        func json(_ secret: String, _ formatting: JSONEncoder.OutputFormatting) -> String? {
            let encoder = JSONEncoder()
            encoder.outputFormatting = formatting
            return (try? encoder.encode(secret)).map { String(decoding: $0.dropFirst().dropLast(), as: UTF8.self) }
        }
        let forms = secrets.filter { $0.count >= 4 }.flatMap { secret in
            // Twice escaped too: eval prints a JSON.stringify result as JSON.
            let escaped = [json(secret, []), json(secret, .withoutEscapingSlashes)].compactMap { $0 }
            return [secret, secret.addingPercentEncoding(withAllowedCharacters: uri),
                    secret.addingPercentEncoding(withAllowedCharacters: form)?.replacingOccurrences(of: " ", with: "+")].compactMap { $0 }
                + escaped + escaped.compactMap { json($0, .withoutEscapingSlashes) }
        }
        let hidden = Set(forms).sorted { $0.count > $1.count }.reduce(output) { $0.replacingOccurrences(of: $1, with: "<hidden>") }
        // A card or account number a field shows in groups (Stripe's "4242 4242 4242 4242").
        return secrets.filter { $0.count >= 8 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }.reduce(hidden) { text, digits in
            text.replacingOccurrences(of: digits.map(String.init).joined(separator: "[ -]?"), with: "<hidden>", options: .regularExpression)
        }
    }

    /// Commands besides the actions that can make the page run its own code with a user gesture.
    private static let mayRunPageCode: Set = ["eval", "keydown", "keyup", "mousedown", "mouseup", "upload", "download"]

    /// Actions whose reply says what they changed.
    private static let reportsChanges: Set = ["click", "dblclick", "check", "uncheck", "hover", "fill", "select", "type", "press", "drag", "upload"]

    /// The fetch/XHR calls an action started, and how the page tree differs from the one the agent last saw, so it
    /// rarely needs a snapshot after acting. The tree is compared only once the agent has taken a snapshot of this
    /// document; the new tree becomes the baseline, so the next action reports only its own changes.
    private func changes(_ tab: Tab, urlBefore: String) async -> String {
        var out: [String] = []
        // Only finished calls are listed: an action waits for its own, a wait may end with one in flight.
        let calls = tab.requests.filter { ($0["start"] as? Double ?? 0) >= tab.commandStart }
        for call in calls.prefix(10) {
            let status = (call["failure"] == nil ? call["status"] as? Int : nil).map(String.init) ?? "failed"
            // Hidden before it is cut, or a secret across the cut would show its first half.
            let url = Self.hide(secrets, in: call["url"] as? String ?? "")
            out.append("- call: \(call["method"] as? String ?? "GET") \(url.prefix(120)) => \(status)")
        }
        if calls.count > 10 { out.append("- (\(calls.count - 10) more calls; requests to see them)") }
        let commits = tab.commits
        if let last = tab.snapshots[""], let snapshot = try? await snapshotTree(tab, "") {
            if snapshot.doc != last.doc {
                tab.snapshots[""] = nil
                out.append("- navigated: snapshot for the new page")
            } else {
                tab.snapshots[""] = snapshot
                tab.baselineCommits = commits
                let lines = Snapshot.diff(from: last.tree, to: snapshot.tree)?.split(separator: "\n").map(String.init) ?? []
                let limit = 20
                out += lines.prefix(limit)
                if lines.count > limit { out.append("- (\(lines.count - limit) more lines; snapshot to see the page)") }
            }
        } else if tab.currentURL != urlBefore {
            out.append("- navigated: snapshot for the new page")
        }
        return out.isEmpty ? "" : "\n### Changes\n" + out.joined(separator: "\n")
    }

    /// Commands whose first argument is an element to act on (drag: both), which they wait for.
    private static let actsOnTarget: Set = ["click", "dblclick", "check", "uncheck", "hover", "fill", "select", "download", "scroll-into-view"]

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
