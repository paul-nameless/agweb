import AppKit
import WebKit

// WebKit throttles only tabs it sees as hidden (view hidden, out of the window, or the window occluded); tabs stacked
// under the displayed one all count as visible, so every covered page animated and painted at full rate. A tab is
// shown only while it is displayed, its agent's command runs on it, it is being recorded, a key or button is held in
// it, or for a while after the agent's last command on it (toggling around every command would refetch on each
// visibilitychange).
extension Browser {
    static let awakeAfterCommand = Double(ProcessInfo.processInfo.environment["AGWEB_AWAKE_SECONDS"] ?? "") ?? 30

    func needsVisible(_ tab: Tab) -> Bool {
        if model.displayedTabID == tab.id, !model.dashboardOpen { return true }
        let workspace = tab.workspace
        guard workspace.currentID == tab.id else { return false }
        // A drag or a held Shift spans commands; a page seeing hidden mid-drag cancels it.
        let holding = tab.held.button != nil || !tab.held.modifiers.isEmpty
        return workspace.busy || workspace.recorder != nil || holding || tab.awakeUntil > Date()
    }

    func updateVisibility() {
        for tab in model.workspaces.lazy.flatMap(\.tabs) { setHidden(tab, !needsVisible(tab)) }
    }

    /// Before a command on `tab`: shown, so rAF, hover and rendering run again, and kept awake after the command. A
    /// page shown again refetches on visibilitychange (SWR, React Query), so the command waits for that first.
    func wake(_ tab: Tab) async {
        tab.workspace.actedOn = tab
        tab.lastActivity = Date()
        guard mainWindow.isHidden(tab.webView) else { return }
        setHidden(tab, false)
        guard tab.pendingURL == nil else { return }
        await tab.activityStateApplied()
        await tab.settle()
    }

    /// Hidden agent tabs are muted too: a page playing audio holds its process in the foreground, so it would never be
    /// suspended. The person's own tabs keep playing, as in any browser.
    private func setHidden(_ tab: Tab, _ hidden: Bool) {
        guard mainWindow.isHidden(tab.webView) != hidden else { return }
        mainWindow.setHidden(tab.webView, hidden)
        if tab.workspace.name != Self.userWorkspace { tab.setMuted(hidden) }
    }

    func keepAwakeAfterCommand(_ tab: Tab) {
        tab.awakeUntil = Date().addingTimeInterval(Self.awakeAfterCommand)
        Task {
            try? await Task.sleep(for: .seconds(Self.awakeAfterCommand + 0.1))
            self.updateVisibility()
        }
    }
}
