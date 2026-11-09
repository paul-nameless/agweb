import AppKit
import WKBCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let browser = Browser()
    private var server: SocketServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let path = WKB.socketPath
        if isServing(path) {
            FileHandle.standardError.write(Data("WKBrowser is already serving \(path)\n".utf8))
            exit(0)
        }
        let browser = browser
        server = SocketServer(path: path) { request in await browser.handle(request) }
        do {
            try server?.start()
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

    func applicationWillTerminate(_ notification: Notification) {
        unlink(WKB.socketPath)
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

    submenu("WKBrowser", [
        item("Hide WKBrowser", #selector(NSApplication.hide(_:)), "h"),
        item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
        .separator(),
        item("Quit WKBrowser", #selector(NSApplication.terminate(_:)), "q"),
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
let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
