import AgwebCore
import AppKit
import SwiftUI
import WebKit

/// One window for every agent: a sidebar of workspaces and their tabs, and a content area where all web views
/// sit stacked in the same frame. The displayed tab is simply the top one. Nothing is hidden, so WebKit keeps
/// every tab "visible" and agents can render, snapshot and click in tabs nobody is looking at.
@MainActor
final class MainWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    let model: BrowserModel
    let urlField = NSTextField()
    private let container = NSView()
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
        window.title = "agweb"
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

    func remove(_ webView: WKWebView) {
        webView.superview?.removeFromSuperview()
        webView.removeFromSuperview()
    }

    func bringToTop(_ webView: WKWebView) {
        guard let host = webView.superview, container.subviews.last !== host else { return }
        let responder = window.firstResponder
        container.addSubview(host, positioned: .above, relativeTo: nil)
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

    @objc func goBack(_ sender: Any?) { model.displayedTab?.webView.goBack() }
    @objc func goForward(_ sender: Any?) { model.displayedTab?.webView.goForward() }
    @objc func reloadPage(_ sender: Any?) { model.displayedTab?.webView.reload() }
}

struct SidebarView: View {
    let model: BrowserModel

    var body: some View {
        List(selection: Binding(get: { model.displayedTabID }, set: { if let id = $0 { model.display(id) } })) {
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
            Button { model.onNewTab?(workspace) } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .help("New tab in \(workspace.name)")
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
