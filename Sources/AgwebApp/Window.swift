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
    let urlField = NSTextField()
    private let container = NSView()
    private lazy var dashboard = NSHostingView(rootView: DashboardView(model: model))
    let dashboardButton = NSButton()
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
        window.setContentSize(NSSize(width: 1280, height: 820))
        window.center()
        super.init()
        window.delegate = self
        installToolbar()
        // After the toolbar so it can't shift the frame. Not `setFrameAutosaveName`: AppKit drops a frame saved on a
        // secondary display whose visible height has since changed by a point, and recenters on the main one.
        if let saved = UserDefaults.standard.string(forKey: Self.frameKey).map(NSRectFromString),
           saved.width >= 400, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(saved) }) {
            window.setFrame(saved, display: false)
        }
    }

    // Test instances on their own socket keep their own frame, so they never move the person's window.
    private static let frameKey = Agweb.customSocket ? "agwebTestFrame" : "agwebMainFrame"

    private func saveFrame() { UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.frameKey) }
    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidResize(_ notification: Notification) { saveFrame() }

    /// Closed (ordered out) or minimized windows don't render, so snapshots and recordings get nothing.
    static func isRendering(_ window: NSWindow) -> Bool { window.isVisible && !window.isMiniaturized }
    static let notRendering = "the window is closed or minimized, so pages are not rendering; run: agweb show"

    /// Puts the window on screen behind everything else, so it appears in the window list without
    /// covering or activating anything.
    func showQuietly() {
        if !window.isVisible { window.orderBack(nil) }
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
    }

    /// Over every tab; the tabs underneath are hidden while it shows.
    func showDashboard(_ open: Bool) {
        dashboardButton.state = open ? .on : .off
        if dashboard.superview == nil {
            dashboard.frame = container.bounds
            dashboard.autoresizingMask = [.width, .height]
            container.addSubview(dashboard, positioned: .above, relativeTo: nil)
        }
        dashboard.isHidden = !open
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
        webView.superview?.removeFromSuperview()
        webView.removeFromSuperview()
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
    func setSize(_ webView: WKWebView, _ size: CGSize?) {
        guard let host = webView.superview else { return }
        guard let size else {
            webView.frame = host.bounds
            webView.autoresizingMask = [.width, .height]
            return
        }
        webView.autoresizingMask = [.maxXMargin, .minYMargin]
        let height = size.height + topInset
        webView.frame = NSRect(x: 0, y: host.bounds.height - height, width: size.width, height: height)
    }

    func focusAddress() {
        window.makeFirstResponder(urlField)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    // MARK: Menu and toolbar actions, all on the displayed tab

    @objc func newTab(_ sender: Any?) { model.onNewTab?(nil) }

    @objc func closeTab(_ sender: Any?) {
        if let tab = model.displayedTab { model.onCloseTab?(tab) } else { window.orderOut(nil) }
    }

    @objc func openLocation(_ sender: Any?) {
        if model.displayedTab == nil { model.onNewTab?(nil) } else { focusAddress() }
    }

    /// Every tab in sidebar order, across workspaces, wrapping at either end.
    @objc func showNextTab(_ sender: Any?) { stepTab(1) }
    @objc func showPreviousTab(_ sender: Any?) { stepTab(-1) }

    private func stepTab(_ step: Int) {
        let tabs = model.workspaces.flatMap(\.tabs)
        guard !tabs.isEmpty else { return }
        let index = tabs.firstIndex { $0.id == model.displayedTabID }.map { ($0 + step + tabs.count) % tabs.count } ?? 0
        model.dashboardOpen = false
        model.display(tabs[index].id)
    }

    @objc func goBack(_ sender: Any?) { model.displayedTab?.webView.goBack() }
    @objc func goForward(_ sender: Any?) { model.displayedTab?.webView.goForward() }
    @objc func reloadPage(_ sender: Any?) { model.displayedTab?.webView.reload() }

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
    @AppStorage(Settings.textSize) private var textSize = TextSize.medium

    var body: some View {
        // Nothing is selected while the dashboard shows, so clicking even the displayed tab goes back to it. A tap
        // gesture on the rows for that would stop List selecting them.
        List(selection: Binding(get: { model.dashboardOpen ? nil : model.displayedTabID },
                                set: { if let id = $0 { model.dashboardOpen = false; model.display(id) } })) {
            ForEach(model.workspaces) { workspace in
                Section {
                    ForEach(workspace.tabs) { tab in
                        TabRow(tab: tab, driven: tab.id == workspace.currentID) { model.onCloseTab?(tab) }
                            .tag(tab.id)
                            .contextMenu {
                                Button("Close Tab") { model.onCloseTab?(tab) }
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
            if workspace.busy { ProgressView().controlSize(.mini) }
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
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(driven ? Color.green : Color.clear)
                .frame(width: 6, height: 6)
                .help("the tab this agent is driving")
            Text(tab.title.isEmpty ? (tab.url.isEmpty ? "New tab" : tab.url) : tab.title)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Button(action: close) { Image(systemName: "xmark").font(.caption2) }
                .buttonStyle(.borderless)
                .opacity(hovering ? 1 : 0)
                .help("Close tab")
        }
        .onHover { hovering = $0 }
    }
}

/// WebKit ignores mouse moves in a window that is not key, so agents' hovers would never happen. While the app
/// is in the background the window reports key, which WebKit reads when key status changes; making it key for
/// real would take the keyboard from the person's app. Scoping this to each move does not work for that reason.
final class AgentWindow: NSWindow {
    override var isKeyWindow: Bool { super.isKeyWindow || !NSApp.isActive }
}
