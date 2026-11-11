import AgwebCore
import AppKit
import SwiftUI

/// UserDefaults keys behind Settings (⌘,).
enum Settings {
    /// An instance on its own root (the selftest, a test build) keeps its own settings and window frame, so a test
    /// never changes or deletes the person's.
    static let store: UserDefaults = {
        let store = Agweb.isDefaultRoot ? .standard : UserDefaults(suiteName: Agweb.settingsSuite(root: Agweb.root))!
        store.register(defaults: [showUsage: true])
        return store
    }()
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
    @AppStorage(Settings.showUsage, store: Settings.store) private var showUsage = true
    @AppStorage(Settings.columns, store: Settings.store) private var columns = 0
    @AppStorage(Settings.textSize, store: Settings.store) private var textSize = TextSize.medium
    @State private var skill: [String] = []
    @State private var cli = ""

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
            Section("Command line tool") {
                Text(cli)
                Button("Install") { CLIInstaller.runWithAlert(); cli = CLIInstaller.status }
                Text("Links agweb into /usr/local/bin, so every terminal and agent can run it, and it updates with the app. Asks for an administrator password if that folder isn't writable.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Agent skill") {
                ForEach(skill, id: \.self) { Text($0) }
                Button("Install for Claude Code and Codex") { skill = SkillInstaller.install() }
                Text("Links ~/.claude/skills/agweb and ~/.codex/skills/agweb to the skill inside the app, so agents learn the agweb command and the skill updates with the app. A skill of your own there is left alone.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            cli = CLIInstaller.status
            skill = SkillInstaller.agents.map { "\($0.name): \(SkillInstaller.status($0.folder))" }
        }
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

    @objc func installCLI(_ sender: Any?) { CLIInstaller.runWithAlert() }

    /// Help ▸ Install Agent Skill.
    @objc func installSkill(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Agent Skill"
        alert.informativeText = SkillInstaller.install().joined(separator: "\n")
        alert.runModal()
    }
}
