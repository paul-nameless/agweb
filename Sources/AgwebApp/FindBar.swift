import AppKit
import WebKit

/// ⌘F: a small blurred panel at the top right of the displayed tab, floating over the page so the page keeps its
/// size and an agent's coordinates stay right. Matching is plain and case-insensitive. Every match is highlighted
/// in one colour and the current one in another, as in Safari, through the CSS Custom Highlight API, which leaves
/// the page's DOM and selection alone. Only the person opens it; it closes, and its highlights go, when they close
/// it, the displayed tab changes or the dashboard opens.
final class FindBar: NSVisualEffectView, NSTextFieldDelegate {
    let field = NSTextField()
    private let count = NSTextField(labelWithString: "")
    private let webView: () -> WKWebView?
    private let close: () -> Void
    /// The page searched last, so its highlights can be cleared after the tab under the bar changed.
    private weak var searched: WKWebView?
    private static let world = WKContentWorld.world(name: "agweb-find")

    init(webView: @escaping () -> WKWebView?, close: @escaping () -> Void) {
        self.webView = webView
        self.close = close
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
        translatesAutoresizingMaskIntoConstraints = false

        field.placeholderString = "Find on page"
        field.delegate = self
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.widthAnchor.constraint(equalToConstant: 200).isActive = true
        count.textColor = .secondaryLabelColor
        count.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        count.setContentHuggingPriority(.required, for: .horizontal)
        func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
            b.isBordered = false
            b.toolTip = tip
            b.widthAnchor.constraint(equalToConstant: 22).isActive = true
            return b
        }
        let stack = NSStackView(views: [field, count, button("chevron.up", "Previous (⇧⌘G)", #selector(previous(_:))),
                                        button("chevron.down", "Next (⌘G)", #selector(next(_:))),
                                        button("xmark", "Close (Esc)", #selector(done(_:)))])
        stack.spacing = 4
        stack.setCustomSpacing(8, after: field)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc func next(_ sender: Any?) { run("step", 1) }
    @objc func previous(_ sender: Any?) { run("step", -1) }
    @objc private func done(_ sender: Any?) { close() }

    func controlTextDidChange(_ obj: Notification) { run("search", 0) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            run("step", NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? -1 : 1)
        case #selector(NSResponder.cancelOperation(_:)):
            close()
        default:
            return false
        }
        return true
    }

    /// Removes the highlights from the page searched last.
    func clear() {
        searched?.callAsyncJavaScript("window.__agwebFind?.clear(); return ''", arguments: [:], in: nil, in: Self.world)
    }

    private func run(_ op: String, _ step: Int) {
        let text = field.stringValue
        guard let webView = webView() else { return }
        if searched !== webView { clear() }
        searched = webView
        webView.callAsyncJavaScript(Self.script + "return F.run(op, text, step);", arguments: ["op": op, "text": text, "step": step],
                                    in: nil, in: Self.world) { [weak self] result in
            guard let self, self.field.stringValue == text else { return }
            let parts = ((try? result.get()) as? String ?? "").split(separator: "/").compactMap { Int($0) }
            guard parts.count == 2, !text.trimmingCharacters(in: .whitespaces).isEmpty else { self.count.stringValue = ""; return }
            let (index, total) = (parts[0], parts[1])
            self.count.stringValue = total == 0 ? "No matches" : "\(index + 1) of \(total)\(total >= Self.limit ? "+" : "")"
        }
    }

    private static let limit = 1000

    /// The page's visible text, whitespace collapsed and lowercased, mapped back to its text nodes, so a match can
    /// span inline elements ("foo <b>bar</b>"). A block boundary counts as a space. Same-origin frames are searched too.
    private static let script = #"""
    const F = window.__agwebFind || (window.__agwebFind = (() => {
      const LIMIT = 1000;
      const skip = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'TEXTAREA', 'HEAD', 'TITLE', 'SELECT', 'OPTION']);
      const docsOf = (doc) => [doc, ...[...doc.querySelectorAll('iframe, frame')].flatMap(f => {
        try { return f.contentDocument ? docsOf(f.contentDocument) : []; } catch { return []; }
      })];
      const css = '::highlight(agweb-find){background-color:rgba(255,214,0,.45);color:inherit}' +
        '::highlight(agweb-find-current){background-color:#ff9632;color:#000}';
      const S = { needle: null, matches: [], index: -1, docs: [] };
      const norm = (s) => s.replace(/\s+/g, ' ').toLowerCase();
      const clear = () => {
        for (const doc of S.docs) {
          try {
            doc.defaultView?.CSS.highlights.delete('agweb-find');
            doc.defaultView?.CSS.highlights.delete('agweb-find-current');
            doc.querySelector('style[data-agweb-find]')?.remove();
          } catch {}
        }
        Object.assign(S, { needle: null, matches: [], index: -1, docs: [] });
      };
      const collect = (doc, needle) => {
        const root = doc.body || doc.documentElement;
        if (!root) return [];
        const display = new Map();
        const inline = (el) => {
          if (!display.has(el)) display.set(el, (doc.defaultView.getComputedStyle(el).display || '').startsWith('inline'));
          return display.get(el);
        };
        const walker = doc.createTreeWalker(root, NodeFilter.SHOW_TEXT, { acceptNode: (n) => {
          const p = n.parentElement;
          if (!p || skip.has(p.tagName) || !n.data.length) return NodeFilter.FILTER_REJECT;
          return p.checkVisibility?.({ visibilityProperty: true }) === false ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT;
        } });
        // text[i] came from map[i] = [node, start, end] in the page.
        let text = '', space = true, prev = null;
        const map = [];
        for (let n = walker.nextNode(); n; n = walker.nextNode()) {
          if (prev && !space && (prev.parentElement !== n.parentElement && (!inline(prev.parentElement) || !inline(n.parentElement)))) {
            text += ' '; map.push([prev, prev.length, prev.length]); space = true;
          }
          const d = n.data;
          for (let i = 0; i < d.length; i++) {
            let c = d[i];
            if (/\s/.test(c)) { if (space) continue; c = ' '; space = true; } else space = false;
            const l = c.toLowerCase();
            text += l.length === 1 ? l : c;
            map.push([n, i, i + 1]);
          }
          prev = n;
        }
        const out = [];
        for (let i = text.indexOf(needle); i >= 0 && S.matches.length + out.length < LIMIT; i = text.indexOf(needle, i + needle.length)) {
          const r = doc.createRange();
          const a = map[i], b = map[i + needle.length - 1];
          r.setStart(a[0], a[1]);
          r.setEnd(b[0], b[2]);
          out.push(r);
        }
        return out;
      };
      const show = () => {
        for (const doc of S.docs) doc.defaultView?.CSS.highlights.delete('agweb-find-current');
        const r = S.matches[S.index];
        if (!r) return;
        const doc = r.startContainer.ownerDocument, view = doc.defaultView;
        const current = new view.Highlight(r);
        current.priority = 1;
        view.CSS.highlights.set('agweb-find-current', current);
        const rect = r.getBoundingClientRect();
        if (rect.top < 0 || rect.bottom > view.innerHeight || rect.left < 0 || rect.right > view.innerWidth) {
          r.startContainer.parentElement?.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'instant' });
        }
        const frame = view.frameElement;
        if (frame) {
          const fr = frame.getBoundingClientRect(), outer = frame.ownerDocument.defaultView;
          if (fr.top < 0 || fr.bottom > outer.innerHeight) frame.scrollIntoView({ block: 'center', behavior: 'instant' });
        }
      };
      const search = (text) => {
        clear();
        const needle = norm(text);
        S.needle = needle;
        if (!needle.trim()) return;
        S.docs = docsOf(document);
        for (const doc of S.docs) {
          const found = collect(doc, needle);
          if (!found.length) continue;
          const view = doc.defaultView;
          if (!doc.querySelector('style[data-agweb-find]')) {
            const style = doc.createElement('style');
            style.dataset.agwebFind = '';
            style.textContent = css;
            (doc.head || doc.documentElement).appendChild(style);
          }
          view.CSS.highlights.set('agweb-find', new view.Highlight(...found));
          S.matches.push(...found);
        }
        // The first match from the top of the view down, so typing keeps the reader's place.
        const below = S.matches.findIndex(r => {
          const rect = r.getBoundingClientRect();
          return rect.bottom >= 0 && (r.startContainer.ownerDocument === document || rect.top >= 0);
        });
        S.index = S.matches.length ? Math.max(below, 0) : -1;
        show();
      };
      return {
        clear,
        run(op, text, step) {
          // The page changed under the matches, or they are for other text: search afresh.
          const stale = S.needle !== norm(text) || S.matches.some(r => !r.startContainer.isConnected);
          if (op === 'search' || stale) search(text);
          else if (S.matches.length) { S.index = (S.index + step + S.matches.length) % S.matches.length; show(); }
          return `${S.index}/${S.matches.length}`;
        },
      };
    })());
    """#
}

extension MainWindow {
    @objc func showFind(_ sender: Any?) {
        guard model.displayedTab != nil, !model.dashboardOpen else { return NSSound.beep() }
        if findBar == nil {
            let bar = FindBar(webView: { [weak self] in self?.model.displayedTab?.webView }, close: { [weak self] in self?.closeFind() })
            container.addSubview(bar, positioned: .above, relativeTo: nil)
            NSLayoutConstraint.activate([
                bar.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 10),
                bar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
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
        bar.clear()
        bar.removeFromSuperview()
        findBar = nil
        if refocus, let webView = model.displayedTab?.webView { window.makeFirstResponder(webView) }
    }

    /// Called when the displayed tab or the dashboard changes.
    func closeFindIfStale() {
        if findBar != nil, model.dashboardOpen || model.displayedTabID != findTabID { closeFind(refocus: false) }
    }
}
