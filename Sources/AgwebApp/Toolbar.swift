import AgwebCore
import AppKit
import Observation
import SwiftUI

/// Back, forward and reload on the left, the address field centered, new tab on the right; all act on the
/// displayed tab. The dashboard swaps them for its CPU and memory total, keeping new tab.
extension MainWindow: NSToolbarDelegate, NSTextFieldDelegate, NSToolbarItemValidation {
    private static let back = NSToolbarItem.Identifier("back")
    private static let forward = NSToolbarItem.Identifier("forward")
    private static let reload = NSToolbarItem.Identifier("reload")
    private static let address = NSToolbarItem.Identifier("address")
    private static let newTabItem = NSToolbarItem.Identifier("newTab")
    private static let dashboardItem = NSToolbarItem.Identifier("dashboard")
    private static let usage = NSToolbarItem.Identifier("usage")
    private static let find = NSToolbarItem.Identifier("find")

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
        toolbar.centeredItemIdentifiers = [Self.address, Self.usage]
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        trackDisplayedURL()
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, Self.dashboardItem, .sidebarTrackingSeparator, Self.back, Self.forward, Self.reload,
         .flexibleSpace, Self.address, Self.usage, Self.find, .flexibleSpace, Self.newTabItem]
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
            urlMinWidth = urlField.widthAnchor.constraint(greaterThanOrEqualToConstant: 420)
            urlMinWidth?.isActive = true
            urlField.widthAnchor.constraint(lessThanOrEqualToConstant: 720).isActive = true
            return item
        case Self.usage:
            let total = NSHostingView(rootView: UsageTotal(model: model))
            total.sizingOptions = .intrinsicContentSize
            item.view = total
            item.label = "CPU and Memory"
            item.isHidden = !model.dashboardOpen
            return item
        case Self.find:
            item.view = findBar
            item.label = "Find"
            item.isHidden = !findOpen
            return item
        case Self.back: configure(item, "Back", "chevron.left", #selector(goBack(_:)))
        case Self.forward: configure(item, "Forward", "chevron.right", #selector(goForward(_:)))
        case Self.reload: configure(item, "Reload", "arrow.clockwise", #selector(reloadPage(_:)))
        case Self.newTabItem: configure(item, "New Tab", "plus", #selector(newTab(_:)))
        case Self.dashboardItem:
            // A push-on/push-off button shows the dashboard's state; a plain toolbar item can't.
            dashboardButton.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Dashboard")
            dashboardButton.bezelStyle = .toolbar
            dashboardButton.setButtonType(.pushOnPushOff)
            dashboardButton.target = self
            dashboardButton.action = #selector(toggleDashboard(_:))
            dashboardButton.toolTip = "Dashboard (⌘D)"
            item.view = dashboardButton
            item.label = "Dashboard"
        default: return nil
        }
        return item
    }

    /// ⌘F shows the find field beside the address, which narrows to make room.
    func updateFindItem() {
        urlMinWidth?.constant = findOpen ? 240 : 420
        for item in window.toolbar?.items ?? [] where item.itemIdentifier == Self.find { item.isHidden = !findOpen }
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
        if item.itemIdentifier == Self.newTabItem || item.itemIdentifier == Self.dashboardItem { return true }
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
            guard let tab = model.displayedTab, let url = Address.typed(urlField.stringValue) else { return true }
            Task { await tab.load(url) }
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

    /// Mirrors the displayed tab's URL into the field, except while the user is typing in it. The dashboard shows
    /// no single tab, so it hides the address and the page buttons.
    private func trackDisplayedURL() {
        let (url, dashboard) = withObservationTracking {
            (model.displayedTab?.url, model.dashboardOpen)
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.trackDisplayedURL() }
        }
        if urlField.currentEditor() == nil { urlField.stringValue = url ?? "" }
        urlField.isEnabled = model.displayedTab != nil
        for item in window.toolbar?.items ?? [] where [Self.back, Self.forward, Self.reload, Self.address].contains(item.itemIdentifier) {
            item.isHidden = dashboard
        }
        for item in window.toolbar?.items ?? [] where item.itemIdentifier == Self.usage { item.isHidden = !dashboard }
        closeFindIfStale()
    }
}
