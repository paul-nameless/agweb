import AppKit
import AgwebCore

/// Workspaces and their tabs outlive the app: saved a second after anything changes and on quit, reopened at
/// launch. A reopened tab loads when it is first shown or driven, so a relaunch doesn't load every page at once.
/// `close` and `close-all` are what end a workspace for good.
struct SavedWorkspaces: Codable {
    struct Workspace: Codable {
        var name: String
        var profile: String?
        var current: Int?
        var tabs: [Tab]
    }

    struct Tab: Codable {
        var url: String
        var title: String
        /// sessionStorage by origin; 0600 like the rest, since it holds tokens.
        var session: [String: [String: String]]?
    }

    var workspaces: [Workspace]
    /// The tab the window showed, as workspace name and index.
    var displayed: String?
    var displayedIndex: Int?
    var dashboard: Bool?
}

extension Browser {
    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            // The tab the person is looking at may be one they log in to by hand.
            await self.model.displayedTab?.captureSession()
            guard !Task.isCancelled else { return }
            self.saveWorkspaces()
            // So a crash loses at most the last second of logins.
            await Profiles.saveSessionCookies()
        }
    }

    func saveWorkspaces() {
        saveTask?.cancel()
        let displayed = model.displayedTab
        let state = SavedWorkspaces(
            workspaces: model.workspaces.map { workspace in
                .init(name: workspace.name, profile: workspace.profile, current: workspace.tabs.firstIndex { $0.id == workspace.currentID },
                      tabs: workspace.tabs.map { .init(url: $0.currentURL, title: $0.currentTitle, session: $0.session.isEmpty ? nil : $0.session) })
            },
            displayed: displayed?.workspace.name, displayedIndex: displayed.flatMap { tab in tab.workspace.tabs.firstIndex { $0 === tab } },
            dashboard: model.dashboardOpen ? true : nil)
        guard let data = try? JSONEncoder().encode(state) else { return }
        let file = Agweb.workspacesFile
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // URLs can carry tokens.
        FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    func restoreWorkspaces() {
        guard let data = try? Data(contentsOf: Agweb.workspacesFile),
              let state = try? JSONDecoder().decode(SavedWorkspaces.self, from: data) else { return }
        for saved in state.workspaces where !model.workspaces.contains(where: { $0.name == saved.name }) {
            guard let workspace = try? existingOrNewWorkspace(named: saved.name, profile: saved.profile) else { continue }
            for savedTab in saved.tabs {
                let url = URL(string: savedTab.url).flatMap { $0.absoluteString == "about:blank" ? nil : $0 }
                let tab = addTab(to: workspace, display: false, lazy: url != nil)
                tab.pendingURL = url
                tab.url = savedTab.url
                tab.title = savedTab.title
                tab.session = savedTab.session ?? [:]
                tab.restoredSession = savedTab.session
            }
            if let index = saved.current, workspace.tabs.indices.contains(index) { workspace.currentID = workspace.tabs[index].id }
        }
        if let name = state.displayed, let index = state.displayedIndex,
           let tabs = model.workspaces.first(where: { $0.name == name })?.tabs, tabs.indices.contains(index) {
            model.display(tabs[index].id)
        }
        if state.dashboard == true { model.dashboardOpen = true }
    }
}
