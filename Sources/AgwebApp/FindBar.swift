import AppKit
import WebKit

/// ⌘F: a small blurred panel at the top right of the displayed tab, floating over the page so the page keeps its
/// size and an agent's coordinates stay right. Matching is plain and case-insensitive. Every match is highlighted
/// in one colour and the current one in another, as in Safari, through the CSS Custom Highlight API, which leaves
/// the page's DOM and selection alone. Only the person opens it; it closes, and its highlights go, when they close
/// it, the displayed tab changes or the dashboard opens.
final class FindBar: NSView, NSTextFieldDelegate {
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

        field.placeholderString = "Find on page"
        field.delegate = self
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.widthAnchor.constraint(equalToConstant: 170).isActive = true
        count.textColor = .secondaryLabelColor
        count.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        count.alignment = .right
        // A fixed width, so "No matches" or "12 of 340" don't resize the toolbar item as they change.
        let widest = ("1000 of 1000+" as NSString).size(withAttributes: [.font: count.font!]).width
        count.widthAnchor.constraint(equalToConstant: ceil(widest) + 4).isActive = true
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
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc func next(_ sender: Any?) { run("step", 1) }
    @objc func previous(_ sender: Any?) { run("step", -1) }
    @objc private func done(_ sender: Any?) { close() }

    /// False while the bar is hidden, so a late reply or a stray key can't search or write the count.
    var active = false
    private var pending: DispatchWorkItem?

    /// Typing searches after a short pause: each search rescans the page on its main thread, where agents' commands wait.
    func controlTextDidChange(_ obj: Notification) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.run("search", 0) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

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

    /// Searches the displayed tab again for the field's text, as when the bar reopens.
    func refresh() {
        if field.stringValue.isEmpty { count.stringValue = "" } else { run("search", 0) }
    }

    /// Removes the highlights from the page searched last.
    func clear() {
        pending?.cancel()
        searched?.callAsyncJavaScript("window.__agwebFind?.clear(); return ''", arguments: [:], in: nil, in: Self.world)
    }

    private func run(_ op: String, _ step: Int) {
        // A step re-searches by itself when the text changed, so a search still waiting is not needed.
        pending?.cancel()
        let text = field.stringValue
        guard active, let webView = webView() else { return }
        if searched !== webView { clear() }
        searched = webView
        webView.callAsyncJavaScript(Self.script + "return F.run(op, text, step);", arguments: ["op": op, "text": text, "step": step],
                                    in: nil, in: Self.world) { [weak self] result in
            guard let self, self.active, self.field.stringValue == text else { return }
            let parts = ((try? result.get()) as? String ?? "").split(separator: "/").compactMap { Int($0) }
            guard parts.count == 2, !text.trimmingCharacters(in: .whitespaces).isEmpty else { self.count.stringValue = ""; return }
            let (index, total) = (parts[0], parts[1])
            self.count.stringValue = total == 0 ? "No matches" : "\(index + 1) of \(total)\(total >= Self.limit ? "+" : "")"
        }
    }

    private static let limit = 1000

    /// The page's visible text, whitespace collapsed and case folded, mapped back to its text nodes, so a match can
    /// span inline elements ("foo <b>bar</b>"). A block boundary or <br> counts as a space. Same-origin frames are
    /// searched too; shadow roots and cross-origin frames are not. The highlight colours come from a constructed
    /// stylesheet, which adds no element to the page and isn't blocked by a style-src CSP.
    private static let script = #"""
    const F = window.__agwebFind || (window.__agwebFind = (() => {
      const LIMIT = 1000;
      const skip = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'TEXTAREA', 'HEAD', 'TITLE', 'SELECT', 'OPTION']);
      const docsOf = (doc) => [doc, ...[...doc.querySelectorAll('iframe, frame')].flatMap(f => {
        try { return f.contentDocument ? docsOf(f.contentDocument) : []; } catch { return []; }
      })];
      const css = '::highlight(agweb-find){background-color:rgba(255,214,0,.45);color:inherit}' +
        '::highlight(agweb-find-current){background-color:#ff9632;color:#000}';
      const S = { needle: null, matches: [], index: -1, docs: [], sheets: new Map() };
      const space = (code) => code === 32 || (code >= 9 && code <= 13) || code === 160 || code === 0x1680 || (code >= 0x2000 && code <= 0x200a) ||
        code === 0x2028 || code === 0x2029 || code === 0x202f || code === 0x205f || code === 0x3000 || code === 0xfeff;
      // One code unit in, one out, the same for the needle and the page, so offsets map back.
      const fold = (c) => { const l = c.toLowerCase(); return l.length === 1 ? l : c; };
      const norm = (s) => {
        let out = '', gap = false;
        for (const c of s) {
          if (space(c.charCodeAt(0))) { if (!gap) out += ' '; gap = true; } else { for (let i = 0; i < c.length; i++) out += fold(c[i]); gap = false; }
        }
        return out;
      };
      const clear = () => {
        for (const doc of S.docs) {
          try {
            doc.defaultView.CSS.highlights.delete('agweb-find');
            doc.defaultView.CSS.highlights.delete('agweb-find-current');
            const sheet = S.sheets.get(doc);
            if (sheet) doc.adoptedStyleSheets = doc.adoptedStyleSheets.filter(x => x !== sheet);
          } catch {}
        }
        Object.assign(S, { needle: null, matches: [], index: -1, docs: [], sheets: new Map() });
      };
      // A page put in the back/forward cache comes back as it left: without our highlights.
      addEventListener('pagehide', clear);
      const collect = (doc, needle) => {
        const root = doc.body || doc.documentElement;
        if (!root) return [];
        const view = doc.defaultView;
        const display = new Map();
        const inline = (el) => {
          if (!display.has(el)) { const d = view.getComputedStyle(el).display || ''; display.set(el, d.startsWith('inline') || d === 'contents'); }
          return display.get(el);
        };
        // Whether text in a and in b reads as separate: a block-level element lies between them.
        const apart = (a, b) => {
          const up = new Set();
          for (let e = a.parentElement; e; e = e.parentElement) up.add(e);
          let common = b.parentElement;
          for (; common && !up.has(common); common = common.parentElement) if (!inline(common)) return true;
          for (let e = a.parentElement; e && e !== common; e = e.parentElement) if (!inline(e)) return true;
          return false;
        };
        // checkVisibility() is false for display: contents, which has no box of its own but shows its children.
        const hidden = (el, opts) => el.checkVisibility?.(opts) === false && view.getComputedStyle(el).display !== 'contents';
        let brk = false;
        const walker = doc.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, { acceptNode: (n) => {
          if (n.nodeType === 3) return n.data.length ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
          if (skip.has(n.tagName) || hidden(n)) return NodeFilter.FILTER_REJECT;
          if (n.tagName === 'BR') brk = true;
          return NodeFilter.FILTER_SKIP;
        } });
        // text[j] came from nodes[mi[j]], code units mo[j] to me[j].
        let text = '', gap = true, prev = -1;
        const nodes = [], mi = [], mo = [], me = [];
        for (let n = walker.nextNode(); n; n = walker.nextNode()) {
          if (n.parentElement && hidden(n.parentElement, { visibilityProperty: true })) continue;
          if (prev >= 0 && !gap && (brk || apart(nodes[prev], n))) {
            const p = nodes[prev];
            text += ' '; mi.push(prev); mo.push(p.length); me.push(p.length); gap = true;
          }
          brk = false;
          nodes.push(n);
          const k = nodes.length - 1, d = n.data;
          for (let i = 0; i < d.length; i++) {
            const code = d.charCodeAt(i);
            if (space(code)) { if (gap) continue; text += ' '; gap = true; } else { text += fold(d[i]); gap = false; }
            mi.push(k); mo.push(i); me.push(i + 1);
          }
          prev = k;
        }
        const out = [];
        for (let i = text.indexOf(needle); i >= 0 && S.matches.length + out.length < LIMIT; i = text.indexOf(needle, i + needle.length)) {
          const r = doc.createRange(), e = i + needle.length - 1;
          r.setStart(nodes[mi[i]], mo[i]);
          r.setEnd(nodes[mi[e]], me[e]);
          out.push(r);
        }
        return out;
      };
      // Centres the match in each scrolling box around it, then in the window, then its frame in the page.
      const reveal = (r) => {
        const doc = r.startContainer.ownerDocument, view = doc.defaultView;
        for (let box = r.startContainer.parentElement; box && box !== doc.body && box !== doc.documentElement; box = box.parentElement) {
          if (box.scrollHeight <= box.clientHeight + 1 && box.scrollWidth <= box.clientWidth + 1) continue;
          const st = view.getComputedStyle(box);
          if (!/(auto|scroll|overlay)/.test(st.overflowY + ' ' + st.overflowX)) continue;
          const m = r.getBoundingClientRect(), b = box.getBoundingClientRect();
          if (m.top < b.top || m.bottom > b.bottom) box.scrollTop += (m.top + m.bottom) / 2 - (b.top + b.bottom) / 2;
          if (m.left < b.left || m.right > b.right) box.scrollLeft += (m.left + m.right) / 2 - (b.left + b.right) / 2;
        }
        const m = r.getBoundingClientRect();
        const dy = m.top < 0 || m.bottom > view.innerHeight ? (m.top + m.bottom) / 2 - view.innerHeight / 2 : 0;
        const dx = m.left < 0 || m.right > view.innerWidth ? (m.left + m.right) / 2 - view.innerWidth / 2 : 0;
        if (dx || dy) view.scrollBy({ left: dx, top: dy, behavior: 'instant' });
        const frame = view.frameElement;
        if (frame) {
          const fr = frame.getBoundingClientRect(), outer = frame.ownerDocument.defaultView;
          if (fr.top < 0 || fr.bottom > outer.innerHeight) frame.scrollIntoView({ block: 'center', behavior: 'instant' });
        }
      };
      const show = () => {
        for (const doc of S.docs) doc.defaultView?.CSS.highlights.delete('agweb-find-current');
        const r = S.matches[S.index];
        if (!r) return;
        const view = r.startContainer.ownerDocument.defaultView;
        const current = new view.Highlight(r);
        current.priority = 1;
        view.CSS.highlights.set('agweb-find-current', current);
        reveal(r);
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
          const sheet = new view.CSSStyleSheet();
          sheet.replaceSync(css);
          doc.adoptedStyleSheets = [...doc.adoptedStyleSheets, sheet];
          S.sheets.set(doc, sheet);
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
          // Other text, no matches yet (the page may have grown) or the page changed under them: search afresh.
          const stale = S.needle !== norm(text) || !S.matches.length || S.matches.some(r => !r.startContainer.isConnected);
          if (op === 'search' || stale) search(text);
          else { S.index = (S.index + step + S.matches.length) % S.matches.length; show(); }
          return `${S.index}/${S.matches.length}`;
        },
      };
    })());
    """#
}

extension MainWindow {
    @objc func showFind(_ sender: Any?) {
        guard model.displayedTab != nil, !model.dashboardOpen else { return NSSound.beep() }
        if !findOpen {
            findOpen = true
            findBar.active = true
            findTabID = model.displayedTabID
            updateFindItem()
            findBar.refresh()
        }
        focusFind(tries: 20)
    }

    /// A toolbar item just unhidden joins the window only after the toolbar lays out again, which can take a few
    /// run loop turns; until then the field can't take focus, so this retries.
    private func focusFind(tries: Int) {
        guard findOpen else { return }
        window.layoutIfNeeded()
        if findBar.field.window === window, window.makeFirstResponder(findBar.field) {
            findBar.field.selectText(nil)
        } else if tries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in self?.focusFind(tries: tries - 1) }
        } else {
            // No room: the toolbar put the field in its overflow menu.
            closeFind(refocus: false)
            NSSound.beep()
        }
    }

    @objc func findNext(_ sender: Any?) { findOpen ? findBar.next(sender) : showFind(sender) }
    @objc func findPrevious(_ sender: Any?) { findOpen ? findBar.previous(sender) : showFind(sender) }

    /// Typing goes back to the page only when the person closed the bar.
    func closeFind(refocus: Bool = true) {
        guard findOpen else { return }
        findBar.clear()
        findBar.active = false
        findOpen = false
        // A hidden field must not keep the keyboard: typing would go nowhere, or to the address field.
        if findBar.field.currentEditor() != nil { window.makeFirstResponder(nil) }
        updateFindItem()
        if refocus, let webView = model.displayedTab?.webView { window.makeFirstResponder(webView) }
    }

    /// Called when the displayed tab or the dashboard changes.
    func closeFindIfStale() {
        if findOpen, model.dashboardOpen || model.displayedTabID != findTabID { closeFind(refocus: false) }
    }
}
