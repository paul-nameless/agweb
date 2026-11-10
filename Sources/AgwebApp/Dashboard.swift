import AgwebCore
import AppKit
import SwiftUI
import WebKit

// Every tab at once, in the window's content area: thumbnails, not live views. Live ones would all have to be
// visible (see Visibility.swift) and shrinking them would relayout the pages. A thumbnail is a small snapshot,
// which works on hidden tabs, refreshed about once a second for tabs an agent is working on.
extension Browser {
    func dashboardChanged(_ open: Bool) {
        dashboardTask?.cancel()
        mainWindow.showDashboard(open)
        updateVisibility()
        guard open else { return }
        // Fixed while it is open, so tiles don't jump around as agents work; new tabs go last.
        model.dashboardOrder = model.workspaces.flatMap(\.tabs).sorted { $0.lastActivity > $1.lastActivity }.map(\.id)
        dashboardTask = Task { [weak self] in
            while !Task.isCancelled, let self {
                await self.refreshThumbnails()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func refreshThumbnails() async {
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = 480
        for tab in model.workspaces.flatMap(\.tabs) where tab.pendingURL == nil && tab.webView.url != nil {
            // Idle tabs keep their picture: a snapshot of a suspended tab would wake its process.
            let active = tab.workspace.busy || tab.awakeUntil > Date() || model.displayedTabID == tab.id
            guard active || tab.thumbnail == nil else { continue }
            if let image = try? await tab.snapshot(config, timeout: 3) { tab.thumbnail = image }
        }
    }

    /// What a dashboard tile says the agent did last; never the text it typed, filled or evaluated.
    static func summary(_ request: Request) -> String {
        let shown = ["type", "eval", "fill", "select", "dialog-accept", "cookie-set", "state-load", "route"].contains(request.command)
            ? request.command + (request.command == "fill" || request.command == "select" ? request.args.first.map { " \($0)" } ?? "" : "")
            : ([request.command] + request.args.prefix(1)).joined(separator: " ")
        return String(shown.prefix(48))
    }
}

struct DashboardView: View {
    let model: BrowserModel

    var body: some View {
        let order = Dictionary(uniqueKeysWithValues: model.dashboardOrder.enumerated().map { ($1, $0) })
        let tabs = model.workspaces.flatMap(\.tabs).sorted { (order[$0.id] ?? .max, $0.id) < (order[$1.id] ?? .max, $1.id) }
        ScrollView {
            if tabs.isEmpty {
                Text("No tabs yet").foregroundStyle(.secondary).padding(40)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 520), spacing: 16, alignment: .top)], spacing: 18) {
                ForEach(tabs) { tab in
                    TabTile(tab: tab, displayed: model.displayedTabID == tab.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.dashboardOpen = false
                            model.display(tab.id)
                        }
                }
            }
            .padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct TabTile: View {
    let tab: Tab
    let displayed: Bool

    var body: some View {
        let workspace = tab.workspace
        let driven = workspace.currentID == tab.id
        VStack(alignment: .leading, spacing: 6) {
            Color(nsColor: .textBackgroundColor)
                .aspectRatio(16 / 10, contentMode: .fit)
                .overlay(alignment: .top) {
                    if let image = tab.thumbnail {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "globe").font(.largeTitle).foregroundStyle(.tertiary).frame(maxHeight: .infinity)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(displayed ? Color.accentColor : Color(nsColor: .separatorColor),
                                                                        lineWidth: displayed ? 2 : 1))
                .overlay(alignment: .topTrailing) {
                    if tab.state != "visible" {
                        Text(tab.state).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.regularMaterial, in: Capsule()).padding(6)
                    }
                }
            HStack(spacing: 6) {
                Circle().fill(driven ? Color.green : Color.clear).frame(width: 6, height: 6)
                Text(tab.title.isEmpty ? (tab.url.isEmpty ? "New tab" : tab.url) : tab.title).lineLimit(1).truncationMode(.tail)
            }
            HStack(spacing: 6) {
                Label(workspace.name, systemImage: "square.stack").lineLimit(1)
                if let profile = workspace.profile { Label(profile, systemImage: "person.crop.circle").lineLimit(1) }
                Spacer(minLength: 0)
                if workspace.busy { ProgressView().controlSize(.mini) }
            }
            .font(.caption).foregroundStyle(.secondary)
            if driven, let last = workspace.lastCommand, let at = workspace.lastCommandAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("\(last) · \(Self.ago(at, context.date))").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
    }

    private static func ago(_ date: Date, _ now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        return seconds < 60 ? "\(seconds) s ago" : seconds < 3600 ? "\(seconds / 60) min ago" : "\(seconds / 3600) h ago"
    }
}
