import AppKit
import WebKit

/// ⌘F: a bar over the top of the displayed tab, as in Safari. It floats over the page rather than pushing it down,
/// so the page keeps its size and an agent's coordinates stay right. Plain, case-insensitive matching through
/// WebKit's own find, which selects each match and scrolls to it. Only the person opens it; it closes when the
/// displayed tab changes or the dashboard opens.
final class FindBar: NSVisualEffectView, NSTextFieldDelegate {
    let field = NSTextField()
    private let count = NSTextField(labelWithString: "")
    private let webView: () -> WKWebView?
    private let close: () -> Void

    init(webView: @escaping () -> WKWebView?, close: @escaping () -> Void) {
        self.webView = webView
        self.close = close
        super.init(frame: .zero)
        material = .headerView
        blendingMode = .withinWindow
        translatesAutoresizingMaskIntoConstraints = false

        field.placeholderString = "Find on page"
        field.delegate = self
        field.bezelStyle = .roundedBezel
        field.widthAnchor.constraint(equalToConstant: 260).isActive = true
        count.textColor = .secondaryLabelColor
        count.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
            b.bezelStyle = .accessoryBarAction
            b.toolTip = tip
            return b
        }
        let done = NSButton(title: "Done", target: self, action: #selector(done(_:)))
        done.bezelStyle = .accessoryBarAction
        let stack = NSStackView(views: [count, field, button("chevron.up", "Previous (⇧⌘G)", #selector(previous(_:))),
                                        button("chevron.down", "Next (⌘G)", #selector(next(_:))), done])
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        addSubview(line)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 36),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 10),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc func next(_ sender: Any?) { find(backwards: false) }
    @objc func previous(_ sender: Any?) { find(backwards: true) }
    @objc private func done(_ sender: Any?) { close() }

    /// Typing searches again from the current match's start, so "ab" after "a" stays on the same spot.
    func controlTextDidChange(_ obj: Notification) {
        guard let webView = webView() else { return }
        webView.evaluateJavaScript("getSelection().rangeCount && getSelection().collapseToStart()", in: nil, in: .defaultClient) { [weak self] _ in
            self?.find(backwards: false)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            find(backwards: NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false)
        case #selector(NSResponder.cancelOperation(_:)):
            close()
        default:
            return false
        }
        return true
    }

    private func find(backwards: Bool) {
        let text = field.stringValue
        guard let webView = webView(), !text.isEmpty else { count.stringValue = ""; return }
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.caseSensitive = false
        config.wraps = true
        webView.find(text, configuration: config) { [weak self] result in
            guard let self, self.field.stringValue == text else { return }
            guard result.matchFound else { self.count.stringValue = "No matches"; return }
            self.countMatches(text, in: webView)
        }
    }

    /// WebKit's public find doesn't count, so the page's visible text is counted, same-origin frames included.
    private func countMatches(_ text: String, in webView: WKWebView) {
        let script = """
        const texts = (doc) => [doc.body?.innerText ?? '', ...[...doc.querySelectorAll('iframe, frame')].flatMap(f => {
          try { return f.contentDocument ? texts(f.contentDocument) : []; } catch { return []; }
        })];
        const needle = text.toLocaleLowerCase();
        let n = 0;
        for (const t of texts(document)) for (let i = t.toLocaleLowerCase().indexOf(needle); i >= 0; i = t.toLocaleLowerCase().indexOf(needle, i + needle.length)) n++;
        return n;
        """
        webView.callAsyncJavaScript(script, arguments: ["text": text], in: nil, in: .defaultClient) { [weak self] result in
            guard let self, self.field.stringValue == text, case .success(let value) = result, let n = value as? Int else { return }
            self.count.stringValue = n == 1 ? "1 match" : "\(max(n, 1)) matches"
        }
    }
}

extension MainWindow {
    @objc func showFind(_ sender: Any?) {
        guard model.displayedTab != nil, !model.dashboardOpen else { return NSSound.beep() }
        if findBar == nil {
            let bar = FindBar(webView: { [weak self] in self?.model.displayedTab?.webView }, close: { [weak self] in self?.closeFind() })
            container.addSubview(bar, positioned: .above, relativeTo: nil)
            NSLayoutConstraint.activate([
                bar.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
                bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
            findBar = bar
            findTabID = model.displayedTabID
        }
        window.makeFirstResponder(findBar?.field)
        findBar?.field.selectText(nil)
    }

    @objc func findNext(_ sender: Any?) { findBar == nil ? showFind(sender) : findBar?.next(sender) }
    @objc func findPrevious(_ sender: Any?) { findBar == nil ? showFind(sender) : findBar?.previous(sender) }

    /// Typing goes back to the page only when the person closed the bar.
    func closeFind(refocus: Bool = true) {
        guard let bar = findBar else { return }
        bar.removeFromSuperview()
        findBar = nil
        if refocus, let webView = model.displayedTab?.webView { window.makeFirstResponder(webView) }
    }

    /// Called when the displayed tab or the dashboard changes.
    func closeFindIfStale() {
        if findBar != nil, model.dashboardOpen || model.displayedTabID != findTabID { closeFind(refocus: false) }
    }
}
