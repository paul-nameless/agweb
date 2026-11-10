import AppKit
import AgwebCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let browser = Browser()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let path = Agweb.socketPath
        // Held until exit. Two launches racing for one socket: the loser leaves before showing anything.
        guard Agweb.lockOwnership(of: path) != nil else {
            FileHandle.standardError.write(Data("agweb is already running for \(path)\n".utf8))
            exit(0)
        }
        let browser = browser
        browser.restoreWorkspaces()
        do {
            try serve(path: path) { request in await browser.handle(request) }
        } catch {
            FileHandle.standardError.write(Data("cannot listen on \(path): \(error)\n".utf8))
            exit(1)
        }
        NSApp.mainMenu = makeMainMenu(target: browser.mainWindow)
        browser.mainWindow.showQuietly()
    }

    // A Dock click activates the app first, then reopens. `open -a` on a running app (a second CLI racing the
    // first launch) reopens without activating, and must not bring the window forward.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if NSApp.isActive { browser.mainWindow.window.makeKeyAndOrderFront(nil) }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// ⌘Q and logout prepare here; the quit command prepares before it terminates.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if browser.preparedToQuit { return .terminateNow }
        Task {
            _ = await browser.prepareToQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        unlink(Agweb.socketPath)
    }
}

@MainActor
private func makeMainMenu(target: MainWindow) -> NSMenu {
    let main = NSMenu()
    func submenu(_ title: String, _ items: [NSMenuItem]) {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        main.addItem(item)
    }
    func item(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command,
              to receiver: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = receiver
        return item
    }

    submenu("Agweb", [
        item("Hide Agweb", #selector(NSApplication.hide(_:)), "h"),
        item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
        .separator(),
        item("Quit Agweb", #selector(NSApplication.terminate(_:)), "q"),
    ])
    submenu("File", [
        item("New Tab", #selector(MainWindow.newTab(_:)), "t", to: target),
        item("Open Location…", #selector(MainWindow.openLocation(_:)), "l", to: target),
        .separator(),
        item("Close Tab", #selector(MainWindow.closeTab(_:)), "w", to: target),
    ])
    // Nil targets: these travel the responder chain to the address field or the page.
    submenu("Edit", [
        item("Undo", Selector(("undo:")), "z"),
        item("Redo", Selector(("redo:")), "z", [.command, .shift]),
        .separator(),
        item("Cut", #selector(NSText.cut(_:)), "x"),
        item("Copy", #selector(NSText.copy(_:)), "c"),
        item("Paste", #selector(NSText.paste(_:)), "v"),
        item("Select All", #selector(NSText.selectAll(_:)), "a"),
    ])
    submenu("View", [
        item("Reload Page", #selector(MainWindow.reloadPage(_:)), "r", to: target),
        item("Back", #selector(MainWindow.goBack(_:)), "[", to: target),
        item("Forward", #selector(MainWindow.goForward(_:)), "]", to: target),
    ])
    submenu("Window", [
        item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
        item("Show Browser", #selector(NSWindow.makeKeyAndOrderFront(_:)), "0", to: target.window),
    ])
    return main
}

signal(SIGPIPE, SIG_IGN)
// WebKit reads these before the first web view, falling back to the system's text settings, which turn an agent's
// "--verbose" into "—verbose", straighten or curl its quotes and autocorrect its words.
for key in ["WebAutomaticDashSubstitutionEnabled", "WebAutomaticQuoteSubstitutionEnabled", "WebAutomaticTextReplacementEnabled",
            "WebAutomaticSpellingCorrectionEnabled"] {
    UserDefaults.standard.set(false, forKey: key)
}
let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
