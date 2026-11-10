import AppKit
import SwiftUI

/// UserDefaults keys behind Settings (⌘,).
enum Settings {
    static let showUsage = "dashboardShowsUsage"
    /// 0 fits as many as the width allows.
    static let columns = "dashboardColumns"
}

struct SettingsView: View {
    @AppStorage(Settings.showUsage) private var showUsage = false
    @AppStorage(Settings.columns) private var columns = 0

    var body: some View {
        Form {
            Section("Dashboard") {
                Picker("Columns", selection: $columns) {
                    Text("Automatic").tag(0)
                    Divider()
                    // More than 6 makes tiles too small to read on a laptop screen.
                    ForEach(1...6, id: \.self) { Text("\($0)").tag($0) }
                }
                Toggle("Show CPU and memory", isOn: $showUsage)
                Text("Each page's process, and the total for agweb with its GPU and network processes, sampled every 2 s while the dashboard is open.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
}
