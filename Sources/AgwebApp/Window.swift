import AgwebCore
import AppKit
import SwiftUI
import WebKit

/// One window for every agent: a sidebar of workspaces and their tabs, and a content area where all web views
/// sit stacked in the same frame, the displayed tab on top and the dashboard above them all. Which tabs are
/// shown to WebKit is Visibility.swift's business.
@MainActor
final class MainWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    let model: BrowserModel
    let urlField = AddressField()
    let container = NSView()
    lazy var findBar = FindBar(webView: { [weak self] in self?.model.displayedTab?.webView }, close: { [weak self] in self?.closeFind() })
    var findOpen = false
    /// The address field's narrowest width; less while the find field shares the toolbar.
    var urlMinWidth: NSLayoutConstraint?
    var findTabID: Int?
    private lazy var dashboard = NSHostingView(rootView: DashboardView(model: model))
    let dashboardButton = NSButton()
    /// Tab views in `container`.
    private var hosts = 0
    private let placeholder = NSTextField(labelWithString: "No tabs yet.\nAgents: agweb -w <task> open <url>    You: ⌘T")

    init(model: BrowserModel) {
        self.model = model
        placeholder.alignment = .center
        placeholder.textColor = .secondaryLabelColor
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        container.clipsToBounds = true
        container.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        let split = NSSplitViewController()
        let sidebar = NSSplitViewItem(sidebarWithViewController: NSHostingController(rootView: SidebarView(model: model)))
        sidebar.minimumThickness = 200
        sidebar.maximumThickness = 380
        let content = NSViewController()
        content.view = container
        split.addSplitViewItem(sidebar)
        split.addSplitViewItem(NSSplitViewItem(viewController: content))

        window = AgentWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.contentViewController = split
        window.title = "Agweb"
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        // Workspaces restore themselves; AppKit's own restore would also reopen a quit test instance's window.
        window.isRestorable = false
        window.setContentSize(NSSize(width: 1280, height: 820))
        window.center()
        super.init()
        (window as? AgentWindow)?.onSideButton = { [weak self] forward in forward ? self?.goForward(nil) : self?.goBack(nil) }
        (window as? AgentWindow)?.onPersonInput = { [weak model] webView, event in
            guard let model, let tab = model.workspaces.lazy.flatMap(\.tabs).first(where: { $0.webView === webView }) else { return }
            tab.personInputAt = Date()
            tab.markUsed()
            // Passkeys: a click or a key in the page shown, not a ⌘ shortcut or a right click.
            if tab === model.displayedTab, event.type == .leftMouseDown || (event.type == .keyDown && !event.modifierFlags.contains(.command)) {
                tab.passkeyInputAt = Date()
            }
        }
        window.delegate = self
        installToolbar()
        // After the toolbar so it can't shift the frame. Not `setFrameAutosaveName`: AppKit drops a frame saved on a
        // secondary display whose visible height has since changed by a point, and recenters on the main one.
        if let saved = Settings.store.string(forKey: Self.frameKey).map(NSRectFromString),
           saved.width >= 400, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(saved) }) {
            window.setFrame(saved, display: false)
        }
    }

    private static let frameKey = "agwebMainFrame"

    private func saveFrame() { Settings.store.set(NSStringFromRect(window.frame), forKey: Self.frameKey) }
    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidResize(_ notification: Notification) { saveFrame() }

    /// Closed (ordered out), minimized or hidden windows don't render, so snapshots and recordings get nothing.
    static func isRendering(_ window: NSWindow) -> Bool { window.isVisible && !window.isMiniaturized }
    /// Why pages aren't rendering and what to do: a window the person minimized or hid is theirs to bring back.
    static func notRendering(_ window: NSWindow) -> String {
        putAway(window) ? "the person minimized or hid the window, so pages are not rendering; ask them to bring it back, or run agweb show only if they said to"
            : "the window is closed, so pages are not rendering; run: agweb show"
    }

    static func putAway(_ window: NSWindow) -> Bool { window.isMiniaturized || NSApp.isHidden }

    /// Puts a closed window back on screen behind everything else, so it appears in the window list without covering
    /// or activating anything. One the person minimized, or hid with the app, stays so: ordering it in brings it
    /// back. Unless `evenIfPutAway`, for an agent asking for their view (show, ask).
    func showQuietly(evenIfPutAway: Bool = false) {
        guard !window.isVisible, evenIfPutAway || !Self.putAway(window) else { return }
        window.orderBack(nil)
    }

    /// Each web view sits in an opaque host filling the content area, so a tab resized smaller doesn't show the
    /// tabs stacked under it.
    func add(_ webView: WKWebView) {
        let host = NSView(frame: container.bounds)
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        host.clipsToBounds = true
        webView.frame = host.bounds
        webView.autoresizingMask = [.width, .height]
        host.addSubview(webView)
        container.addSubview(host, positioned: .above, relativeTo: placeholder)
        hosts += 1
        // Hidden while any tab exists: a tab hidden in a covered window would otherwise show it as the window comes back.
        placeholder.isHidden = true
    }

    private static let askBar = NSUserInterfaceItemIdentifier("ask")

    /// `ask`'s bar, floating over the bottom of the tab so it hides little of the page.
    func showAsk(on webView: WKWebView, message: String, done: @escaping () -> Void) {
        guard let host = webView.superview else { return }
        hideAsk(on: webView)
        let bar = NSHostingView(rootView: AskBar(message: message, done: done))
        bar.identifier = Self.askBar
        let width = min(bar.fittingSize.width, host.bounds.width - 32)
        bar.frame = NSRect(x: (host.bounds.width - width) / 2, y: 16, width: width, height: bar.fittingSize.height)
        bar.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
        host.addSubview(bar)
    }

    func hideAsk(on webView: WKWebView) {
        webView.superview?.subviews.filter { $0.identifier == Self.askBar }.forEach { $0.removeFromSuperview() }
    }

    static let loginBar = NSUserInterfaceItemIdentifier("login")

    /// A Basic or Digest login for a 401 page, floating just below the toolbar; it never takes focus.
    func showLogin(on webView: WKWebView, site: String, realm: String, refused: String?, submit: @escaping (String, String) -> Void) {
        guard let host = webView.superview else { return }
        hideLogin(on: webView)
        let bar = NSHostingView(rootView: LoginBar(site: site, realm: realm, refused: refused, submit: submit))
        bar.identifier = Self.loginBar
        let width = min(bar.fittingSize.width, host.bounds.width - 32), height = bar.fittingSize.height
        bar.frame = NSRect(x: (host.bounds.width - width) / 2, y: host.bounds.height - topInset - height - 12, width: width, height: height)
        bar.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        host.addSubview(bar)
    }

    func hideLogin(on webView: WKWebView) {
        webView.superview?.subviews.filter { $0.identifier == Self.loginBar }.forEach { $0.removeFromSuperview() }
    }

    static let keyBar = NSUserInterfaceItemIdentifier("security-key")

    /// A security key ceremony's bar, floating just below the toolbar: what to do with the key, its PIN, Cancel. It never
    /// takes focus by itself. Shown again at each step, since its size changes.
    func showKey(on webView: WKWebView, _ ceremony: KeyCeremony) {
        guard let host = webView.superview else { return }
        hideKey(on: webView)
        let bar = NSHostingView(rootView: KeyBar(ceremony: ceremony))
        bar.identifier = Self.keyBar
        let width = min(bar.fittingSize.width, host.bounds.width - 32), height = bar.fittingSize.height
        bar.frame = NSRect(x: (host.bounds.width - width) / 2, y: host.bounds.height - topInset - height - 12, width: width, height: height)
        bar.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        host.addSubview(bar)
    }

    func hideKey(on webView: WKWebView) {
        webView.superview?.subviews.filter { $0.identifier == Self.keyBar }.forEach { $0.removeFromSuperview() }
    }

    /// Over every tab; the tabs underneath are hidden while it shows.
    func showDashboard(_ open: Bool) {
        dashboardButton.state = open ? .on : .off
        // Removed, not hidden: a hidden NSHostingView still takes clicks, passing the page mouse-downs but no
        // mouse-ups, which leaves WebKit holding the button until a restart.
        guard open else { return dashboard.removeFromSuperview() }
        dashboard.frame = container.bounds
        dashboard.autoresizingMask = [.width, .height]
        container.addSubview(dashboard, positioned: .above, relativeTo: nil)
    }

    @objc func toggleDashboard(_ sender: Any?) { model.dashboardOpen.toggle() }

    /// The dashboard as PNG, drawn by AppKit, so it needs no screen recording permission.
    func dashboardPNG() -> Data? {
        guard let rep = dashboard.bitmapImageRepForCachingDisplay(in: dashboard.bounds) else { return nil }
        dashboard.cacheDisplay(in: dashboard.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    /// On the host: WebKit sees a hidden ancestor as a hidden page.
    func setHidden(_ webView: WKWebView, _ hidden: Bool) {
        if let host = webView.superview, host.isHidden != hidden { host.isHidden = hidden }
    }

    func isHidden(_ webView: WKWebView) -> Bool { webView.superview?.isHidden ?? false }

    func remove(_ webView: WKWebView) {
        if webView.superview != nil { hosts -= 1 }
        webView.superview?.removeFromSuperview()
        webView.removeFromSuperview()
        placeholder.isHidden = hosts > 0
    }

    func bringToTop(_ webView: WKWebView) {
        guard let host = webView.superview else { return }
        let responder = window.firstResponder
        // The dashboard stays above every tab.
        if dashboard.superview != nil {
            container.addSubview(host, positioned: .below, relativeTo: dashboard)
        } else if container.subviews.last !== host {
            container.addSubview(host, positioned: .above, relativeTo: nil)
        }
        if responder === webView { window.makeFirstResponder(webView) }
    }

    /// The toolbar band a full-size content view lays over the top of the content area; WebKit insets pages below it.
    var topInset: CGFloat { max(0, container.convert(container.bounds, to: nil).maxY - window.contentLayoutRect.maxY) }

    /// A web view `size` points across and that tall below the toolbar band, pinned to the top left; nil fills the
    /// content area again. Larger than the window is clipped on screen, not in snapshots.
    /// `centered`: in the middle of the window's width (an emulated phone), else at the top left.
    func setSize(_ webView: WKWebView, _ size: CGSize?, centered: Bool = false) {
        guard let host = webView.superview else { return }
        guard let size else {
            webView.frame = host.bounds
            webView.autoresizingMask = [.width, .height]
            return
        }
        webView.autoresizingMask = centered ? [.minXMargin, .maxXMargin, .minYMargin] : [.maxXMargin, .minYMargin]
        // Below the toolbar, not under it: a narrow page behind the toolbar's glass showed as a strip of its colour.
        let x = centered ? max(0, ((host.bounds.width - size.width) / 2).rounded()) : 0
        webView.frame = NSRect(x: x, y: host.bounds.height - topInset - size.height, width: size.width, height: size.height)
    }

    /// The dashboard hides the address item and shows it again a moment after it closes, so the field may join the
    /// window late (⌘T in the dashboard); tries for about half a second.
    func focusAddress(tries: Int = 15) {
        window.layoutIfNeeded()
        if urlField.window === window, !urlField.isHiddenOrHasHiddenAncestor, window.makeFirstResponder(urlField) {
            urlField.selectText(nil)
        } else if tries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in self?.focusAddress(tries: tries - 1) }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    // MARK: Menu and toolbar actions, all on the displayed tab

    @objc func newTab(_ sender: Any?) { model.onNewTab?(nil) }

    /// Asks for a name and a profile, then opens the workspace with an empty tab, its address field focused.
    @objc func newWorkspace(_ sender: Any?) {
        let taken = Set(model.workspaces.map(\.name))
        let name = NSTextField(string: (1...).lazy.map { "workspace-\($0)" }.first { !taken.contains($0) }!)
        let profile = NSPopUpButton()
        profile.addItem(withTitle: "Fresh profile")
        profile.addItems(withTitles: Profiles.names.sorted())
        let fields = NSStackView(views: [name, profile])
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.frame = NSRect(x: 0, y: 0, width: 260, height: 56)
        name.widthAnchor.constraint(equalToConstant: 260).isActive = true
        let alert = NSAlert()
        alert.messageText = "New Workspace"
        alert.informativeText = "A workspace's tabs share its profile: a named one keeps its logins."
        alert.accessoryView = fields
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = name
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let chosen = name.stringValue.trimmingCharacters(in: .whitespaces)
            let error = chosen.isEmpty ? "A workspace needs a name."
                : taken.contains(chosen) ? "\(chosen) is open already."
                : self.model.onNewWorkspace?(chosen, profile.indexOfSelectedItem == 0 ? nil : profile.titleOfSelectedItem)
            guard let error else { return }
            let failed = NSAlert()
            failed.messageText = "Can't create the workspace"
            failed.informativeText = error
            failed.beginSheetModal(for: self.window)
        }
    }

    /// ⌘W closes the window in front when it isn't this one (Settings, About), as in any Mac app.
    @objc func closeTab(_ sender: Any?) {
        if let front = NSApp.keyWindow, front !== window { front.performClose(sender); return }
        if let tab = model.displayedTab { model.onCloseTab?(tab) } else { window.orderOut(nil) }
    }

    @objc func openLocation(_ sender: Any?) {
        if model.displayedTab == nil { model.onNewTab?(nil) } else { model.dashboardOpen = false; focusAddress() }
    }

    /// Every tab in sidebar order, across workspaces, wrapping at either end.
    @objc func showNextTab(_ sender: Any?) { stepTab(1) }
    @objc func showPreviousTab(_ sender: Any?) { stepTab(-1) }

    /// ⌘1…⌘8 show that tab in sidebar order, ⌘9 the last, as in Safari; the menu item's tag is the number.
    @objc func showTabNumber(_ sender: NSMenuItem) {
        let tabs = model.workspaces.flatMap(\.tabs)
        guard let tab = sender.tag == 9 ? tabs.last : tabs.dropFirst(sender.tag - 1).first else { return }
        model.dashboardOpen = false
        model.display(tab.id)
    }

    private func stepTab(_ step: Int) {
        let tabs = model.workspaces.flatMap(\.tabs)
        guard !tabs.isEmpty else { return }
        let index = tabs.firstIndex { $0.id == model.displayedTabID }.map { ($0 + step + tabs.count) % tabs.count } ?? 0
        model.dashboardOpen = false
        model.display(tabs[index].id)
    }

    // The person's, from the toolbar, the menu or a side button: use, like a click in the page.
    @objc func goBack(_ sender: Any?) { model.displayedTab?.markUsed(); model.displayedTab?.webView.goBack() }
    @objc func goForward(_ sender: Any?) { model.displayedTab?.markUsed(); model.displayedTab?.webView.goForward() }
    @objc func reloadPage(_ sender: Any?) {
        guard let tab = model.displayedTab else { return }
        tab.markUsed()
        tab.resubmitAllowed = true
        if tab.webView.reload() == nil { tab.resubmitAllowed = false }
    }

    // Safari's steps. Clicks and screenshots already scale by pageZoom; a zoomed page has a narrower CSS viewport,
    // so this is for the person, per tab, and not saved.
    private static let zoomSteps: [CGFloat] = [0.5, 0.75, 0.85, 1, 1.15, 1.25, 1.5, 1.75, 2, 2.5, 3]
    @objc func zoomIn(_ sender: Any?) { zoom { zoom in Self.zoomSteps.first { $0 > zoom + 0.001 } } }
    @objc func zoomOut(_ sender: Any?) { zoom { zoom in Self.zoomSteps.last { $0 < zoom - 0.001 } } }
    @objc func actualSize(_ sender: Any?) { zoom { _ in 1 } }

    private func zoom(_ next: (CGFloat) -> CGFloat?) {
        guard let webView = model.displayedTab?.webView, let zoom = next(webView.pageZoom) else { return }
        webView.pageZoom = zoom
    }
}

struct SidebarView: View {
    let model: BrowserModel
    @AppStorage(Settings.textSize, store: Settings.store) private var textSize = TextSize.medium

    var body: some View {
        // Nothing is selected while the dashboard shows, so clicking even the displayed tab goes back to it. A tap
        // gesture on the rows for that would stop List selecting them.
        List(selection: Binding(get: { model.dashboardOpen ? nil : model.displayedTabID },
                                set: { if let id = $0 { model.dashboardOpen = false; model.display(id) } })) {
            ForEach(model.workspaces) { workspace in
                Section {
                    ForEach(workspace.tabs) { tab in
                        // The person's own workspaces have no agent tab: none of theirs is dimmed.
                        TabRow(tab: tab, driven: workspace.currentID == nil || tab.id == workspace.currentID, agent: workspace.currentID != nil,
                               working: workspace.workingTabID == tab.id) { model.onCloseTab?(tab) }
                            .tag(tab.id)
                            .contextMenu {
                                Button("Close Tab") { model.onCloseTab?(tab) }
                                SoundButton(tab: tab, model: model)
                                Button("New Tab in \(workspace.name)") { model.onNewTab?(workspace) }
                            }
                    }
                } header: {
                    WorkspaceHeader(workspace: workspace, model: model)
                }
            }
        }
        .listStyle(.sidebar)
        .environment(\.sidebarRowSize, textSize.sidebarRows)
        // Rows only as tall as their text: the sidebar's default left the selection tall and the list sparse.
        .environment(\.defaultMinListRowHeight, 18)
        .safeAreaInset(edge: .top) {
            if let label = Agweb.label {
                Label("Test: \(label)", systemImage: "flask").font(.caption.bold()).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 4)
                    .help("A separate instance keeping everything in \(Agweb.root.path)")
            }
        }
    }
}

private struct WorkspaceHeader: View {
    let workspace: Workspace
    let model: BrowserModel

    var body: some View {
        HStack(spacing: 6) {
            Text(workspace.name)
            if let profile = workspace.profile {
                Label(profile, systemImage: "person.crop.circle").labelStyle(.titleAndIcon).foregroundStyle(.tertiary)
                    .help("Profile \(profile): logins shared by every workspace using it")
            }
            Spacer()
        }
        .contextMenu {
            Button("New Tab") { model.onNewTab?(workspace) }
            Button("Close Workspace") { model.onCloseWorkspace?(workspace) }
        }
    }
}

private struct TabRow: View {
    let tab: Tab
    let driven: Bool
    let agent: Bool
    /// An agent's command is running on this tab (or just ended).
    let working: Bool
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            // The tab the agent's next command goes to reads in the normal color; its other tabs are dimmed.
            Text(tab.title.isEmpty ? (tab.url.isEmpty ? "New tab" : tab.url) : tab.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(driven ? .primary : .secondary)
                .help(driven && agent ? "The tab this workspace's agent drives" : "")
            Spacer(minLength: 0)
            MutedIcon(tab: tab).font(.caption2)
            ActivityDot(tab: tab, working: working)
            Button(action: close) { Image(systemName: "xmark").font(.caption2) }
                .buttonStyle(.borderless)
                .opacity(hovering ? 1 : 0)
                .help("Close tab")
        }
        .onHover { hovering = $0 }
    }
}

/// Mute Tab or Unmute Tab, in the tab's menu in the sidebar and the dashboard. Unmuted, it is heard even hidden.
struct SoundButton: View {
    let tab: Tab
    let model: BrowserModel

    var body: some View {
        Button(tab.isMuted ? "Unmute Tab" : "Mute Tab") { model.onSound?(tab, tab.isMuted) }
    }
}

/// Shown while the tab is muted: by the person from its menu, or as an agent's hidden tab is by default.
struct MutedIcon: View {
    let tab: Tab

    var body: some View {
        if tab.isMuted {
            Image(systemName: "speaker.slash.fill").foregroundStyle(.secondary)
                .help(tab.personSound == false ? "Muted (the tab's menu unmutes it)"
                                               : "Muted while hidden, as an agent's tabs are (the tab's menu unmutes it)")
        }
    }
}

/// Orange while the agent waits for the person (`ask`), green while its command works on the tab; the sidebar and
/// the dashboard.
struct ActivityDot: View {
    let tab: Tab
    let working: Bool

    var body: some View {
        if let asking = tab.asking {
            Circle().fill(Color.orange).frame(width: 7, height: 7).help("The agent asks you: \(asking)")
        } else if working {
            Circle().fill(Color.green).frame(width: 7, height: 7).help("The agent is working on this tab")
        }
    }
}

private struct AskBar: View {
    let message: String
    let done: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            Text(message).lineLimit(3).frame(maxWidth: 480, alignment: .leading)
            // No Return shortcut: it would take Enter from the login form under the bar.
            Button("Done", action: done)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .fixedSize()
    }
}

private struct LoginBar: View {
    let site: String
    let realm: String
    let refused: String?
    let submit: (String, String) -> Void
    @State private var user: String
    @State private var password = ""

    init(site: String, realm: String, refused: String?, submit: @escaping (String, String) -> Void) {
        (self.site, self.realm, self.refused, self.submit) = (site, realm, refused, submit)
        _user = State(initialValue: refused ?? "")
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "key.fill").foregroundStyle(refused == nil ? Color.secondary : Color.red)
            Text(refused.map { "\(site) refused \($0)" } ?? "\(site) asks for a login").lineLimit(1)
                .help(realm.isEmpty ? "" : "Realm: \(realm)")
            TextField("User", text: $user).frame(width: 120)
            SecureField("Password", text: $password).frame(width: 120).onSubmit(logIn)
            Button("Log In", action: logIn).disabled(user.isEmpty)
        }
        .textFieldStyle(.roundedBorder)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .fixedSize()
    }

    private func logIn() {
        if !user.isEmpty { submit(user, password) }
    }
}

private struct KeyBar: View {
    let ceremony: KeyCeremony
    @State private var pin = ""

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "key.horizontal.fill").foregroundStyle(wrong ? Color.red : Color.secondary)
            Text(message).lineLimit(2).frame(maxWidth: 420, alignment: .leading)
                .help("Asked in workspace \(ceremony.workspace). Log: \(KeyLog.file.path)")
            if case .pin = ceremony.phase {
                SecureField("PIN", text: $pin).frame(width: 110).onSubmit(send)
                Button("Continue", action: send).disabled(pin.isEmpty)
            }
            Button("Cancel") { ceremony.cancel("the person cancelled") }
        }
        .textFieldStyle(.roundedBorder)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .fixedSize()
    }

    private var wrong: Bool { if case .pin(_, true) = ceremony.phase { true } else { false } }

    private var message: String {
        let what = "\(ceremony.doing) \(ceremony.site)"
        switch ceremony.phase {
        case .insert: return "Plug in your security key to \(what)"
        case .touch: return "Touch your security key to \(what)"
        case .pin(let retries, let wrong):
            let left = retries.map { " \($0) \($0 == 1 ? "attempt" : "attempts") left." } ?? ""
            return (wrong ? "Wrong PIN.\(left) " : "") + "Enter your security key's PIN to \(what)"
        }
    }

    private func send() {
        guard !pin.isEmpty else { return }
        ceremony.submitPIN(pin)
        pin = ""
    }
}

/// WebKit ignores mouse moves in a window that is not key, so agents' hovers would never happen. While the app
/// is in the background the window reports key, which WebKit reads when key status changes; making it key for
/// real would take the keyboard from the person's app. Scoping this to each move does not work for that reason. It also
/// turns on secure input for a focused password field, which `Browser.releaseSecureInput` undoes.
final class AgentWindow: NSWindow {
    override var isKeyWindow: Bool { super.isKeyWindow || !NSApp.isActive }

    /// While an agent's key or mouse press holds the keyboard (Browser.withKeyboard), another tab's page may not take
    /// it (WebKit asks for a page's focus() or a press into a field): WebKit would reset the agent's rich-editor caret
    /// mid-word. The person's own clicks and keys, and the toolbar's fields, always get it.
    var keyboardHolder: NSResponder?
    private var personEvents = 0

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if let holder = keyboardHolder, responder !== holder, personEvents == 0, responder is WKWebView { return false }
        return super.makeFirstResponder(responder)
    }

    /// The person's mouse buttons 4 and 5 go back and forward, as in Safari; WebKit ignores them. Agents' clicks
    /// go to the web view directly and never pass here.
    var onSideButton: ((_ forward: Bool) -> Void)?
    /// The person's click or key in a tab, before WebKit gets it: a page's copy that follows goes to the person's
    /// clipboard (ClipboardRouting.swift), and a click or key in the page shown lets it use passkeys for a few seconds.
    /// Agents' clicks never pass here; their keys can, see NativeInput.isSent. The person's keys reach the window only
    /// while agweb is in front.
    var onPersonInput: ((WKWebView, NSEvent) -> Void)?

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // From the frame view, whose coordinates are the window's: it has the toolbar over the page, so a click on
            // the address field is not one on the page.
            if let frame = contentView?.superview, let view = frame.hitTest(event.locationInWindow) { notePerson(view, event) }
        case .keyDown:
            if !NativeInput.isSent(event), NSApp.isActive, let view = firstResponder as? NSView { notePerson(view, event) }
        default: break
        }
        if [.otherMouseDown, .otherMouseUp].contains(event.type), [3, 4].contains(event.buttonNumber) {
            if event.type == .otherMouseDown { onSideButton?(event.buttonNumber == 4) }
            return
        }
        personEvents += NativeInput.isSent(event) ? 0 : 1
        defer { personEvents -= NativeInput.isSent(event) ? 0 : 1 }
        super.sendEvent(event)
    }

    /// ⌘-keys reach the web view here, not through sendEvent. An agent's ⌘-key the page left alone comes back here
    /// from WebKit when agweb is in front; taken here, it never reaches the Edit menu, whose Copy and Paste would use
    /// the person's clipboard (and ⌘W would close a tab).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if NativeInput.isSent(event) { return true }
        if NSApp.isActive, let view = firstResponder as? NSView { notePerson(view, event) }
        return super.performKeyEquivalent(with: event)
    }

    private func notePerson(_ view: NSView, _ event: NSEvent) {
        var view: NSView? = view
        while let current = view, !(current is WKWebView) { view = current.superview }
        if let webView = view as? WKWebView, !NativeInput.stroking.contains(ObjectIdentifier(webView)) { onPersonInput?(webView, event) }
    }
}

