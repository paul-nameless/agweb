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
        scheduleSave()
        guard open else { return }
        dashboardTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled, let self {
                await self.refreshThumbnails()
                if Settings.store.bool(forKey: Settings.showUsage) {
                    if tick % 5 == 0 { self.model.processes = self.usageSampler.sample() }
                } else if !self.model.processes.isEmpty {
                    self.model.processes = [:]
                }
                tick += 1
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
        let shown = CommandLog.textCommands.contains(request.command)
            ? request.command + (request.command == "fill" || request.command == "select" ? request.args.first.map { " \($0)" } ?? "" : "")
            : ([request.command] + request.args.prefix(1)).joined(separator: " ")
        return String(shown.prefix(48))
    }
}

struct DashboardView: View {
    let model: BrowserModel
    /// The order while the pointer is over the grid, so a tile doesn't move away just as it is clicked.
    @State private var frozen: [Int]?
    @AppStorage(Settings.showUsage, store: Settings.store) private var showUsage = false
    @AppStorage(Settings.columns, store: Settings.store) private var columns = 0
    @AppStorage(Settings.textSize, store: Settings.store) private var textSize = TextSize.medium

    var body: some View {
        let recent = model.workspaces.flatMap(\.tabs).sorted { ($0.lastActivity, $1.id) > ($1.lastActivity, $0.id) }
        let place = Dictionary(uniqueKeysWithValues: (frozen ?? recent.map(\.id)).enumerated().map { ($1, $0) })
        // New tabs go last while frozen.
        let tabs = recent.sorted { (place[$0.id] ?? .max) < (place[$1.id] ?? .max) }
        let usage = showUsage ? model.processes : [:]
        let sharing = Dictionary(grouping: tabs.map(\.processID), by: { $0 }).mapValues(\.count)
        ScrollView {
            if tabs.isEmpty {
                Text("No tabs yet").foregroundStyle(.secondary).padding(40)
            }
            LazyVGrid(columns: grid, spacing: 18) {
                ForEach(tabs) { tab in
                    let pid = tab.processID
                    TabTile(tab: tab, displayed: model.displayedTabID == tab.id, usage: usage[pid]?.usage, shared: (sharing[pid] ?? 0) > 1,
                            scale: textSize.scale) {
                        model.onCloseTab?(tab)
                    }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.dashboardOpen = false
                            model.display(tab.id)
                        }
                }
            }
            .padding(16)
            // Room to scroll the last row out from under the total.
            .padding(.bottom, usage.isEmpty ? 0 : 32)
            .animation(.default, value: tabs.map(\.id))
        }
        .overlay(alignment: .bottomLeading) {
            if !usage.isEmpty { total(usage).padding(12) }
        }
        .onHover { inside in frozen = inside ? tabs.map(\.id) : nil }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var grid: [GridItem] {
        columns > 0 ? Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: columns)
            : [GridItem(.adaptive(minimum: 260, maximum: 520), spacing: 16, alignment: .top)]
    }

    /// Every process counted once, with the split by kind in the tooltip.
    private func total(_ usage: [pid_t: (name: String, usage: Usage)]) -> some View {
        func sum(_ list: some Sequence<(name: String, usage: Usage)>) -> Usage {
            list.reduce(Usage(cpu: 0, memory: 0)) { Usage(cpu: $0.cpu + $1.usage.cpu, memory: $0.memory + $1.usage.memory) }
        }
        let kinds: [(String, (String) -> Bool)] = [("Pages", { $0.contains("WebContent") }), ("GPU", { $0.contains("GPU") }),
                                                   ("Network", { $0.contains("Networking") }), ("App and other", { _ in true })]
        var left = Array(usage.values)
        let parts = kinds.map { kind, matches in
            let mine = left.filter { matches($0.name) }
            left.removeAll { matches($0.name) }
            return "\(kind): \(sum(mine).label)"
        }
        return Label("Total " + sum(usage.values).label, systemImage: "gauge.with.dots.needle.33percent")
            .font(.system(size: 11 * textSize.scale)).monospacedDigit().foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .help(parts.joined(separator: "\n"))
    }
}

private struct TabTile: View {
    let tab: Tab
    let displayed: Bool
    let usage: Usage?
    let shared: Bool
    /// The Settings text size; macOS text styles have fixed sizes, so these are the styles' sizes scaled.
    let scale: CGFloat
    let close: () -> Void

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
                        Image(systemName: "globe").font(.system(size: 26 * scale)).foregroundStyle(.tertiary).frame(maxHeight: .infinity)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(displayed ? Color.accentColor : Color(nsColor: .separatorColor),
                                                                        lineWidth: displayed ? 2 : 1))
                .overlay(alignment: .bottom) {
                    if let asking = tab.asking {
                        Label { Text(asking).lineLimit(2) } icon: { Image(systemName: "hand.raised.fill").foregroundStyle(.orange) }
                            .font(.system(size: 11 * scale))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.regularMaterial, in: Capsule()).padding(8)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if tab.state != "visible" {
                        Text(tab.state).font(.system(size: 10 * scale)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.regularMaterial, in: Capsule()).padding(6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: 10 * scale, weight: .semibold)).frame(width: 22, height: 22)
                            .background(.regularMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Close tab")
                    .padding(6)
                }
            HStack(spacing: 6) {
                Circle().fill(driven ? Color.green : Color.clear).frame(width: 6, height: 6)
                Text(tab.title.isEmpty ? (tab.url.isEmpty ? "New tab" : tab.url) : tab.title).lineLimit(1).truncationMode(.tail)
            }
            .font(.system(size: 13 * scale))
            HStack(spacing: 6) {
                Label(workspace.name, systemImage: "square.stack").lineLimit(1)
                if let profile = workspace.profile { Label(profile, systemImage: "person.crop.circle").lineLimit(1) }
                Spacer(minLength: 0)
                if workspace.busy { ProgressView().controlSize(.mini) }
            }
            .font(.system(size: 10 * scale)).foregroundStyle(.secondary)
            if let usage {
                Text(usage.label + (shared ? " · shared" : "")).font(.system(size: 10 * scale)).monospacedDigit().foregroundStyle(.secondary)
                    .help(shared ? "This page shares its process with another tab, so both show the same numbers" : "This page's process")
            }
            if driven, let last = workspace.lastCommand, let at = workspace.lastCommandAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("\(last) · \(Self.ago(at, context.date))").font(.system(size: 10 * scale)).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
    }

    private static func ago(_ date: Date, _ now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        return seconds < 60 ? "\(seconds) s ago" : seconds < 3600 ? "\(seconds / 60) min ago" : "\(seconds / 3600) h ago"
    }
}
