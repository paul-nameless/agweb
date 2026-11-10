import AppKit
import WebKit

// WebKit throttles only tabs it sees as hidden (view hidden, out of the window, or the window occluded); tabs stacked
// under the displayed one all count as visible, so every covered page animated and painted at full rate. A tab is
// shown only while it is displayed, its agent's command runs on it, it is being recorded, or for a short while after
// the agent's last command (toggling around every command would refetch on each visibilitychange).
extension Browser {
    static let awakeAfterCommand: Double = 10

    func needsVisible(_ tab: Tab) -> Bool {
        if model.displayedTabID == tab.id { return true }
        let workspace = tab.workspace
        guard workspace.currentID == tab.id else { return false }
        return workspace.busy || workspace.recorder != nil || tab.awakeUntil > Date()
    }

    func updateVisibility() {
        for tab in model.workspaces.lazy.flatMap(\.tabs) { mainWindow.setHidden(tab.webView, !needsVisible(tab)) }
    }

    /// Before a command: shown, and WebKit has applied it (about 1 ms), so rAF, hover and rendering run again.
    func wake(_ tab: Tab) async {
        guard mainWindow.isHidden(tab.webView) else { return }
        mainWindow.setHidden(tab.webView, false)
        await tab.activityStateApplied()
    }


    func keepAwakeAfterCommand(_ tab: Tab) {
        tab.awakeUntil = Date().addingTimeInterval(Self.awakeAfterCommand)
        Task {
            try? await Task.sleep(for: .seconds(Self.awakeAfterCommand + 0.1))
            self.updateVisibility()
        }
    }
}
