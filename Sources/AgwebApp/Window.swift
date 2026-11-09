import AgwebCore
import AppKit
import SwiftUI
import WebKit

/// One window for every agent: a sidebar of sessions and their tabs, and a content area where all web views
/// sit stacked in the same frame. The displayed tab is simply the top one. Nothing is hidden, so WebKit keeps
/// every tab "visible" and agents can render, snapshot and click in tabs nobody is looking at.
@MainActor
final class MainWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    let model: BrowserModel
    let urlField = NSTextField()
    private let container = NSView()
    private let placeholder = NSTextField(labelWithString: "No tabs yet.\nAgents: agweb -s=<agent> open <url>    You: ⌘T")

    init(model: BrowserModel) {
        self.model = model
        placeholder.alignment = .center
        placeholder.textColor = .secondaryLabelColor
        placeholder.translatesAutoresizingMaskIntoConstraints = false
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
        // The autosave name only saves; restoring is explicit, and after the toolbar so it can't shift the frame.
        // AppKit moves a frame saved on a display that is gone onto one that exists.
        window.setFrameUsingName(Self.frameName)
        window.setFrameAutosaveName(Self.frameName)
    }

    // Test instances on their own socket keep their own frame, so they never move the person's window.
    private static let frameName = Agweb.customSocket ? "agwebTest" : "agwebMain"

    /// Closed (ordered out) or minimized windows don't render, so snapshots and recordings get nothing.
    static func isRendering(_ window: NSWindow) -> Bool { window.isVisible && !window.isMiniaturized }
    static let notRendering = "the window is closed or minimized, so pages are not rendering; run: agweb show"

    /// Puts the window on screen behind everything else, so it appears in the window list without
    /// covering or activating anything.
    func showQuietly() {
        if !window.isVisible { window.orderBack(nil) }
    }

    func add(_ webView: WKWebView) {
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView, positioned: .above, relativeTo: placeholder)
    }

    func bringToTop(_ webView: WKWebView) {
        guard container.subviews.last !== webView else { return }
        let responder = window.firstResponder
        container.addSubview(webView, positioned: .above, relativeTo: nil)
        if responder === webView { window.makeFirstResponder(webView) }
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
            ForEach(model.sessions) { session in
                Section {
                    ForEach(session.tabs) { tab in
                        TabRow(tab: tab, driven: tab.id == session.currentID) { model.onCloseTab?(tab) }
                            .tag(tab.id)
                            .contextMenu {
                                Button("Close Tab") { model.onCloseTab?(tab) }
                                Button("New Tab in \(session.name)") { model.onNewTab?(session) }
                            }
                    }
                } header: {
                    SessionHeader(session: session, model: model)
                }
            }
        }
        .listStyle(.sidebar)
    }
}

private struct SessionHeader: View {
    let session: Session
    let model: BrowserModel

    var body: some View {
        HStack(spacing: 6) {
            Text(session.name)
            if session.profile != session.name {
                Text(session.profile).foregroundStyle(.tertiary)
            }
            Spacer()
            if session.busy { ProgressView().controlSize(.mini) }
            Button { model.onNewTab?(session) } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .help("New tab in \(session.name)")
        }
        .contextMenu {
            Button("New Tab") { model.onNewTab?(session) }
            Button("Close Session") { model.onCloseSession?(session) }
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
