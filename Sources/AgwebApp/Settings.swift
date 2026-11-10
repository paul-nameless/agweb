import AgwebCore
import AppKit
import SwiftUI

/// UserDefaults keys behind Settings (⌘,).
enum Settings {
    /// An instance on its own socket (the selftest, a test build) keeps its own settings, so a test never
    /// changes or deletes the person's.
    static let store = Agweb.customSocket ? UserDefaults(suiteName: Agweb.bundleIdentifier + ".test")! : .standard
    static let showUsage = "dashboardShowsUsage"
    /// 0 fits as many as the width allows.
    static let columns = "dashboardColumns"
    static let textSize = "textSize"
}

/// The sidebar's and the dashboard's text; pages have their own zoom (⌘+, ⌘−).
enum TextSize: Int, CaseIterable {
    case small, medium, large

    var title: String { ["Small", "Medium", "Large"][rawValue] }
    var sidebarRows: SidebarRowSize { [.small, .medium, .large][rawValue] }
    /// For the dashboard, whose text styles macOS doesn't scale.
    var scale: CGFloat { [0.9, 1, 1.25][rawValue] }
}

struct SettingsView: View {
    @AppStorage(Settings.showUsage, store: Settings.store) private var showUsage = false
    @AppStorage(Settings.columns, store: Settings.store) private var columns = 0
    @AppStorage(Settings.textSize, store: Settings.store) private var textSize = TextSize.medium
    @State private var skill: [String] = []

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Text size", selection: $textSize) {
                    ForEach(TextSize.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text("Sidebar and dashboard. Zoom a page with ⌘+ and ⌘−.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Dashboard") {
                Picker("Columns", selection: $columns) {
                    Text("Automatic").tag(0)
                    Divider()
                    // More than 6 makes tiles too small to read on a laptop screen.
                    ForEach(1...6, id: \.self) { Text("\($0)").tag($0) }
                }
                Toggle("Show CPU and memory", isOn: $showUsage)
                Text("Each page's process, and the total for agweb with its GPU and network processes, sampled every 5 s while the dashboard is open.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Agent skill") {
                ForEach(skill, id: \.self) { Text($0) }
                Button("Install for Claude Code and Codex") { skill = SkillInstaller.install() }
                Text("Teaches agents to use the agweb command. A copy agweb installed is updated when agweb updates.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { skill = SkillInstaller.agents.map { "\($0.name): \(SkillInstaller.status($0.folder).rawValue)" } }
        .frame(width: 440)
        .fixedSize()
    }
}

@MainActor
final class SettingsWindow: NSObject {
    private lazy var window: NSWindow = {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
        window.title = "Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }()

    @objc func show(_ sender: Any?) { window.makeKeyAndOrderFront(nil) }

    /// Help ▸ Install Agent Skill.
    @objc func installSkill(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Agent Skill"
        alert.informativeText = SkillInstaller.install().joined(separator: "\n")
        alert.runModal()
    }
}
