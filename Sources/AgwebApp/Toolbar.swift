import AppKit
import Observation

/// Back, forward and reload on the left, the address field centered, new tab on the right; all act on the
/// displayed tab.
extension MainWindow: NSToolbarDelegate, NSTextFieldDelegate, NSToolbarItemValidation {
    private static let back = NSToolbarItem.Identifier("back")
    private static let forward = NSToolbarItem.Identifier("forward")
    private static let reload = NSToolbarItem.Identifier("reload")
    private static let address = NSToolbarItem.Identifier("address")
    private static let newTabItem = NSToolbarItem.Identifier("newTab")

    func installToolbar() {
        urlField.placeholderString = "Enter address"
        urlField.lineBreakMode = .byTruncatingTail
        urlField.usesSingleLineMode = true
        urlField.cell?.isScrollable = true
        urlField.bezelStyle = .roundedBezel
        urlField.alignment = .center
        urlField.delegate = self
        let toolbar = NSToolbar(identifier: "main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.centeredItemIdentifiers = [Self.address]
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        trackDisplayedURL()
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, Self.back, Self.forward, Self.reload,
         .flexibleSpace, Self.address, .flexibleSpace, Self.newTabItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case Self.address:
            item.view = urlField
            item.label = "Address"
            urlField.widthAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true
            urlField.widthAnchor.constraint(lessThanOrEqualToConstant: 720).isActive = true
            return item
        case Self.back: configure(item, "Back", "chevron.left", #selector(goBack(_:)))
        case Self.forward: configure(item, "Forward", "chevron.right", #selector(goForward(_:)))
        case Self.reload: configure(item, "Reload", "arrow.clockwise", #selector(reloadPage(_:)))
        case Self.newTabItem: configure(item, "New Tab", "plus", #selector(newTab(_:)))
        default: return nil
        }
        return item
    }

    private func configure(_ item: NSToolbarItem, _ label: String, _ symbol: String, _ action: Selector) {
        item.label = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.target = self
        item.action = action
        // Bordered items get their own bezel and the standard gap between neighbours.
        item.isBordered = true
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        if item.itemIdentifier == Self.newTabItem { return true }
        guard let webView = model.displayedTab?.webView else { return false }
        switch item.itemIdentifier {
        case Self.back: return webView.canGoBack
        case Self.forward: return webView.canGoForward
        default: return true
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            guard let tab = model.displayedTab, let url = try? Browser.url(urlField.stringValue) else { return true }
            if url.isFileURL {
                tab.webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            } else {
                tab.webView.load(URLRequest(url: url))
            }
            window.makeFirstResponder(tab.webView)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            urlField.stringValue = model.displayedTab?.url ?? ""
            window.makeFirstResponder(model.displayedTab?.webView)
            return true
        default:
            return false
        }
    }

    /// Mirrors the displayed tab's URL into the field, except while the user is typing in it.
    private func trackDisplayedURL() {
        let url = withObservationTracking {
            model.displayedTab?.url
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.trackDisplayedURL() }
        }
        if urlField.currentEditor() == nil { urlField.stringValue = url ?? "" }
        urlField.isEnabled = model.displayedTab != nil
    }
}
