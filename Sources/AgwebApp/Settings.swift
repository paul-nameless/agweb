import AgwebCore
import AppKit
import LocalAuthentication
import SwiftUI

/// UserDefaults keys behind Settings (⌘,).
enum Settings {
    /// An instance on its own root (the selftest, a test build) keeps its own settings and window frame, so a test
    /// never changes or deletes the person's.
    static let store: UserDefaults = {
        let store = Agweb.isDefaultRoot ? .standard : UserDefaults(suiteName: Agweb.settingsSuite(root: Agweb.root))!
        store.register(defaults: [showUsage: true, adBlock: true, passkeys: true, closeUnusedDays: 7, unloadIdleMinutes: 30])
        return store
    }()
    static let showUsage = "dashboardShowsUsage"
    /// 0 fits as many as the width allows.
    static let columns = "dashboardColumns"
    static let textSize = "textSize"
    static let adBlock = "blockAds"
    static let passkeys = "agwebPasskeys"
    /// Named profiles whose passkey requests may use a security key (Passkeys.usesKey); only the person sets them.
    static let securityKeyProfiles = "agwebSecurityKeyProfiles"
    /// Every workspace's, fresh ones included.
    static let securityKeyAll = "agwebSecurityKeyAll"
    /// Workspaces and tabs unused this many days close by themselves (Cleanup.swift); 0 never.
    static let closeUnusedDays = "closeUnusedDays"
    /// Tabs unused this many minutes lose their page's memory and reload when used (Unload.swift); 0 never.
    static let unloadIdleMinutes = "unloadIdleMinutes"
}

/// The sidebar's and the dashboard's text; pages have their own zoom (⌘+, ⌘−).
enum TextSize: Int, CaseIterable {
    case small, medium, large

    var title: String { ["Small", "Medium", "Large"][rawValue] }
    var sidebarRows: SidebarRowSize { [.small, .medium, .large][rawValue] }
    /// For the dashboard, whose text styles macOS doesn't scale.
    var scale: CGFloat { [0.9, 1, 1.25][rawValue] }
}

/// Agweb's passkeys, one section per profile (and one per fresh workspace holding in-memory passkeys). Anyone sees
/// sites and users (as `agweb passkey list` does); deleting waits for the Mac owner's check.
struct PasskeySettings: View {
    @AppStorage(Settings.passkeys, store: Settings.store) private var enabled = true
    @AppStorage(Settings.securityKeyAll, store: Settings.store) private var keyEverywhere = false
    private let passkeys = Passkeys.shared
    @State private var deleting: PasskeyEntry?
    @State private var problem: String?

    var body: some View {
        let _ = passkeys.revision
        let keys = passkeys.entries()
        let groups = Set(keys.map(\.group) + Profiles.names.map { "profile \($0)" }).sorted()
        Form {
            Section {
                Toggle("Answer passkey requests with Agweb's passkeys", isOn: $enabled)
                    .onChange(of: enabled) { passkeys.settingChanged() }
            } footer: {
                Text("Each profile's passkeys. Agents sign up and sign in with them with no prompt; they delete only what an agent made. "
                     + (passkeys.store is KeychainPasskeyStore ? "Kept in your login Keychain." : "This instance runs on its own folder and keeps them in a file there."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Use a security key plugged into this Mac", isOn: $keyEverywhere)
                    .onChange(of: keyEverywhere) { passkeys.keySettingChanged() }
            } header: { Text("Security keys") } footer: {
                Text("For every workspace, or one profile below. You type the PIN and touch the key in the tab; agents never see the PIN. "
                     + "Log: \(KeyLog.file.path)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!enabled)
            if groups.isEmpty {
                Section { Text("None yet. Profiles appear here once a workspace is opened with -p NAME.").foregroundStyle(.secondary) }
            }
            ForEach(groups, id: \.self) { group in
                let rows = keys.filter { $0.group == group }
                Section(group.prefix(1).uppercased() + group.dropFirst()) {
                    if group.hasPrefix("profile ") {
                        let owner = PasskeyOwner.profile(String(group.dropFirst("profile ".count)))
                        Toggle("Use a security key plugged into this Mac", isOn: Binding(get: { passkeys.usesKey(owner) }, set: { passkeys.setUsesKey($0, owner) }))
                            .disabled(keyEverywhere || !enabled)
                    }
                    if rows.isEmpty { Text("No passkeys").foregroundStyle(.secondary) }
                    ForEach(rows) { entry in row(entry) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 600, height: 600)
        .confirmationDialog("Delete the passkey for \(deleting?.passkey.label ?? "")?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let deleting { delete(deleting) }
                deleting = nil
            }
        } message: { Text("Agweb can no longer sign in with it. The site still lists it until you remove it in the account's settings there.") }
        .alert("Passkeys", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {} message: { Text(problem ?? "") }
    }

    private func row(_ entry: PasskeyEntry) -> some View {
        let date = Date.FormatStyle(date: .abbreviated, time: .omitted)
        let user = entry.passkey.userName.isEmpty ? entry.passkey.displayName : entry.passkey.userName
        return HStack(alignment: .firstTextBaseline) {
            Image(systemName: "person.badge.key").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.passkey.rpID)
                Text([user, entry.passkey.byPerson == false ? "made by an agent" : "",
                      entry.passkey.lastUsed.map { "used \($0.formatted(date))" } ?? "created \(entry.passkey.created.formatted(date))"]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { deleting = entry } label: { Image(systemName: "trash") }.help("Delete this passkey")
        }
        .buttonStyle(.borderless)
    }

    /// After the Mac owner's check (Touch ID or the login password).
    private func delete(_ entry: PasskeyEntry) {
        Task {
            guard (try? await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "delete a passkey")) == true else { return }
            do { try entry.delete() } catch { problem = "\(error)" }
        }
    }
}

/// The command line tool and the agent skill.
struct GeneralSettings: View {
    @AppStorage(Settings.closeUnusedDays, store: Settings.store) private var closeUnused = 7
    @AppStorage(Settings.unloadIdleMinutes, store: Settings.store) private var unloadIdle = 30
    @State private var skill: [String] = []
    @State private var cli = ""

    var body: some View {
        Form {
            Section("Command line tool") {
                LabeledContent(cli) {
                    Button("Install") { CLIInstaller.runWithAlert(); cli = CLIInstaller.status }
                }
                Text("Links agweb into /usr/local/bin.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Agent skill") {
                ForEach(skill, id: \.self) { Text($0) }
                Button("Install for Claude Code and Codex") { skill = SkillInstaller.install() }
            }
            Section("Workspaces") {
                Picker("Close unused workspaces and tabs after", selection: $closeUnused) {
                    Text("1 day").tag(1)
                    Text("3 days").tag(3)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("Never").tag(0)
                }
                Text("Only time agweb is running counts. Your own workspaces and what an agent is working on stay.").font(.caption).foregroundStyle(.secondary)
                Picker("Unload unused tabs after", selection: $unloadIdle) {
                    Text("10 minutes").tag(10)
                    Text("30 minutes").tag(30)
                    Text("2 hours").tag(120)
                    Text("Never").tag(0)
                }
                Text("Frees the tab's memory; it reloads when used, losing typed text and scroll position. Sooner when the Mac is short on memory. Never the tab shown, nor one playing sound you can hear.").font(.caption).foregroundStyle(.secondary)
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

/// Text size, the dashboard and ad blocking.
struct AppearanceSettings: View {
    @AppStorage(Settings.showUsage, store: Settings.store) private var showUsage = true
    @AppStorage(Settings.columns, store: Settings.store) private var columns = 0
    @AppStorage(Settings.textSize, store: Settings.store) private var textSize = TextSize.medium
    @AppStorage(Settings.adBlock, store: Settings.store) private var adBlock = true
    @State private var adBlockStatus = ""

    var body: some View {
        Form {
            Section("Text") {
                Picker("Text size", selection: $textSize) {
                    ForEach(TextSize.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text("Sidebar and dashboard. ⌘+ and ⌘− zoom a page.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Dashboard") {
                Picker("Columns", selection: $columns) {
                    Text("Automatic").tag(0)
                    Divider()
                    // More than 6 makes tiles too small to read on a laptop screen.
                    ForEach(1...6, id: \.self) { Text("\($0)").tag($0) }
                }
                Toggle("Show CPU and memory", isOn: $showUsage)
            }
            Section("Ads and trackers") {
                Toggle("Block ads and trackers", isOn: $adBlock)
                    .onChange(of: adBlock) { AdBlock.shared.settingChanged(); adBlockStatus = AdBlock.shared.summary }
                LabeledContent(adBlockStatus) {
                    Button("Update") {
                        let task = AdBlock.shared.update(force: true)
                        adBlockStatus = AdBlock.shared.summary
                        Task { await task.value; adBlockStatus = AdBlock.shared.summary }
                    }
                    .disabled(!adBlock)
                }
                Text("uBlock Origin's lists. Agents can turn it off for their own workspace.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { adBlockStatus = AdBlock.shared.summary }
        .frame(width: 440)
        .fixedSize()
    }
}

@MainActor
final class SettingsWindow: NSObject {
    /// Toolbar tabs, as in every macOS app's Settings; the window takes each tab's size and title.
    private lazy var window: NSWindow = {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        for (title, symbol, view) in [("General", "gearshape", AnyView(GeneralSettings())), ("Appearance", "paintbrush", AnyView(AppearanceSettings())),
                                     ("Passkeys", "person.badge.key", AnyView(PasskeySettings()))] {
            let host = NSHostingController(rootView: view)
            host.sizingOptions = .preferredContentSize
            // The tab controller gives the window the selected tab's view controller title; without one it's "Untitled".
            host.title = title
            let item = NSTabViewItem(viewController: host)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.title = "General"
        window.toolbarStyle = .preference
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
