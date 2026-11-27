// Function bodies for callAsyncJavaScript. They run in the isolated "agweb" content world, which shares the DOM
// with the page but not its globals, so the page cannot see or clobber window.__agweb.
public enum PageScripts {
    /// Why an empty target fails; the page's `find` and the commands that read no target as the whole page share it.
    public static let emptyTarget = "the target is empty (an unset shell variable?); use a ref from snapshot (e12), role=…, text=… or CSS"
    /// Targets: a snapshot ref (`e12`), `role=button[name="Save"]` (name: case-insensitive substring), `text=Save`
    /// (substring) or `text="Save"` (exact), else a CSS selector. Role and text targets must match exactly one
    /// visible element, so a click never lands on the wrong one of several.
    /// An element keeps its ref while it lives. Every document numbers on from `refSeed` (the workspace's highest
    /// ref so far, a page back from the cache included), so a ref from another page fails instead of naming a
    /// different element. `doc` tells one document from the next at the same URL.
    public static let find = """
    const W = window.__agweb || (window.__agweb = { refs: new Map(), ids: new WeakMap(), next: 0, doc: Math.random().toString(36).slice(2) });
    if (W.next < refSeed) W.next = refSeed;
    const refOf = (el) => {
      let ref = W.ids.get(el);
      if (!ref) {
        ref = `e${++W.next}`;
        W.ids.set(el, ref);
        W.refs.set(ref, new WeakRef(el));
      }
      return ref;
    };
    // A longer text ends in … so the reader knows it was cut.
    const clean = (s) => { const t = (s || '').replace(/\\s+/g, ' ').trim(); return t.length > 120 ? t.slice(0, 119) + '…' : t; };
    const roleOf = (el) => {
      const explicit = el.getAttribute('role');
      if (explicit === 'presentation' || explicit === 'none') return null;
      if (explicit) return explicit;
      const tag = el.tagName.toLowerCase();
      if (tag === 'a' && el.hasAttribute('href')) return 'link';
      if (tag === 'button' || tag === 'summary') return 'button';
      if (tag === 'select') return 'combobox';
      if (tag === 'textarea') return 'textbox';
      if (tag === 'input') {
        const type = (el.getAttribute('type') || 'text').toLowerCase();
        if (type === 'hidden') return null;
        return { checkbox: 'checkbox', radio: 'radio', submit: 'button', button: 'button', reset: 'button', image: 'button', range: 'slider', search: 'searchbox', file: 'button' }[type] || 'textbox';
      }
      if (/^h[1-6]$/.test(tag)) return 'heading';
      if (tag === 'img') return 'img';
      if (['nav', 'main', 'form', 'dialog', 'ul', 'ol', 'table'].includes(tag)) return { nav: 'navigation', ul: 'list', ol: 'list' }[tag] || tag;
      if (tag === 'li') return 'listitem';
      if (tag === 'tr') return 'row';
      if (tag === 'td') return 'cell';
      if (tag === 'th') return el.getAttribute('scope') === 'row' ? 'rowheader' : 'columnheader';
      if (tag === 'iframe' || tag === 'frame') return 'iframe';
      if (el.isContentEditable && !el.parentElement?.isContentEditable) return 'textbox';
      return null;
    };
    // The accessible name, in the spec's order: aria-labelledby, aria-label, a native label or alt, the content for
    // roles named by it (a combobox or textbox is not: its text is the value), then title and placeholder.
    const fromContent = new Set(['link', 'button', 'heading', 'checkbox', 'radio', 'switch', 'tab', 'menuitem', 'option', 'listitem', 'cell', 'generic',
      'gridcell', 'columnheader', 'rowheader', 'row']);
    // innerText without aria-hidden parts: an icon font's ligature ("lens", "help") is not part of a name.
    const shownText = (el) => {
      let text = el.innerText || '';
      for (const hidden of el.querySelectorAll('[aria-hidden="true"]')) text = text.replace(hidden.innerText || '\\u0000', ' ');
      return text;
    };
    // A control's first label. el.labels scans the control's whole tree on every read, so naming 6000 inputs took 1.6 s;
    // each tree's labels are mapped once per script run instead.
    const labelMaps = new Map();
    const labelOf = (el) => {
      if (!('labels' in el)) return null;
      const root = el.getRootNode();
      let map = labelMaps.get(root);
      if (!map) {
        map = new Map();
        for (const label of root.querySelectorAll?.('label') ?? []) { const control = label.control; if (control && !map.has(control)) map.set(control, label); }
        labelMaps.set(root, map);
      }
      return map.get(el) ?? null;
    };
    const nameOf = (el, role = roleOf(el)) => {
      const root = el.getRootNode();
      // Without aria-hidden parts: a required "*" and icon ligatures ("help") are not part of a name.
      const spoken = (n) => n.nodeType === 3 ? n.textContent : n.nodeType !== 1 || n.getAttribute('aria-hidden') === 'true' ? ''
        : [...n.childNodes].map(spoken).join(' ');
      const labelledBy = (el.getAttribute('aria-labelledby') || '').split(/\\s+/)
        .map(id => id && root.getElementById?.(id) || el.ownerDocument.getElementById(id)).filter(Boolean).map(spoken).join(' ');
      const button = el.tagName === 'INPUT' && ['submit', 'button', 'reset'].includes(el.type);
      return clean(
        labelledBy || el.getAttribute('aria-label') || labelOf(el)?.innerText || el.getAttribute('alt') ||
        (button ? el.value : '') || (fromContent.has(role) && !['INPUT', 'TEXTAREA', 'SELECT'].includes(el.tagName) ? shownText(el) : '') ||
        (fromContent.has(role) ? el.querySelector?.('img[alt]')?.getAttribute('alt') : '') ||
        el.getAttribute('title') || el.getAttribute('placeholder') || ''
      );
    };
    const visible = (el) => el.getClientRects().length > 0 && el.ownerDocument.defaultView.getComputedStyle(el).visibility !== 'hidden';
    // Every element, through open shadow roots and same-origin iframes.
    const all = function* (root) {
      for (const el of root.querySelectorAll('*')) {
        yield el;
        if (el.shadowRoot) yield* all(el.shadowRoot);
        if (el.tagName === 'IFRAME' || el.tagName === 'FRAME') { let doc = null; try { doc = el.contentDocument; } catch {} if (doc) yield* all(doc); }
      }
    };
    // A CSS selector's matches in the page; only when none of them shows, also those in every open shadow root and
    // same-origin frame, as Playwright's CSS reaches into them (a hidden copy in the page doesn't hide a shown one
    // there). A selector stays within one root: target the input, not `host input` or `iframe input`.
    const css = (selector) => {
      const found = [...document.querySelectorAll(selector)];
      if (found.some(visible)) return found;
      for (const el of all(document)) {
        let root = el.shadowRoot;
        if (!root && (el.tagName === 'IFRAME' || el.tagName === 'FRAME')) { try { root = el.contentDocument; } catch {} }
        if (root) for (const match of root.querySelectorAll(selector)) found.push(match);
      }
      return found;
    };
    // A heading's level, as the snapshot prints it.
    const levelOf = (el) => /^H[1-6]$/.test(el.tagName) ? +el.tagName[1] : parseInt(el.getAttribute('aria-level'), 10) || 2;
    // Every visible element a role= or text= target matches.
    const matchesOf = (target) => {
      if (target.startsWith('role=')) {
        // name*= is accepted too: the name is a substring either way. [level=N] as a snapshot prints it for headings.
        const head = /^role=([\\w-]+)/.exec(target), filters = {};
        let rest = head ? target.slice(head[0].length) : null;
        while (rest) {
          const f = /^\\[(name|level)\\*?=(?:"([^"]*)"|'([^']*)'|([^\\]]*))\\]/.exec(rest);
          if (!f) { rest = null; break; }
          filters[f[1]] = f[2] ?? f[3] ?? f[4];
          rest = rest.slice(f[0].length);
        }
        if (rest === null || (filters.level !== undefined && !/^-?\\d+$/.test(filters.level))) {
          const e = new Error(`invalid selector ${target}: use role=button, role=button[name="Save"] (a case-insensitive substring) or role=heading[level=2]`);
          e.name = 'SyntaxError';
          throw e;
        }
        const role = head[1], name = filters.name?.toLowerCase().replace(/…$/, ''); // a cut name copied from a snapshot
        return [...all(document)].filter(el => roleOf(el) === role && visible(el) && (name === undefined || nameOf(el).toLowerCase().includes(name))
          && (filters.level === undefined || levelOf(el) === +filters.level));
      }
      // Not clean(): its 120-character cut would hide the end of a long paragraph.
      const whole = (s) => (s || '').replace(/\\s+/g, ' ').trim();
      const raw = target.slice(5), exact = /^".*"$/.test(raw), text = exact ? whole(raw.slice(1, -1)) : whole(raw).toLowerCase();
      const has = (el) => {
        if (!(el.textContent || '').toLowerCase().includes(exact ? text.toLowerCase() : text)) return false;
        const t = whole(el.innerText);
        return exact ? t === text : t.toLowerCase().includes(text);
      };
      // The innermost elements holding the text, not every ancestor of them.
      return [...all(document)].filter(el => !['SCRIPT', 'STYLE', 'HEAD', 'TITLE'].includes(el.tagName) && has(el) && visible(el) && ![...el.children].some(has));
    };
    const label = (el) => `${roleOf(el) || el.tagName.toLowerCase()} ${JSON.stringify(nameOf(el) || clean(el.innerText).slice(0, 40))}${roleOf(el) === 'heading' ? ` [level=${levelOf(el)}]` : ''} [ref=${refOf(el)}]`;
    const list = (els) => els.slice(0, 5).map(label).join('; ') + (els.length > 5 ? `; and ${els.length - 5} more` : '');
    // A CSS miss on a URL attribute: CSS compares the attribute as the page wrote it (HN's form has action="comment"),
    // while eval's form.action is the resolved URL.
    const urlHint = (selector) => {
      const m = /\\[\\s*(href|src|action|formaction)\\s*([\\^$*]?=)\\s*(?:"([^"]*)"|'([^']*)'|([^\\]\\s]+))\\s*\\]/i.exec(selector);
      if (!m) return '';
      const attr = m[1].toLowerCase(), op = m[2], value = m[3] ?? m[4] ?? m[5];
      // Only a full URL with a host: a[href^="http"] means links written absolute, and every relative one resolves to http.
      if (!/:\\/\\/[^/]/.test(value)) return '';
      const prop = { href: 'href', src: 'src', action: 'action', formaction: 'formAction' }[attr];
      const hit = (url) => typeof url === 'string' && (op === '=' ? url === value : op === '^=' ? url.startsWith(value) : op === '$=' ? url.endsWith(value) : url.includes(value));
      let els = [];
      try { els = [...document.querySelectorAll(selector.slice(0, m.index) + `[${attr}]` + selector.slice(m.index + m[0].length))]; } catch { return ''; }
      els = els.filter(el => hit(el[prop]));
      if (!els.length) return '';
      return `; CSS matches ${attr} as the page writes it (${JSON.stringify(els[0].getAttribute(attr))}), not the resolved URL: ${list(els)}`;
    };
    // `<target> >> nth=N` picks one of several matches, counting from 0; -1 is the last.
    const find = (target) => {
      const nth = /^(.*?)\\s*>>\\s*nth=(-?\\d+)$/.exec(target);
      // Usually an unset shell variable (`fill "$REF" x`); querySelectorAll('') would only say "invalid selector".
      if (!(nth ? nth[1] : target).trim()) {
        const e = new Error(`invalid selector ${JSON.stringify(target)}: \(emptyTarget)`);
        e.name = 'SyntaxError';
        throw e;
      }
      if (!nth) return findOne(target);
      const els = /^(role|text)=/.test(nth[1]) ? matchesOf(nth[1]) : css(nth[1]);
      const el = els.at(Number(nth[2]));
      if (!el) throw new Error(`no visible element matches ${target}: ${nth[1]} matches ${els.length}`);
      return el;
    };
    const findOne = (target) => {
      if (/^e\\d+$/.test(target)) {
        const el = W.refs.get(target)?.deref();
        // An element of an iframe that navigated away stays connected to its old document, which has no window.
        if (!el || !el.isConnected || !el.ownerDocument.defaultView) throw new Error(`ref ${target} not found: the page changed; take a new snapshot`);
        return el;
      }
      if (!/^(role|text)=/.test(target)) {
        // The first one a person can see: a page often keeps a hidden copy first (a collapsed quick-login form).
        const els = css(target);
        if (!els.length) throw new Error(`no element matches ${target}` + urlHint(target));
        return els.find(visible) ?? els[0];
      }
      const matches = matchesOf(target);
      if (matches.length === 0) {
        // A near miss: the elements of that role and their names, so the next try needs no snapshot.
        const role = /^role=([\\w-]+)/.exec(target)?.[1];
        const near = role ? [...all(document)].filter(el => roleOf(el) === role && visible(el)) : [];
        throw new Error(`no visible element matches ${target}` + (near.length ? `; visible ${role}s: ${list(near)}` : ''));
      }
      if (matches.length > 1) {
        throw new Error(`${target} matches ${matches.length} elements: ${list(matches)}. Be more specific, use a ref from snapshot, or add >> nth=0`);
      }
      return matches[0];
    };
    // Where a window sits in the frame tree: its index among its parent's frames at each level, from the top. The
    // same numbers work across origins, so a cross-origin frame and the iframe showing it give the same path.
    const framePath = (w) => {
      const path = [];
      for (; w !== w.parent; w = w.parent) {
        let i = 0;
        while (i < w.parent.length && w.parent[i] !== w) i++;
        if (i === w.parent.length) return null;
        path.unshift(i);
      }
      return path;
    };
    // The element's rect in the top page's viewport, through same-origin iframes.
    const rectOf = (el) => {
      const r = el.getBoundingClientRect();
      let x = r.left, y = r.top;
      for (let w = el.ownerDocument.defaultView; w && w.frameElement; w = w.parent) {
        const f = w.frameElement.getBoundingClientRect();
        x += f.left + w.frameElement.clientLeft;
        y += f.top + w.frameElement.clientTop;
      }
      return { x, y, width: r.width, height: r.height, local: r };
    };
    """

    public static let maxSnapshotLines = 2000

    /// The whole page, or with `target` only that element and what is inside it; `limit` lines at most, 0 for all of them.
    public static let snapshot = find + """
    const root = target ? find(target) : null;
    for (const [ref, weak] of W.refs) if (!weak.deref()) W.refs.delete(ref);
    // `shown`: the refs on lines, for the app to tell a frame's refs from the page's.
    const lines = [], frames = [], shown = [];
    let truncated = false;
    const skip = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'svg', 'HEAD']);
    const leaf = new Set(['link', 'button', 'textbox', 'searchbox', 'combobox', 'checkbox', 'radio', 'slider', 'heading', 'img', 'switch', 'tab', 'menuitem', 'option',
      'cell', 'gridcell', 'columnheader', 'rowheader', 'generic']);
    const emit = (line) => {
      if (limit && lines.length >= limit) { truncated = true; return false; }
      lines.push(line);
      return true;
    };
    // Shadow hosts render their shadow tree; slots render what was assigned to them.
    const childrenOf = (node) => {
      if (node.shadowRoot) return node.shadowRoot.childNodes;
      if (node.tagName === 'SLOT') {
        const assigned = node.assignedNodes({ flatten: true });
        return assigned.length ? assigned : node.childNodes;
      }
      if (node.tagName === 'IFRAME' || node.tagName === 'FRAME') {
        let body = null;
        try { body = node.contentDocument?.body; } catch {}
        return body ? [body] : [];
      }
      return node.childNodes;
    };
    const visit = (node, depth) => {
      if (node.nodeType === Node.TEXT_NODE) {
        const text = clean(node.textContent);
        if (text) emit(`${'  '.repeat(depth)}- text: ${JSON.stringify(text)}`);
        return;
      }
      // aria-hidden is not followed, as in Playwright's snapshot: pages leave it on what they show (react-bootstrap's
      // open modal), and an agent acts on what is on screen. Names still leave aria-hidden parts out.
      if (node.nodeType !== Node.ELEMENT_NODE || skip.has(node.tagName)) return;
      const style = node.ownerDocument.defaultView.getComputedStyle(node);
      // display:contents boxes (every <slot> by default) have no rects but their children do.
      if (style.display === 'contents' || node.tagName === 'BODY' || node.tagName === 'FRAMESET') { walk(node, depth); return; }
      if (node.getClientRects().length === 0 || style.visibility === 'hidden') return;
      const role = controlRole(node);
      if (!role) { if (!crossFrame(node, depth)) walk(node, depth); return; }
      const ref = refOf(node);
      let line = `${'  '.repeat(depth)}- ${role}`;
      // A container's text shows as its children, so only a leaf is named by its content.
      const name = nameOf(node, leaf.has(role) ? role : null);
      if (name) line += ` ${JSON.stringify(name)}`;
      // A number only: a page's aria-level="2] [ref=e1" must not forge another ref's line.
      if (role === 'heading') line += ` [level=${/^H[1-6]$/.test(node.tagName) ? node.tagName[1] : parseInt(node.getAttribute('aria-level'), 10) || 2}]`;
      if (node.checked || node.getAttribute('aria-checked') === 'true') line += ' [checked]';
      if (node.getAttribute('aria-selected') === 'true') line += ' [selected]';
      if (node.getAttribute('aria-expanded') === 'true') line += ' [expanded]';
      if (node.disabled) line += ' [disabled]';
      // A password or card someone typed by hand must not reach an agent's transcript.
      if (node.type === 'password' || /\\bcc-(number|csc|exp)/.test(node.autocomplete) || W.secrets?.has(node)) { if (node.value) line += ' [value=<hidden>]'; }
      else if (['textbox', 'searchbox', 'combobox'].includes(role) && node.tagName !== 'SELECT' && node.value) line += ` [value=${JSON.stringify(clean(node.value))}]`;
      // A custom select (mat-select, a div with role=combobox) shows its choice as its text, not a value.
      else if (role === 'combobox' && !('value' in node)) {
        // Not the options of a list it holds open.
        const own = (n) => n.nodeType === 3 ? n.textContent : n.nodeType !== 1 || ['listbox', 'option', 'menu'].includes(n.getAttribute('role')) ? ''
          : [...n.childNodes].map(own).join(' ');
        const shown = clean(node.getAttribute('aria-valuetext') || own(node));
        if (shown && shown !== name) line += ` [value=${JSON.stringify(shown)}]`;
      }
      line += ` [ref=${ref}]`;
      if (node === document.activeElement) line += ' [focused]';
      if (!emit(line)) return;
      shown.push(ref);
      if (crossFrame(node, depth + 1)) return;
      if (node.tagName === 'SELECT') {
        for (const option of node.options) {
          emit(`${'  '.repeat(depth + 1)}- option ${JSON.stringify(clean(option.label))}${option.selected ? ' [selected]' : ''}`);
        }
      } else {
        walk(node, depth + 1, leaf.has(role));
      }
    };
    // A cross-origin frame (Stripe's has role=presentation) shows as a marker line the app replaces with the frame's
    // own snapshot; its iframe's ref places the frame on screen.
    const isCrossFrame = (node) => {
      if (!['IFRAME', 'FRAME'].includes(node.tagName) || !node.contentWindow) return false;
      try { return !node.contentDocument; } catch { return true; }
    };
    const crossFrame = (node, depth) => {
      if (!isCrossFrame(node)) return false;
      const path = framePath(node.contentWindow);
      if (path && emit(`${'  '.repeat(depth)}\\u0001${frames.length}`)) { frames.push({ path, ref: refOf(node) }); shown.push(refOf(node)); }
      return true;
    };
    // Inside a leaf (a button, a link, a combobox) its text is already the name, so only elements with a role
    // show: a search box in a dialog the page made a button, the options of an open custom select.
    const walk = (parent, depth, insideLeaf = false) => {
      for (const node of childrenOf(parent)) {
        if (truncated) return;
        if (insideLeaf) { for (const el of roled(node)) visit(el, depth); } else visit(node, depth);
      }
    };
    // A control built from a span or div, which only its tabindex or pointer cursor gives away, shows as Playwright
    // does: a generic with a ref. The cursor counts only where it starts, not on every child under it.
    const controlRole = (node) => {
      const role = roleOf(node);
      if (role) return role;
      const view = node.ownerDocument.defaultView, parent = node.parentElement;
      const tabbable = node.hasAttribute('tabindex') && node.getAttribute('tabindex') !== '-1';
      const pointer = view.getComputedStyle(node).cursor === 'pointer' && parent && view.getComputedStyle(parent).cursor !== 'pointer';
      return (tabbable || pointer) && clean(node.innerText) ? 'generic' : null;
    };
    const roled = function* (node) {
      if (node.nodeType !== Node.ELEMENT_NODE) return;
      if (controlRole(node) || isCrossFrame(node)) { yield node; return; }
      for (const child of childrenOf(node)) yield* roled(child);
    };
    if (root) visit(root, 0); else walk(document.body || document.documentElement, 0);
    if (truncated) lines.push(`- (truncated at ${limit} lines; snapshot --filename saves all of them)`);
    if (root && !lines.length && (skip.has(root.tagName) || !root.checkVisibility({ visibilityProperty: true }))) lines.push('- (hidden on the page, so no tree; eval reads it)');
    // The refs only from a frame below the page (the app routes them to it): 150,000 of them would ride along for nothing.
    return JSON.stringify({ tree: lines.join('\\n'), next: W.next, doc: W.doc, frames, refs: window === window.top ? undefined : shown, path: framePath(window) });
    """

    /// The frame's path in the frame tree (see `framePath`), to tell which cross-origin frame a handle is.
    public static let framePath = find + """
    return JSON.stringify(framePath(window));
    """

    /// Scrolls whatever holds the iframe so `at`, a point in its content, shows; returns where that point is then in this
    /// document's top viewport. A cross-origin frame's own scrollIntoView never scrolls the page around it.
    public static let revealAt = find + """
    // A box of `size` at `at` in the iframe's content, in that document's viewport; each scroller holding the iframe
    // (through shadow hosts and same-origin frames, a body that scrolls included) scrolls it fully into view, to the
    // middle as the page's own targets go.
    const el = find(target), style = el.ownerDocument.defaultView.getComputedStyle(el), r = el.getBoundingClientRect();
    const box = { x: r.left + el.clientLeft + parseFloat(style.paddingLeft) + at.x - size.width / 2,
                  y: r.top + el.clientTop + parseFloat(style.paddingTop) + at.y - size.height / 2 };
    let moved = false;
    // How far to scroll one axis so the box shows within [start, start + length].
    const delta = (from, extent, start, length) =>
      extent <= length ? (from < start || from + extent > start + length ? from + extent / 2 - (start + length / 2) : 0)
                       : (from > start || from + extent < start + length ? from - start : 0);
    const scroll = (scroller, dx, dy, read) => {
      if (!dx && !dy) return;
      const [x0, y0] = read();
      scroller.scrollBy({ left: dx, top: dy, behavior: 'instant' });
      const [x1, y1] = read();
      box.x -= x1 - x0;
      box.y -= y1 - y0;
      moved ||= x1 !== x0 || y1 !== y0;
    };
    for (let n = el; n; ) {
      const doc = n.ownerDocument, win = doc.defaultView;
      const up = n.assignedSlot || n.parentElement || n.getRootNode().host;
      if (up) {
        if (up !== doc.scrollingElement && /auto|scroll|overlay/.test(win.getComputedStyle(up).overflow)) {
          const b = up.getBoundingClientRect();
          scroll(up, delta(box.x, size.width, b.left + up.clientLeft, up.clientWidth), delta(box.y, size.height, b.top + up.clientTop, up.clientHeight),
                 () => [up.scrollLeft, up.scrollTop]);
        }
        n = up;
        continue;
      }
      // The top of a document: its window, then out to the iframe holding it, while that one is same-origin.
      scroll(win, delta(box.x, size.width, 0, win.innerWidth), delta(box.y, size.height, 0, win.innerHeight), () => [win.scrollX, win.scrollY]);
      const f = win.frameElement;
      if (!f) break;
      const fb = f.getBoundingClientRect(), fs = f.ownerDocument.defaultView.getComputedStyle(f);
      box.x += fb.left + f.clientLeft + parseFloat(fs.paddingLeft);
      box.y += fb.top + f.clientTop + parseFloat(fs.paddingTop);
      n = f;
    }
    return JSON.stringify({ x: box.x + size.width / 2, y: box.y + size.height / 2, moved });
    """

    /// Where an iframe's content starts in its document's top viewport: frame content there is offset by this.
    public static let frameOrigin = find + """
    const el = find(target), r = rectOf(el), style = el.ownerDocument.defaultView.getComputedStyle(el);
    return JSON.stringify({ x: r.x + el.clientLeft + parseFloat(style.paddingLeft), y: r.y + el.clientTop + parseFloat(style.paddingTop) });
    """

    /// Markdown through Defuddle (loaded into this world first): one element converted whole, or the page's main
    /// content. A page with little article in it (a web app) is converted whole instead.
    public static let text = find + """
    // An image inlined as a data: URL (Google's result thumbnails) is kilobytes of base64 no reader can use: it keeps
    // its alt text, type and size with the data cut, or goes when it has no alt; snapshot still lists it with a ref.
    let dropped = 0;
    const noData = (root) => {
      for (const source of root.querySelectorAll('source[srcset^="data:" i]')) source.remove();
      for (const img of root.querySelectorAll('img')) {
        if (/^\\s*data:/i.test(img.getAttribute('srcset') || '')) img.removeAttribute('srcset');
        // A lazy image's data: src is a placeholder: the converter takes the real one from srcset or <source>.
        if (!/^\\s*data:/i.test(img.getAttribute('src') || '') || img.getAttribute('srcset') || img.closest('picture')?.querySelector('source[srcset]')) continue;
        dropped++;
        if (!(img.getAttribute('alt') || '').trim()) { img.remove(); continue; }
        const src = img.getAttribute('src').trim();
        img.setAttribute('src', `${src.split(/[;,]/)[0]}… ${Math.max(1, Math.round(src.length * 0.75 / 1000))} KB cut`);
      }
    };
    // Inline SVG icons come through as markup, which no reader wants; they go from a copy before converting, so a
    // code sample showing <svg> (text, not an element) stays.
    const bare = (html) => {
      const box = document.createElement('template');
      box.innerHTML = html;
      for (const svg of box.content.querySelectorAll('svg')) svg.remove();
      noData(box.content);
      return box;
    };
    // A copy of what the page shows: elements it hides (display: none) stay out, such as a challenge page's
    // "Verification successful" waiting for its turn, and so do inline SVGs. Defuddle's article drops hidden ones itself.
    const shownCopy = (el, inner) => {
      const box = document.createElement('template');
      // Into the template's inert document: a clone in the page's would upgrade custom elements, running their code.
      const inert = box.content.ownerDocument;
      // What a node renders: a shadow host its open shadow tree (rapi-doc's operations), a slot what was assigned to it.
      const rendered = (node) => {
        if (node.shadowRoot) return node.shadowRoot.childNodes;
        if (node.localName !== 'slot') return node.childNodes;
        const assigned = node.assignedNodes({ flatten: true });
        return assigned.length ? assigned : node.childNodes;
      };
      const copy = (node) => {
        const out = inert.importNode(node, false);
        for (const child of rendered(node)) {
          // A shadow tree's styles come along with it.
          if (child.nodeType === 1 && (['svg', 'style', 'script'].includes(child.localName) || getComputedStyle(child).display === 'none')) continue;
          out.appendChild(copy(child));
        }
        return out;
      };
      const root = copy(el);
      box.content.append(...(inner ? [...root.childNodes] : [root]));
      noData(box.content);
      return box;
    };
    const md = (box) => Defuddle.createMarkdownContent(box.innerHTML, location.href);
    const words = (s) => (s.match(/\\S+/g) || []).length;
    const reply = (markdown, whole = false, kept = 0, shown = 0, huge = 0) => JSON.stringify({ markdown, whole, kept, shown, dropped, huge });
    if (target) {
      const el = find(target);
      return JSON.stringify({ markdown: md(shownCopy(el, false)), hidden: !el.checkVisibility(), dropped });
    }
    const body = () => { dropped = 0; return md(shownCopy(document.body, true)); };
    if (everything) return reply(body(), true);
    // A page that says it is an article: og:type or schema.org JSON-LD.
    const declared = document.querySelector('meta[property="og:type"]')?.content === 'article' ||
      [...document.querySelectorAll('script[type="application/ld+json"]')].some(s => /"@type"\\s*:\\s*\\[?\\s*"(\\w*Article|BlogPosting)"/.test(s.textContent));
    // Sites Defuddle has its own reader for, which skips the slow scoring: the URL patterns of defuddle.js's
    // ExtractorRegistry (0.13.3; keep them in step when updating it), less its catch-all.
    const site = /(^|\\.)(x\\.com|twitter\\.com|reddit\\.com|youtube\\.com|youtu\\.be|bilibili\\.com|news\\.ycombinator\\.com|chatgpt\\.com|claude\\.ai|grok\\.com|gemini\\.google\\.com|mail\\.google\\.com|github\\.com|linkedin\\.com|threads\\.net|threads\\.com|bsky\\.app|medium\\.com|wiki\\.c2\\.com|substack\\.com|nytimes\\.com|wikipedia\\.org|leetcode\\.com|lwn\\.net)$/.test(location.hostname)
      || /\\/@[^/]+\\/\\d+|\\/t\\/[^/]+\\/\\d+/.test(location.pathname);
    // Defuddle scores every element (shadow roots flattened in), 3.4 s on a 42,000-element feed whatever its options;
    // a page that big comes back whole, unless it says it is an article or has a site reader.
    const count = (root) => { const all = root.querySelectorAll('*'); let n = all.length; for (const el of all) if (el.shadowRoot) n += count(el.shadowRoot); return n; };
    const elements = declared || site ? 0 : count(document);
    if (elements > 15000) return reply(body(), true, 0, 0, elements);
    const page = new Defuddle(document, { url: location.href }).parse();
    if (page.wordCount < 50) return reply(body(), true);
    // The article can leave out what a reader came for, such as a pricing page's plans: say how much it kept,
    // counting both sides the same way.
    const article = bare(page.content);
    const kept = words(article.content.textContent), shown = words(document.body.innerText);
    // A listing or docs index kept under half loses its rows, so it comes back whole, unless the page says it is an
    // article or one of Defuddle's site extractors (Hacker News, Reddit, GitHub) read it.
    if (shown > 300 && kept * 2 < shown && !declared && !page.extractorType) return reply(body(), true);
    return reply((page.title ? `# ${page.title}\\n\\n` : '') + md(article), false, kept, shown);
    """

    // Returns the element's center in CSS pixels (`reveal` brings it into view first), what actually sits there (at
    // `at`, a point in the top viewport, when given), and what kind of control it is (some controls open native
    // popups when clicked). `covered` names what would take a click instead, such as a cookie dialog's backdrop.
    public static let locate = find + """
    const el = find(target);
    const r = rectOf(el);
    // A link wrapped over two lines: its bounding box's middle can sit on the next link, so its biggest line box counts.
    const rects = [...el.getClientRects()];
    const box = rects.length > 1 ? rects.reduce((a, b) => a.width * a.height >= b.width * b.height ? a : b) : r.local;
    const dx = r.x - r.local.left, dy = r.y - r.local.top;
    const point = typeof at === 'object' && at ? at : null;
    const lx = point ? point.x - dx : box.left + box.width / 2, ly = point ? point.y - dy : box.top + box.height / 2;
    // Up through slots and shadow hosts, which contains() stops at.
    const up = (n) => n.assignedSlot || n.parentElement || n.getRootNode().host;
    const within = (n, root) => { for (; n; n = up(n)) if (n === root) return true; return false; };
    // A label passes its clicks to its control: a styled checkbox hides the input under its label's span.
    const control = (n) => n.closest?.('label')?.control;
    let hit = el.getRootNode().elementFromPoint?.(lx, ly) ?? el.ownerDocument.elementFromPoint(lx, ly);
    let cover = hit && !within(hit, el) && !within(el, hit) && control(hit) !== el && control(el) !== hit ? hit : null;
    // Each document above a same-origin frame must have the frame there, not a backdrop of its own.
    for (let w = el.ownerDocument.defaultView, x = lx, y = ly; !cover && w.frameElement; w = w.parent) {
      const f = w.frameElement, b = f.getBoundingClientRect();
      x += b.left + f.clientLeft;
      y += b.top + f.clientTop;
      const above = f.ownerDocument.elementFromPoint(x, y);
      if (above && !within(above, f) && !within(f, above)) cover = above;
    }
    const name = (n) => {
      let s = n.tagName.toLowerCase() + (n.id ? '#' + n.id : n.classList?.[0] ? '.' + n.classList[0] : '');
      const role = n.getAttribute('role'), label = n.getAttribute('aria-label');
      if (role) s += ` role=${role}`;
      if (label) s += ` "${label.trim().slice(0, 40)}"`;
      return `<${s}>`;
    };
    const describe = (n) => {
      let s = name(n);
      const owner = !n.id && n.parentElement?.closest('[id]');
      if (owner) s += ` in #${owner.id}`;
      // A backdrop is often its modal's sibling, so a modal on screen counts too; never one the target is in.
      const shown = (d) => {
        const b = d.getBoundingClientRect();
        return !d.closest('[aria-hidden=true]') && d.checkVisibility({ opacityProperty: true, visibilityProperty: true })
          && b.width && b.height && b.bottom > 0 && b.top < innerHeight;
      };
      const mine = (d) => d && !within(el, d) ? d : null;
      const dialog = mine(n.closest('[role=dialog], [role=alertdialog], [aria-modal=true], dialog'))
        ?? [...n.ownerDocument.querySelectorAll('[role=alertdialog], [aria-modal=true], dialog:modal')].find((d) => mine(d) && shown(d));
      if (dialog) {
        const title = dialog.getAttribute('aria-label') || (dialog.getAttribute('aria-labelledby') || '').split(/\\s+/)
          .map((id) => id && n.ownerDocument.getElementById(id)?.textContent.trim()).filter(Boolean).join(' ')
          || dialog.querySelector('h1, h2, h3, [role=heading]')?.textContent.trim();
        s += title ? `; dialog "${title.replace(/\\s+/g, ' ').slice(0, 60)}" is open` : '; a dialog is open';
      }
      return s;
    };
    const covered = cover ? describe(cover) : null;
    const kindOf = (e) => !e ? '' : e.tagName === 'SELECT' ? 'select' : e.tagName === 'INPUT' ? (e.getAttribute('type') || 'text').toLowerCase() : e.tagName.toLowerCase();
    const kind = kindOf(el), hitKind = kindOf(hit);
    return JSON.stringify({ x: box.left + box.width / 2 + dx, y: box.top + box.height / 2 + dy, covered, kind, hitKind, width: box.width, height: box.height, viewportWidth: innerWidth, viewportHeight: innerHeight });
    """

    /// Agent world: where a Cloudflare challenge's checkbox is, in CSS pixels, or null. The widget (300×65, the box
    /// 21 px in) sits in a closed shadow root next to its hidden response input, so its container stands in for it.
    public static let challengeSpot = """
    // The challenge page's own widget id: a login form's Turnstile (name="cf-turnstile-response") is no challenge page.
    const input = document.querySelector('input[id^="cf-chl-widget-"]');
    const r = input?.parentElement?.getBoundingClientRect();
    if (!r || !r.width || !r.height) return null;
    return JSON.stringify({ x: r.left + 21, y: r.top + Math.min(r.height, 65) / 2 });
    """

    /// Scrolls the element to the middle of the viewport, out from under a sticky header or footer.
    public static let center = find + """
    find(target).scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
    return 'ok';
    """

    /// The element's box in the top viewport, after scrolling it into view, for element screenshots.
    public static let box = find + """
    const el = find(target);
    el.scrollIntoView({ block: 'nearest', inline: 'nearest', behavior: 'instant' });
    const r = rectOf(el);
    return JSON.stringify({ x: r.x, y: r.y, width: r.width, height: r.height, viewportWidth: innerWidth, viewportHeight: innerHeight });
    """

    /// The page's own scrolling: the root, and a body whose overflow goes to the viewport.
    static let pageScrolls = """
    const pageScrolls = (el) => {
      const doc = el.ownerDocument;
      return el === doc.documentElement || el === doc.scrollingElement
        || (el === doc.body && doc.defaultView.getComputedStyle(doc.documentElement).overflowY === 'visible');
    };
    """

    /// Before a screenshot taller than the viewport, which grows the view (moving scroll positions): keeps every scroll
    /// position for `shotEnd`, goes to the top, and measures the page and its scroller: the biggest element scrolling
    /// on its own, wide like a page's main part (chat apps keep the document at the window's height and scroll the
    /// messages inside; a sidebar is narrow), and hiding more than the document does (on a page that scrolls by
    /// itself, a box inside is part of it).
    public static let shotStart = pageScrolls + """
    const page = Math.max(document.documentElement.scrollHeight, document.body?.scrollHeight ?? 0);
    const scrolled = [[document.scrollingElement || document.documentElement, scrollX, scrollY]];
    let scroller = null, area = 0;
    for (const el of document.querySelectorAll('*')) {
      if (el.scrollHeight <= el.clientHeight && el.scrollWidth <= el.clientWidth) continue;
      scrolled.push([el, el.scrollLeft, el.scrollTop]);
      if (pageScrolls(el) || el.scrollHeight - el.clientHeight <= page - innerHeight + 1) continue;
      if (el.clientHeight < innerHeight / 3 || el.clientWidth < innerWidth * 0.4) continue;
      if (!['auto', 'scroll', 'overlay'].includes(getComputedStyle(el).overflowY)) continue;
      if (el.clientWidth * el.clientHeight > area) { area = el.clientWidth * el.clientHeight; scroller = el; }
    }
    globalThis.agwebShot = { scrolled, scroller };
    scrollTo({ left: 0, top: 0, behavior: 'instant' });
    return JSON.stringify({ page, hidden: scroller ? scroller.scrollHeight - scroller.clientHeight : 0, scrollerHeight: scroller?.clientHeight ?? 0 });
    """

    /// After the view grew: how much of the scroller `shotStart` found is still hidden, and the height the document's
    /// box takes (scrollHeight never says less than the view).
    public static let shotMeasure = """
    const s = globalThis.agwebShot?.scroller, doc = document.documentElement.getBoundingClientRect().bottom + scrollY;
    // Re-rendered on resize: what it hides now is unknown.
    if (!s?.isConnected) return JSON.stringify({ gone: 1, doc });
    return JSON.stringify({ hidden: s.scrollHeight - s.clientHeight, scrollerHeight: s.clientHeight, doc });
    """

    /// After the view grew to fit a tall element: puts it at the top, and says which part of it shows (a scrolling box
    /// of fixed height around it still cuts it).
    public static let shotElement = find + pageScrolls + """
    const el = find(target);
    el.scrollIntoView({ block: 'start', inline: 'nearest', behavior: 'instant' });
    await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
    const r = rectOf(el), view = el.ownerDocument.defaultView;
    let top = Math.max(r.local.top, 0), bottom = Math.min(r.local.bottom, view.innerHeight);
    for (let a = el.parentElement ?? el.getRootNode().host; a; a = a.parentElement ?? a.getRootNode().host) {
      if (pageScrolls(a) || view.getComputedStyle(a).overflowY === 'visible') continue;
      const b = a.getBoundingClientRect();
      top = Math.max(top, b.top + a.clientTop);
      bottom = Math.min(bottom, b.top + a.clientTop + a.clientHeight);
    }
    return JSON.stringify({ x: r.x, y: r.y, width: r.width, height: r.height, shown: Math.max(0, bottom - top), shownY: top + r.y - r.local.top });
    """

    /// After a tall screenshot: the view is back, so the scroll positions `shotStart` kept go back too.
    public static let shotEnd = """
    await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
    for (const [el, left, top] of globalThis.agwebShot?.scrolled ?? []) el.scrollTo({ left, top, behavior: 'instant' });
    delete globalThis.agwebShot;
    return 'ok';
    """

    /// Brings the element to the middle of the viewport unless all of it shows already, as Playwright's
    /// scrollIntoViewIfNeeded does, gliding there over a few hundred milliseconds when `smooth`. How much shows is
    /// the browser's own answer (an IntersectionObserver), so scroll containers and iframes clip it too. One bigger
    /// than the viewport counts as shown when part of it is, and goes to its start.
    public static let reveal = find + """
    const el = find(target);
    const r = rectOf(el);
    if (!r.width || !r.height) return 'no size';
    // A frozen page (window closed, minimized or hidden) runs no observers; then the box in the top viewport decides.
    const shown = () => new Promise((resolve) => {
      const io = new IntersectionObserver(([entry]) => { io.disconnect(); resolve(entry.intersectionRatio); });
      io.observe(el);
      setTimeout(() => {
        io.disconnect();
        const b = rectOf(el);
        const w = Math.max(0, Math.min(b.x + b.width, innerWidth) - Math.max(b.x, 0)), h = Math.max(0, Math.min(b.y + b.height, innerHeight) - Math.max(b.y, 0));
        resolve(w * h / (b.width * b.height || 1));
      }, 300);
    });
    const big = r.width > innerWidth || r.height > innerHeight;
    const enough = (ratio) => big ? ratio > 0 : ratio > 0.99;
    if (enough(await shown())) return 'already in view';
    // Every box that may scroll, out through shadow hosts and same-origin frames. Where an instant scroll leaves
    // each is where the glide ends. scrollTo with behavior 'instant' ignores the page's scroll-behavior: smooth.
    const boxes = new Set();
    for (let node = el; node; ) {
      boxes.add(node.ownerDocument.scrollingElement);
      const up = node.parentElement || node.getRootNode().host;
      if (up) { boxes.add(up); node = up; } else node = node.ownerDocument.defaultView.frameElement;
    }
    const from = [...boxes].filter(Boolean).map((box) => ({ box, x: box.scrollLeft, y: box.scrollTop }));
    el.scrollIntoView({ block: big ? 'start' : 'center', inline: big ? 'start' : 'center', behavior: 'instant' });
    const moves = from.map((m) => ({ ...m, x1: m.box.scrollLeft, y1: m.box.scrollTop })).filter((m) => m.x1 !== m.x || m.y1 !== m.y);
    if (smooth && moves.length) {
      const to = (m, e) => m.box.scrollTo({ left: m.x + (m.x1 - m.x) * e, top: m.y + (m.y1 - m.y) * e, behavior: 'instant' });
      for (const m of moves) to(m, 0);
      const far = Math.max(...moves.map((m) => Math.hypot(m.x1 - m.x, m.y1 - m.y)));
      const ms = Math.min(900, 250 + far / 4), start = performance.now();
      // A hidden tab gets no animation frames; the timer keeps the glide going there.
      const frame = () => new Promise((resolve) => { requestAnimationFrame(resolve); setTimeout(resolve, 50); });
      for (let t = 0; t < 1; ) {
        await frame();
        t = Math.min(1, (performance.now() - start) / ms);
        const eased = t < 0.5 ? 4 * t * t * t : 1 - (-2 * t + 2) ** 3 / 2;
        for (const m of moves) to(m, eased);
      }
    }
    return enough(await shown()) ? 'scrolled' : 'scrolled, but it is still not all in view: something clips or covers it';
    """

    /// Whether a checkbox, radio or ARIA switch is checked, or why it can't be.
    public static let checkedState = find + """
    const el = find(target);
    if (el.tagName === 'INPUT' && ['checkbox', 'radio'].includes(el.type)) return el.checked ? 'checked' : 'unchecked';
    if (['checkbox', 'radio', 'switch', 'menuitemcheckbox', 'menuitemradio'].includes(el.getAttribute('role'))) {
      return el.getAttribute('aria-checked') === 'true' ? 'checked' : 'unchecked';
    }
    const inner = el.querySelector?.('input[type=checkbox], input[type=radio]');
    if (inner) return inner.checked ? 'checked' : 'unchecked';
    return 'none';
    """

    /// Tags the element so a page-world script can find it; JS objects don't cross content worlds, DOM state does.
    public static let mark = find + """
    const el = find(target);
    const id = Math.random().toString(36).slice(2);
    el.setAttribute('data-agweb-target', id);
    return id;
    """

    public static let highlight = find + """
    const H = W.highlights || (W.highlights = new Map());
    const remove = (el) => { H.get(el)?.remove(); H.delete(el); };
    if (hide) {
      if (target) remove(find(target)); else { for (const box of H.values()) box.remove(); H.clear(); }
      return 'ok';
    }
    const el = find(target);
    remove(el);
    const r = rectOf(el);
    const box = document.createElement('div');
    box.style.cssText = `position:absolute;left:${r.x + scrollX - 2}px;top:${r.y + scrollY - 2}px;width:${r.width + 4}px;height:${r.height + 4}px;` +
      'box-sizing:border-box;border:2px solid #e0f;background:rgba(224,0,255,.12);pointer-events:none;z-index:2147483647;' + style;
    document.documentElement.appendChild(box);
    H.set(el, box);
    return 'ok';
    """

    /// For a recording's pointer: the cursor a person would see at `x`, `y` (CSS px in the top viewport), through open
    /// shadow roots and same-origin frames: "hand", "text" or "arrow". CSS `auto` resolves as WebKit does: a link's hand,
    /// an editable field's or selectable text's I-beam, else the arrow.
    public static let cursorAt = """
    let doc = document, px = x, py = y, el = doc.elementFromPoint(px, py);
    for (let i = 0; el && i < 50; i++) {
      const inner = el.shadowRoot?.elementFromPoint(px, py);
      if (inner && inner !== el && el.shadowRoot.contains(inner)) { el = inner; continue; }
      let d = null;
      if (el.tagName === 'IFRAME' || el.tagName === 'FRAME') { try { d = el.contentDocument; } catch {} }
      if (!d) break;
      const b = el.getBoundingClientRect();
      px -= b.left + el.clientLeft; py -= b.top + el.clientTop;
      doc = d; el = d.elementFromPoint(px, py);
    }
    if (!el) return 'arrow';
    const style = doc.defaultView.getComputedStyle(el);
    if (style.cursor === 'pointer') return 'hand';
    if (style.cursor === 'text' || style.cursor === 'vertical-text') return 'text';
    if (style.cursor !== 'auto') return 'arrow';
    let up = el;
    for (; up; up = up.parentElement ?? up.getRootNode().host) {
      if (['a', 'area'].includes(up.tagName.toLowerCase()) && (up.hasAttribute('href') || up.hasAttribute('xlink:href'))) return 'hand';
    }
    const typed = el.tagName === 'INPUT' && ['text', 'search', 'email', 'url', 'tel', 'password', 'number'].includes(el.type);
    if (el.isContentEditable || el.tagName === 'TEXTAREA' || typed) return el.matches(':disabled') ? 'arrow' : 'text';
    if ((style.userSelect || style.webkitUserSelect) === 'none') return 'arrow';
    // Text right under the point, not merely in the element: a paragraph's margin or a card's padding shows the arrow.
    const caret = doc.caretRangeFromPoint?.(px, py), node = caret?.startContainer;
    if (!node || node.nodeType !== 3 || !node.textContent.trim()) return 'arrow';
    // The characters either side of the caret, not the whole node: a long article's text node has thousands of line boxes.
    const range = doc.createRange();
    range.setStart(node, Math.max(0, caret.startOffset - 1));
    range.setEnd(node, Math.min(node.length, caret.startOffset + 1));
    for (const r of range.getClientRects()) if (px >= r.left && px <= r.right && py >= r.top && py <= r.bottom) return 'text';
    return 'arrow';
    """

    /// For wait: whether the target is on the page and visible (with `attached`, there at all), or with `gone`
    /// whether not; with `enabled`, see below. Several matches fail the wait, as they would fail the action after it, and so does a ref that
    /// is gone for good; with `gone` they count as present and gone.
    public static let present = find + """
    // With `enabled`, a present element that is disabled (natively, through its fieldset, or aria-disabled on it or
    // an ancestor) answers "disabled" instead.
    let present;
    try {
      const el = find(target);
      present = attached || visible(el);
      // :disabled on the element's own control, not a fieldset's: a link or a legend's control inside one still works.
      if (present && enabled && !gone && el.closest('button:disabled, input:disabled, select:disabled, textarea:disabled, [aria-disabled="true"]')) return 'disabled';
    } catch (e) {
      if (e.name === 'SyntaxError') throw new Error(e.message.startsWith('invalid selector') ? e.message : `invalid selector ${target}`);
      if (!gone && /take a new snapshot/.test(e.message)) throw e;
      present = /matches \\d+ elements/.test(e.message);
      if (present && !gone) throw e;
    }
    return String(gone ? !present : present);
    """

    public static let hasText = """
    // The page's text, then each shown open shadow root's (body.innerText leaves them out), then its same-origin
    // frames'. Only what is on screen: innerText of an element that isn't rendered is all its text, a <style>'s CSS
    // included, so hidden children, styles and hidden hosts are left out, as body.innerText leaves out hidden text.
    // A display:contents box (every <slot>) has no box of its own: it shows when what holds it does.
    const contents = (el) => getComputedStyle(el).display === 'contents';
    const shown = (el) => el.checkVisibility({ visibilityProperty: true }) || (contents(el) && !!(el.parentElement || el.getRootNode().host)
      && shown(el.parentElement || el.getRootNode().host));
    // innerText of a box-less element is its raw textContent, so one is read through: a slot's assigned nodes or its
    // fallback, a wrapper's children.
    const textOf = (n) => {
      if (n.nodeType === 3) return n.textContent;
      if (n.nodeType !== 1 || ['STYLE', 'SCRIPT', 'TEMPLATE'].includes(n.tagName)) return '';
      if (!contents(n)) return n.checkVisibility({ visibilityProperty: true }) ? n.innerText : '';
      const assigned = n.tagName === 'SLOT' ? n.assignedNodes({ flatten: true }) : [];
      return [...(assigned.length ? assigned : n.childNodes)].map(textOf).join(' ');
    };
    const shadows = function* (root) {
      for (const el of root.querySelectorAll('*')) {
        if (!el.shadowRoot || !shown(el)) continue;
        yield [...el.shadowRoot.childNodes].map(textOf).join(' ');
        yield* shadows(el.shadowRoot);
      }
    };
    const texts = function* (doc) {
      yield doc.body?.innerText ?? '';
      yield* shadows(doc);
      for (const f of doc.querySelectorAll('iframe, frame')) { let inner = null; try { inner = f.contentDocument; } catch {} if (inner) yield* texts(inner); }
    };
    for (const t of texts(document)) if (t.includes(text)) return 'true';
    return 'false';
    """

    /// Page world: loaded, and no fetch or XHR in flight.
    public static let quiet = """
    return String(document.readyState === 'complete' && !(window.__agwebPending > 0));
    """

    /// Page world: whether a fetch or XHR started at or after `since` (ms since 1970) is still in flight. Only the
    /// calls found on the `first` look count, or a long poll the page reopens after each answer would hold it.
    public static let busySince = """
    const inflight = window.__agwebInflight || new Set();
    if (first) window.__agwebSettling = [...inflight].filter(e => e.start >= since);
    return String((window.__agwebSettling || []).some(e => inflight.has(e)));
    """

    public static let focusedKind = """
    const e = document.activeElement;
    return !e ? '' : e.tagName === 'SELECT' ? 'select' : e.tagName === 'INPUT' ? (e.getAttribute('type') || 'text').toLowerCase() : '';
    """

    public static let viewport = """
    return JSON.stringify({ viewportWidth: innerWidth, viewportHeight: innerHeight });
    """

    // Links and images are draggable by default, and the element under the pointer may be one inside the target.
    public static let isDraggable = find + """
    const el = find(target);
    const r = el.getBoundingClientRect();
    const hit = el.ownerDocument.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
    const draggable = (e) => !!e && (e.draggable || !!e.closest('[draggable="true"]'));
    return String(draggable(el) || (el.contains(hit) && draggable(hit)));
    """

    public static let html5Drag = find + """
    const src = find(from), dst = find(to);
    const dataTransfer = new DataTransfer();
    const center = (e) => { const r = e.getBoundingClientRect(); return { clientX: r.left + r.width / 2, clientY: r.top + r.height / 2 }; };
    const fire = (e, type, at) => e.dispatchEvent(new DragEvent(type, { bubbles: true, cancelable: true, dataTransfer, ...at }));
    fire(src, 'dragstart', center(src));
    fire(dst, 'dragenter', center(dst));
    fire(dst, 'dragover', center(dst));
    fire(dst, 'drop', center(dst));
    fire(src, 'dragend', center(dst));
    return 'ok';
    """

    public static let jsClick = find + """
    find(target).click();
    return 'ok';
    """

    /// `select` passes `onlySelect`, so it fails on anything but a <select> instead of typing into it.
    public static let fill = find + """
    const el = find(target);
    const type = (el.getAttribute('type') || '').toLowerCase();
    if (onlySelect && el.tagName !== 'SELECT') throw new Error(`${el.tagName.toLowerCase()} is not a <select>; use fill or click`);
    if (el.tagName === 'INPUT' && ['checkbox', 'radio', 'file', 'submit', 'button', 'reset', 'image'].includes(type)) {
      throw new Error(type === 'file' ? 'use upload for file inputs' : ['checkbox', 'radio'].includes(type) ? `use check or uncheck for ${type} inputs` : `use click for ${type} inputs`);
    }
    if (!['INPUT', 'TEXTAREA', 'SELECT'].includes(el.tagName) && !el.isContentEditable) {
      throw new Error(`${el.tagName.toLowerCase()} is not a field; snapshot again and target the input inside it`);
    }
    el.focus();
    if (el.tagName === 'SELECT') {
      const option = [...el.options].find(o => o.value === text || o.label === text);
      if (!option) throw new Error(`no option ${text}; options: ${[...el.options].map(o => o.label).join(', ')}`);
      el.value = option.value;
      el.dispatchEvent(new Event('input', { bubbles: true }));
      // Left focused, a select opens its native menu on the next arrow key or space.
      el.blur();
    } else if (el.tagName === 'INPUT' && ['date', 'time', 'datetime-local', 'month', 'week', 'color', 'range', 'number'].includes(type)) {
      el.value = text;
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.blur();
    } else {
      if (el.select) el.select(); else el.ownerDocument.execCommand('selectAll');
      if (!(text ? el.ownerDocument.execCommand('insertText', false, text) : el.ownerDocument.execCommand('delete'))) {
        const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, text);
        el.dispatchEvent(new Event('input', { bubbles: true }));
      }
    }
    el.dispatchEvent(new Event('change', { bubbles: true }));
    if (secret) (W.secrets ||= new WeakSet()).add(el);
    return 'ok';
    """

    /// A rich editor's caret across a hand-back of the keyboard: WebKit clears the selection when the tab's view gives
    /// it up and, taking it again, restores a text field's but puts a contenteditable's caret at its start, so a
    /// background tab's typing came out backwards. `save` after a key, `restore` before the next, only if
    /// no other command (a click, fill or script that may move the caret) ran on the tab since (Tab.caretKept).
    public static let keepSelection = """
    const deep = (doc) => { const a = doc.activeElement; try { if ((a?.tagName === 'IFRAME' || a?.tagName === 'FRAME') && a.contentDocument) return deep(a.contentDocument); } catch {} return doc; };
    const doc = deep(document), el = doc.activeElement, sel = doc.getSelection();
    if (!el?.isContentEditable || !sel) return '';
    if (mode === 'save') {
      window.__agwebCaret = sel.rangeCount && el.contains(sel.getRangeAt(0).startContainer) ? sel.getRangeAt(0).cloneRange() : null;
    } else if (window.__agwebCaret && el.contains(window.__agwebCaret.startContainer)) {
      // WebKit moves the caret to the editor's start from a zero-delay timer after the tab takes the keyboard: after it.
      await new Promise(r => setTimeout(r, 0));
      sel.removeAllRanges();
      sel.addRange(window.__agwebCaret);
    }
    return '';
    """

    public static let insertText = """
    const focusedDocument = (doc) => { const a = doc.activeElement; try { if ((a?.tagName === 'IFRAME' || a?.tagName === 'FRAME') && a.contentDocument) return focusedDocument(a.contentDocument); } catch {} return doc; };
    if (!focusedDocument(document).execCommand('insertText', false, text)) throw new Error('no editable element is focused');
    return 'ok';
    """

    // Page world: arbitrary expression or function, result as JSON text. A function gets the element tagged by
    // `mark` (in the page, an open shadow root or a same-origin iframe, at any depth). The newline keeps a trailing line comment in `code` from
    // swallowing the closing parenthesis.
    public static func evaluate(_ code: String, mark: String? = nil) -> String {
        let element = mark.map { """
            const __sel = '[data-agweb-target="\($0)"]';
            const __find = (root) => {
              const hit = root.querySelector(__sel);
              if (hit) return hit;
              for (const el of root.querySelectorAll('*')) {
                let found;
                if (el.shadowRoot) found = __find(el.shadowRoot);
                if (!found && (el.tagName === 'IFRAME' || el.tagName === 'FRAME')) try { found = el.contentDocument && __find(el.contentDocument); } catch {}
                if (found) return found;
              }
            };
            const __el = __find(document);
            __el?.removeAttribute('data-agweb-target');
            """ } ?? "const __el = undefined;"
        return """
        \(element)
        const __value = (\(code)
        );
        const __result = typeof __value === 'function' ? await __value(__el) : await __value;
        if (__result === undefined) return 'undefined';
        return JSON.stringify(__result) ?? String(__result);
        """
    }

    // Page world, document start, every frame: reports fetch and XHR calls with their headers and text bodies (WebKit
    // has no network API), and answers the ones matching window.__agwebRoutes ({pattern, status, body, contentType,
    // headers}) itself. Routes are a page global so the app can change them on a live page.
    public static let networkHook = """
    (() => {
      if (window.__agwebNetwork) return;
      window.__agwebNetwork = true;
      // Calls in flight: their count for wait --load, their entries (with start times) for settling after an action.
      window.__agwebPending = 0;
      const inflight = window.__agwebInflight = new Set();
      const begin = (e) => { window.__agwebPending++; inflight.add(e); };
      const end = (e) => { window.__agwebPending = Math.max(0, window.__agwebPending - 1); inflight.delete(e); };
      const post = (m) => { try { window.webkit.messageHandlers.agwebPage.postMessage(m); } catch {} };
      const max = 65536;
      const cut = (s) => s == null ? null : s.length > max ? s.slice(0, max) + `… (${s.length} characters)` : s;
      const textual = (type) => !type || /json|text|xml|javascript|urlencoded|graphql/i.test(type);
      const bodyText = (b) => b == null ? null : typeof b === 'string' ? cut(b) : b instanceof URLSearchParams ? cut(b.toString())
        : b instanceof FormData ? cut([...b].map(([k, v]) => `${k}=${typeof v === 'string' ? v : `<file ${v.name}>`}`).join('&'))
        : `<${b.constructor?.name || typeof b}>`;
      const absolute = (u) => { try { return new URL(u, location.href).href; } catch { return String(u); } };
      // Playwright globs: ** crosses slashes, * does not, ? is literal.
      const glob = (p) => new RegExp('^' + p.replace(/[.+?^${}()|[\\]\\\\]/g, '\\\\$&').replace(/\\*\\*/g, '\\u0000').replace(/\\*/g, '[^/]*').replace(/\\u0000/g, '.*') + '$');
      const route = (url) => (window.__agwebRoutes || []).find(r => glob(r.pattern).test(url));
      const routedHeaders = (r) => { const h = new Headers(r.headers || {}); if (r.contentType) h.set('content-type', r.contentType); return h; };
      const nullBody = [101, 204, 205, 304];

      const fetch0 = window.fetch;
      window.fetch = async function (input, init = {}) {
        const req = input instanceof Request ? input : null;
        const entry = { kind: 'fetch', method: (init.method || req?.method || 'GET').toUpperCase(), url: absolute(req ? req.url : input),
                        requestHeaders: Object.fromEntries(new Headers(init.headers || req?.headers || {})), requestBody: bodyText(init.body), start: Date.now() };
        const r = route(entry.url);
        if (r) {
          const status = r.status || 200, headers = routedHeaders(r);
          post({ ...entry, status, statusText: 'routed', responseHeaders: Object.fromEntries(headers), responseBody: cut(r.body ?? ''), routed: true });
          return new Response(nullBody.includes(status) ? null : r.body ?? '', { status, headers });
        }
        begin(entry);
        try {
          const res = await fetch0.apply(this, arguments);
          const type = res.headers.get('content-type') || '';
          const done = (body) => post({ ...entry, status: res.status, statusText: res.statusText, responseHeaders: Object.fromEntries(res.headers), responseBody: body, duration: Date.now() - entry.start });
          if (textual(type)) res.clone().text().then(t => done(cut(t)), () => done(null)); else done(`<binary ${type}>`);
          return res;
        } catch (e) {
          post({ ...entry, failure: String(e) });
          throw e;
        } finally {
          end(entry);
        }
      };

      const X = XMLHttpRequest.prototype, open0 = X.open, send0 = X.send, header0 = X.setRequestHeader;
      X.open = function (method, url, ...rest) {
        this.__agweb = { kind: 'xhr', method: String(method).toUpperCase(), url: absolute(url), requestHeaders: {} };
        const r = route(this.__agweb.url);
        if (!r) return open0.call(this, method, url, ...rest);
        // A data: URL answers without the network; status and headers are overridden on this object.
        this.__agweb.route = r;
        const status = r.status || 200, headers = routedHeaders(r), list = [...headers].map(([k, v]) => `${k}: ${v}`).join('\\r\\n');
        Object.defineProperties(this, {
          status: { get: () => status }, statusText: { get: () => 'routed' },
          getResponseHeader: { value: (k) => headers.get(k) }, getAllResponseHeaders: { value: () => list },
        });
        return open0.call(this, 'GET', `data:${r.contentType || 'text/plain'};charset=utf-8,${encodeURIComponent(r.body ?? '')}`, ...rest);
      };
      X.setRequestHeader = function (k, v) { if (this.__agweb) this.__agweb.requestHeaders[k] = v; return header0.call(this, k, v); };
      X.send = function (body) {
        const entry = this.__agweb;
        if (entry) {
          entry.requestBody = bodyText(body);
          entry.start = Date.now();
          begin(entry);
          this.addEventListener('loadend', () => {
            end(entry);
            const { route: r, ...rest } = entry;
            const headers = Object.fromEntries(this.getAllResponseHeaders().trim().split(/[\\r\\n]+/).filter(Boolean).map(l => [l.slice(0, l.indexOf(':')).trim().toLowerCase(), l.slice(l.indexOf(':') + 1).trim()]));
            const type = this.responseType;
            const body = type === '' || type === 'text' ? cut(this.responseText) : type === 'json' ? cut(JSON.stringify(this.response)) : `<${type}>`;
            post({ ...rest, status: this.status, statusText: this.statusText, responseHeaders: headers, responseBody: body, duration: Date.now() - entry.start,
                   ...(r ? { routed: true } : {}), ...(this.status === 0 ? { failure: 'network error' } : {}) });
          });
        }
        return send0.call(this, body);
      };
    })();
    """

    /// Page world, main frame, document start: localStorage from `state-load` for origins that weren't open then.
    /// The app drops an origin once it reports it stored.
    public static func pendingStorage(_ json: String) -> String {
        """
        (() => {
          const items = (\(json))[location.origin];
          if (!items) return;
          for (const [k, v] of items) { try { localStorage.setItem(k, v); } catch {} }
          try { window.webkit.messageHandlers.agwebPage.postMessage({ stored: location.origin }); } catch {}
        })();
        """
    }

    /// Page world, document start, main frame: a reopened tab's sessionStorage, saved before a restart, put back
    /// before the page's scripts run, unless the tab already has some for the origin. Either way the origin is done.
    public static func seedSession(_ json: String) -> String {
        """
        (() => {
          const items = (\(json))[location.origin];
          if (!items) return;
          if (!sessionStorage.length) for (const [k, v] of Object.entries(items)) { try { sessionStorage.setItem(k, v); } catch {} }
          try { window.webkit.messageHandlers.agwebPage.postMessage({ seeded: location.origin }); } catch {}
        })();
        """
    }

    public static let readSession = """
    return JSON.stringify({ origin: location.origin, items: Object.fromEntries(Object.keys(sessionStorage).map(k => [k, sessionStorage.getItem(k)])) });
    """

    public static let readStorage = """
    return JSON.stringify({ origin: location.origin, items: Object.keys(localStorage).map(k => [k, localStorage.getItem(k)]) });
    """

    public static let writeStorage = """
    for (const [k, v] of items) localStorage.setItem(k, v);
    return 'ok';
    """

    // Page world, document start: forwards console output and uncaught errors to the app, without running page code.
    public static let consoleHook = """
    (() => {
      const handler = window.webkit?.messageHandlers?.agwebConsole;
      if (!handler) return;
      // Built-ins taken before the page's scripts run, so describing what a page logs never runs the page's code. A
      // native console.log touches nothing on its arguments; a page that puts a getter on an Error's stack and sees it
      // called knows a developer console is open, or that agweb is. Values behind getters show as [getter]. A Proxy's
      // traps can still see the look (accepted).
      const uncurry = Function.prototype.bind.bind(Function.prototype.call);
      const send = uncurry(handler.postMessage);
      const apply = Reflect.apply, descriptor = Object.getOwnPropertyDescriptor, protoOf = Object.getPrototypeOf;
      const ownKeys = Object.keys, isArray = Array.isArray, quote = JSON.stringify, toTag = Symbol.toStringTag;
      const isProto = uncurry(Object.prototype.isPrototypeOf), indexOf = uncurry(String.prototype.indexOf);
      const slice = uncurry(String.prototype.slice), iso = uncurry(Date.prototype.toISOString);
      const ErrorProto = Error.prototype, DateProto = Date.prototype, ErrorEventProto = ErrorEvent.prototype;
      const get = (proto, key) => uncurry(descriptor(proto, key).get);
      const eventMessage = get(ErrorEventProto, 'message'), eventFile = get(ErrorEventProto, 'filename');
      const eventLine = get(ErrorEventProto, 'lineno'), eventReason = get(PromiseRejectionEvent.prototype, 'reason');
      const GETTER = {};
      // A property's stored value, looked up through the prototypes without calling anything.
      const stored = (o, key) => {
        for (let p = o, i = 0; p && i < 32; p = protoOf(p), i++) {
          const d = descriptor(p, key);
          if (d) return 'value' in d ? d.value : GETTER;
        }
      };
      const nested = (v, depth) => v === GETTER ? '[getter]' : typeof v === 'string' ? quote(v) : describe(v, depth);
      const describe = (a, depth = 0) => {
        switch (typeof a) {
          case 'string': return a;
          case 'function': { const name = stored(a, 'name'); return '[function ' + (typeof name === 'string' && name ? name : '(anonymous)') + ']'; }
          case 'object': break;
          default: return String(a);
        }
        if (a === null) return 'null';
        if (isProto(ErrorProto, a)) {
          const name = stored(a, 'name'), message = stored(a, 'message'), stack = stored(a, 'stack');
          // WebKit's stack is only the frames, without V8's "TypeError: message" first line.
          const end = typeof stack === 'string' ? indexOf(stack, '\\n') : -1;
          const frame = typeof stack === 'string' && stack ? (end < 0 ? stack : slice(stack, 0, end)) : '';
          return (typeof name === 'string' ? name : 'Error') + ': ' + (typeof message === 'string' ? message : '') + (frame ? ' (at ' + frame + ')' : '');
        }
        if (isProto(DateProto, a)) { try { return iso(a); } catch { return 'Invalid Date'; } }
        if (isArray(a)) {
          if (depth > 2) return '[…]';
          const length = stored(a, 'length');
          let out = '[';
          for (let i = 0; i < length && i < 20; i++) out += (i ? ',' : '') + nested(stored(a, String(i)), depth + 1);
          return out + (length > 20 ? ',…]' : ']');
        }
        const tag = stored(a, toTag);
        if (typeof tag === 'string') return '[object ' + tag + ']';
        if (depth > 2) return '{…}';
        const keys = ownKeys(a);
        let out = '{';
        for (let i = 0; i < keys.length && i < 20; i++) {
          const d = descriptor(a, keys[i]);
          out += (i ? ',' : '') + quote(keys[i]) + ':' + nested(d && 'value' in d ? d.value : GETTER, depth + 1);
        }
        return out + (keys.length > 20 ? ',…}' : '}');
      };
      const post = (level, text) => { try { send(handler, level + ': ' + text); } catch {} };
      const join = (args) => {
        let out = '';
        for (let i = 0; i < args.length; i++) out += (i ? ' ' : '') + describe(args[i]);
        return out;
      };
      for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
        const original = console[level];
        console[level] = function (...args) { post(level, join(args)); return apply(original, this, args); };
      }
      // The event's own fields: the Error itself may carry a getter.
      addEventListener('error', e => {
        if (isProto(ErrorEventProto, e)) post('pageerror', eventMessage(e) + ' (at ' + eventFile(e) + ':' + eventLine(e) + ')');
      });
      addEventListener('unhandledrejection', e => post('pageerror', describe(eventReason(e))));
    })();
    """

    // Page world, document start, every frame. A page never writes the system clipboard itself: its writes go to the
    // app, which puts them on the person's clipboard after the person's click and on the workspace's own after an
    // agent's (ClipboardRouting.swift). Calls without a user gesture fail as WebKit's own do. Clipboard reads after an
    // agent's input get the workspace's clipboard; the person's still go to WebKit, which refuses them (Model.swift).
    // execCommand('copy'/'cut') becomes a synthetic copy event, whose data, or else the selection, is what was copied.
    public static let clipboardHook = """
    (() => {
      const handler = window.webkit?.messageHandlers?.agwebClipboard;
      if (!handler || window.__agwebShortcut) return;
      const ask = (message) => handler.postMessage(message);
      // Read now, before the page can replace navigator.userActivation.
      const activation = navigator.userActivation;
      const isActive = activation && Object.getOwnPropertyDescriptor(Object.getPrototypeOf(activation), 'isActive')?.get;
      const active = () => (isActive ? isActive.call(activation) : true);
      const denied = () => new DOMException('The request is not allowed by the user agent or the platform in the current context, possibly because the user denied permission.', 'NotAllowedError');
      const exec = Document.prototype.execCommand;
      const base64 = async (blob) => {
        const bytes = new Uint8Array(await blob.arrayBuffer());
        let s = '';
        for (let i = 0; i < bytes.length; i += 32768) s += String.fromCharCode(...bytes.subarray(i, i + 32768));
        return btoa(s);
      };
      // Items travel as [type, value, base64] triples.
      const send = async (items) => { if (await ask({ write: items }) !== 'ok') throw denied(); };
      // Only secure contexts have navigator.clipboard; execCommand('copy') works everywhere.
      const proto = window.Clipboard ? Clipboard.prototype : {};
      const { read, readText } = proto;
      proto.writeText = function (text) {
        if (!arguments.length) return Promise.reject(new TypeError('Not enough arguments'));
        if (!active()) return Promise.reject(denied());
        return send([['text/plain', String(text), false]]);
      };
      proto.write = function (items) {
        if (!Array.isArray(items)) return Promise.reject(new TypeError('Argument 1 must be a sequence of ClipboardItem'));
        if (!active()) return Promise.reject(denied());
        return (async () => {
          const out = [];
          const item = items[0];
          for (const type of item ? item.types : []) {
            const blob = await item.getType(type);
            out.push(type.startsWith('text/') ? [type, await blob.text(), false] : [type, await base64(blob), true]);
          }
          return send(out);
        })();
      };
      proto.readText = async function () {
        if (!active()) throw denied();
        const items = await ask({ read: true });
        if (!items) return readText.call(this);
        return items.find(i => i[0] === 'text/plain')?.[1] ?? '';
      };
      proto.read = async function () {
        if (!active()) throw denied();
        const items = await ask({ read: true });
        if (!items) return read.call(this);
        if (!items.length) return [];
        const parts = {};
        for (const [type, value, binary] of items) {
          parts[type] = new Blob([binary ? Uint8Array.from(atob(value), c => c.charCodeAt(0)) : value], { type });
        }
        return [new ClipboardItem(parts)];
      };
      // The focused element, through open shadow roots (a design system's input).
      const focused = () => {
        let el = document.activeElement;
        while (el && el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement;
        return el;
      };
      const field = (el) => el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement;
      // Where WebKit fires clipboard events: the focused field when the selection is in it (WebKit then reports the
      // document selection collapsed), else the start of the selection.
      const target = () => {
        const el = focused();
        const selection = getSelection();
        if (field(el) && (!selection || selection.isCollapsed)) return el;
        const node = selection && selection.rangeCount ? selection.getRangeAt(0).startContainer : null;
        return (node && (node.nodeType === 1 ? node : node.parentElement)) || el || document.body || document.documentElement;
      };
      const copy = (cut) => {
        const at = target();
        const data = new DataTransfer();
        const event = new ClipboardEvent(cut ? 'cut' : 'copy', { clipboardData: data, bubbles: true, cancelable: true, composed: true });
        at.dispatchEvent(event);
        let items = [];
        if (event.defaultPrevented) {
          items = data.types.filter(t => t !== 'Files').map(t => [t, data.getData(t), false]);
        } else if (!(at instanceof HTMLInputElement && at.type === 'password')) {
          // WebKit's selection text covers a focused field's selection too, email and number fields included.
          const selection = getSelection();
          const text = selection ? String(selection) : '';
          if (text) {
            items = [['text/plain', text, false]];
            if (!selection.isCollapsed && selection.rangeCount) {
              const box = document.createElement('div');
              box.append(selection.getRangeAt(0).cloneContents());
              items.push(['text/html', box.innerHTML, false]);
            }
            const editable = field(at) ? !at.readOnly && !at.disabled : at.isContentEditable;
            if (cut && editable) exec.call(document, 'delete');
          }
        }
        if (items.length) ask({ write: items }).catch(() => {});
        return true;
      };
      Document.prototype.execCommand = function (command, ...rest) {
        const name = String(command).toLowerCase();
        if (name !== 'copy' && name !== 'cut') return exec.call(this, command, ...rest);
        // Another frame's document goes through that frame's own hook; a document without a window can't copy.
        if (this !== document) return this.defaultView ? this.defaultView.document.execCommand(command, ...rest) : false;
        return active() ? copy(name === 'cut') : false;
      };
      // An agent's ⌘A, ⌘C, ⌘X or ⌘V (agweb press): WebKit edits only on a person's key equivalent, so agweb does it
      // after the key, unless the page's own keydown handler took it.
      let lastKey = null;
      addEventListener('keydown', (e) => { lastKey = e; }, true);
      Object.defineProperty(window, '__agwebShortcut', { value: (key, items) => {
        const pressed = lastKey;
        lastKey = null;
        if (!active()) return 'denied';
        if (pressed && pressed.metaKey && pressed.key.toLowerCase() === key && pressed.defaultPrevented) return 'key';
        if (key === 'a') { exec.call(document, 'selectAll'); return 'selected'; }
        if (key === 'c' || key === 'x') { copy(key === 'x'); return 'copied'; }
        const data = new DataTransfer();
        for (const [type, value, binary] of items) if (!binary) data.setData(type, value);
        const event = new ClipboardEvent('paste', { clipboardData: data, bubbles: true, cancelable: true, composed: true });
        target().dispatchEvent(event);
        if (event.defaultPrevented) return 'page';
        const text = items.find(i => i[0] === 'text/plain')?.[1];
        return text != null && exec.call(document, 'insertText', false, text) ? 'pasted' : 'nowhere';
      } });
    })();
    """

    /// Runs the clipboard hook's shortcut in the focused frame; "none" when the frame has no hook (a page that
    /// loaded before agweb knew to add it).
    public static let shortcut = """
    return window.__agwebShortcut ? window.__agwebShortcut(key, items) : 'none';
    """

    /// Page world, every frame, before the page's scripts: passkey requests (`navigator.credentials` with `publicKey`)
    /// go to agweb's own authenticator, which checks the origin natively; other credential kinds go to WebKit.
    public static let passkeyShim = #"""
    (() => {
      const handler = window.webkit?.messageHandlers?.agwebPasskey;
      if (!handler || !window.CredentialsContainer || !window.PublicKeyCredential) return;
      const post = handler.postMessage.bind(handler);
      const proto = CredentialsContainer.prototype;
      const native = { create: proto.create, get: proto.get };
      const toString = Object.prototype.toString;
      const isBuffer = (v) => ArrayBuffer.isView(v) || toString.call(v) === '[object ArrayBuffer]';
      const bytes = (v) => ArrayBuffer.isView(v) ? new Uint8Array(v.buffer, v.byteOffset, v.byteLength) : new Uint8Array(v);
      const b64u = (v) => { let s = ''; for (const c of bytes(v)) s += String.fromCharCode(c); return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, ''); };
      const buffer = (s) => { const bin = atob(s.replace(/-/g, '+').replace(/_/g, '/')); const out = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i); return out.buffer; };
      const plain = (v) => isBuffer(v) ? b64u(v) : Array.isArray(v) ? v.map(plain)
        : v && typeof v === 'object' ? Object.fromEntries(Object.entries(v).map(([k, x]) => [k, plain(x)])) : v;
      const define = (o, props) => { for (const [k, v] of Object.entries(props)) Object.defineProperty(o, k, { value: v, enumerable: true }); return o; };
      const aborted = (signal) => signal.reason ?? new DOMException('The operation was aborted.', 'AbortError');
      // A security key's reply names its algorithm, transport and attachment; agweb's own passkeys leave them out.
      const credential = (r, create) => {
        const ext = { ...r.extensions, ...(r.credProps ? { credProps: r.rk === undefined ? {} : { rk: r.rk } } : {}) };
        const alg = r.algorithm ?? -7, transports = r.transports ?? ['internal'], attachment = r.attachment ?? 'platform';
        const response = Object.create(((create ? window.AuthenticatorAttestationResponse : window.AuthenticatorAssertionResponse) || Object).prototype);
        let json;
        if (create) {
          define(response, { clientDataJSON: buffer(r.clientDataJSON), attestationObject: buffer(r.attestationObject),
            getAuthenticatorData: () => buffer(r.authenticatorData), getPublicKey: () => r.publicKey ? buffer(r.publicKey) : null,
            getPublicKeyAlgorithm: () => alg, getTransports: () => [...transports] });
          json = { clientDataJSON: r.clientDataJSON, attestationObject: r.attestationObject, authenticatorData: r.authenticatorData,
            publicKey: r.publicKey, publicKeyAlgorithm: alg, transports };
        } else {
          define(response, { clientDataJSON: buffer(r.clientDataJSON), authenticatorData: buffer(r.authenticatorData),
            signature: buffer(r.signature), userHandle: r.userHandle ? buffer(r.userHandle) : null });
          json = { clientDataJSON: r.clientDataJSON, authenticatorData: r.authenticatorData, signature: r.signature, userHandle: r.userHandle ?? undefined };
        }
        return define(Object.create(PublicKeyCredential.prototype), { id: r.id, rawId: buffer(r.id), type: 'public-key',
          authenticatorAttachment: attachment, response, getClientExtensionResults: () => ({ ...ext }),
          toJSON: () => ({ id: r.id, rawId: r.id, type: 'public-key', authenticatorAttachment: attachment, clientExtensionResults: { ...ext }, response: json }) });
      };
      // One request at a time, as in browsers: a double click must not create a second passkey that replaces the first.
      let pending = false;
      const ceremony = (kind, options) => {
        const signal = options.signal;
        if (signal?.aborted) return Promise.reject(aborted(signal));
        // Autofill passkeys: nothing is offered by itself, so the request waits until the page aborts it.
        if (options.mediation === 'conditional') {
          if (kind === 'create') return Promise.reject(new DOMException('agweb creates passkeys only on request', 'NotAllowedError'));
          return new Promise((_, reject) => signal?.addEventListener('abort', () => reject(aborted(signal)), { once: true }));
        }
        if (pending) return Promise.reject(new DOMException('A request is already pending.', 'NotAllowedError'));
        pending = true;
        return new Promise((resolve, reject) => {
          let done = false;
          // An abort also stops a security key waiting for the person.
          signal?.addEventListener('abort', () => { if (!done) { done = true; reject(aborted(signal)); post({ kind: 'cancel' }).catch(() => {}); } }, { once: true });
          const publicKey = plain(options.publicKey);
          const answered = post({ kind, publicKey, credProps: !!options.publicKey.extensions?.credProps });
          const free = () => { pending = false; };
          answered.then(free, free);
          answered.then((r) => {
            if (done) return;
            done = true;
            if (r?.error) reject(new DOMException(r.error.message, r.error.name)); else resolve(credential(r.credential, kind === 'create'));
          }, (e) => { if (!done) { done = true; reject(new DOMException(String(e?.message ?? e), 'NotAllowedError')); } });
        });
      };
      for (const kind of ['create', 'get']) {
        Object.defineProperty(proto, kind, { configurable: true, writable: true, value: { [kind](options) {
          return options?.publicKey ? ceremony(kind, options) : native[kind].apply(this, arguments);
        } }[kind] });
      }
      const statics = {
        isUserVerifyingPlatformAuthenticatorAvailable: () => Promise.resolve(true),
        isConditionalMediationAvailable: () => Promise.resolve(false),
        getClientCapabilities: () => Promise.resolve({ conditionalCreate: false, conditionalGet: false, hybridTransport: false,
          passkeyPlatformAuthenticator: true, userVerifyingPlatformAuthenticator: true, relatedOrigins: false,
          signalAllAcceptedCredentials: false, signalCurrentUserDetails: false, signalUnknownCredential: false }),
      };
      for (const [k, v] of Object.entries(statics)) Object.defineProperty(PublicKeyCredential, k, { configurable: true, writable: true, value: v });
    })();
    """#

    /// Page world, every frame, only in a workspace with `agweb media` or `agweb geolocation` set: fake devices the
    /// app answers for (FakeDevices, message handler agwebDevices), each part guarded, so a live page given the script
    /// again gets only the parts it lacks. Replaced functions take the name, length and enumerability of the ones they
    /// replace, so a page sees the same shapes as in Safari.
    public static func devicesShim(media: Bool, geolocation: Bool) -> String {
        "(() => {\n" + devicesShared + (media ? mediaPart : "") + (geolocation ? geolocationPart : "") + permissionsPart + "})();"
    }

    private static let devicesShared = #"""
      const handler = window.webkit?.messageHandlers?.agwebDevices;
      if (!handler) return;
      const once = (name) => { const mark = Symbol.for('agweb.' + name); if (window[mark]) return false; Object.defineProperty(window, mark, { value: true }); return true; };
      // Looked up on each call: the app removes the handler when the workspace stops faking, and adds a new one back.
      const post = async (m) => window.webkit.messageHandlers.agwebDevices.postMessage(m);
      const fail = (name, message) => new DOMException(message, name);
      // Name and length as the replaced function's. Function.prototype.toString is left alone: replacing it makes every
      // function on the page look tampered with (CreepJS: hasToStringProxy, and webdriver flagged as a lie), and a
      // Proxy prints as "function ProxyObject()" in JavaScriptCore.
      const dress = (f, original, name, length) => {
        Object.defineProperty(f, 'name', { value: original?.name ?? name });
        Object.defineProperty(f, 'length', { value: original?.length ?? length });
        return f;
      };
      const patch = (o, name, fn, length = 0) => {
        const was = Object.getOwnPropertyDescriptor(o, name);
        const f = dress({ [name](...args) { return fn.apply(this, args); } }[name], was?.value, name, length);
        Object.defineProperty(o, name, { configurable: true, writable: true, enumerable: was?.enumerable ?? true, value: f });
      };
      const getter = (o, name, get, set) => {
        const was = Object.getOwnPropertyDescriptor(o, name);
        const d = Object.getOwnPropertyDescriptor({ get [name]() { return get.call(this); }, set [name](v) { set?.call(this, v); } }, name);
        Object.defineProperty(o, name, { configurable: true, enumerable: was?.enumerable ?? true, get: dress(d.get, was?.get, 'get ' + name, 0),
          ...(set ? { set: dress(d.set, was?.set, 'set ' + name, 1) } : {}) });
      };

    """#

    /// getUserMedia answers with the workspace's files, looped, instead of real devices. WKWebView has no
    /// navigator.mediaDevices without camera and microphone usage strings, so this provides one. The camera is the
    /// clip's H.264 samples decoded with WebCodecs into a canvas (canvas.captureStream); the microphone is the file's
    /// audio decoded into a looping Web Audio source, so nothing reaches the speakers. Neither loads a URL, so a page's
    /// Content-Security-Policy can't block them. Device names and ids look like Safari's (ids hashed per origin by the
    /// app); the app hands over only the files set for the workspace, so a page can't name a path.
    private static let mediaPart = #"""
      if (isSecureContext && window.MediaDevices && window.MediaStreamTrack && HTMLCanvasElement.prototype.captureStream && once('media')) {
        const kinds = { videoinput: 'camera', audioinput: 'mic' };
        const bytes = (b64) => {
          if (Uint8Array.fromBase64) return Uint8Array.fromBase64(b64);
          const bin = atob(b64), out = new Uint8Array(bin.length);
          for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
          return out;
        };
        const number = (c, name) => { const v = c?.[name]; return typeof v === 'number' ? v : v?.exact ?? v?.ideal ?? v?.max; };
        // Each getUserMedia call gets its own player; it stops once every track from it (clones included) has stopped.
        // `held` keeps each track's JS object alive: once collected, stream.getTracks() makes a new one, which the
        // WeakMap doesn't know, and the page would see the canvas track's own label ("CanvasCaptureMediaStreamTrack").
        const fakes = new WeakMap(), held = new Set();
        const own = (track, info, pipe) => { pipe.live++; fakes.set(track, { ...info, pipe }); held.add(track); return track; };

        // WebCodecs, not a <video>: a media element needs a blob: URL, which a page's CSP (media-src) may refuse.
        const cameraTrack = async (clip, device, c, pipe) => {
          const unreadable = (why) => fail('NotReadableError', `agweb can't play the camera file ${clip.name}: ${why}`);
          if (!window.VideoDecoder) throw unreadable('this WebKit has no WebCodecs');
          const data = bytes(clip.data);
          const config = { codec: clip.codec, description: bytes(clip.description), codedWidth: clip.width, codedHeight: clip.height };
          if (!(await VideoDecoder.isConfigSupported(config)).supported) throw unreadable(`${clip.codec} is not supported`);
          const canvas = document.createElement('canvas');
          canvas.width = clip.width; canvas.height = clip.height;
          const g = canvas.getContext('2d');
          // Decoded frames wait in `ready` until their time comes; the clip loops by flushing and starting over.
          const ready = [];
          let on = true, loop = 0, fed = 0, flushing = false, timer = 0;
          const decoder = new VideoDecoder({ output: (f) => { if (on) ready.push({ f, at: loop * clip.duration + f.timestamp }); else f.close(); },
                                             error: () => { on = false; } });
          decoder.configure(config);
          const feed = () => {
            while (on && !flushing && decoder.decodeQueueSize + ready.length < 6) {
              if (fed === clip.samples.length) {
                flushing = true;
                decoder.flush().then(() => { loop++; fed = 0; flushing = false; feed(); }, () => {});
                return;
              }
              const [timestamp, key, offset, size, duration] = clip.samples[fed++];
              decoder.decode(new EncodedVideoChunk({ type: key ? 'key' : 'delta', timestamp, duration, data: data.subarray(offset, offset + size) }));
            }
          };
          let start = performance.now(), last = start;
          const tick = () => {
            if (!on) return;
            // A throttled or suspended tab: the clip pauses for the gap instead of racing through the frames it missed.
            const t = performance.now();
            // Over 2 s, not the ~1 s ticks of a throttled hidden page, which would freeze the picture instead.
            if (t - last > 2000) start += t - last;
            last = t;
            const now = (t - start) * 1000;
            let frame = null;
            // Behind (a throttled background tab): skip to the latest frame due.
            while (ready.length && ready[0].at <= now) { frame?.close(); frame = ready.shift().f; }
            if (frame) { g.drawImage(frame, 0, 0); frame.close(); }
            feed();
            timer = setTimeout(tick, 10);
          };
          feed();
          tick();
          const fps = number(c, 'frameRate') || Math.round(clip.samples.length * 1e6 / clip.duration) || 30;
          pipe.stops.push(() => { on = false; clearTimeout(timer); if (decoder.state !== 'closed') decoder.close(); ready.forEach((r) => r.f.close()); ready.length = 0; });
          return own(canvas.captureStream(fps).getVideoTracks()[0], { device,
            settings: { width: canvas.width, height: canvas.height, frameRate: fps, aspectRatio: canvas.width / canvas.height, facingMode: 'user' } }, pipe);
        };

        const micTrack = async (file, device, pipe) => {
          const ctx = new AudioContext();
          let buffer;
          try { buffer = await ctx.decodeAudioData(bytes(file.data).buffer); } catch (e) {
            ctx.close();
            throw fail('NotReadableError', `agweb could not decode the microphone file ${file.name}`);
          }
          const source = ctx.createBufferSource();
          source.buffer = buffer; source.loop = true;
          const out = ctx.createMediaStreamDestination();
          source.connect(out);
          source.start();
          ctx.resume().catch(() => {});
          pipe.stops.push(() => { source.stop(); ctx.close(); });
          return own(out.stream.getAudioTracks()[0], { device,
            settings: { sampleRate: ctx.sampleRate, channelCount: buffer.numberOfChannels, echoCancellation: false, autoGainControl: false, noiseSuppression: false } }, pipe);
        };

        const T = MediaStreamTrack.prototype;
        const native = { label: Object.getOwnPropertyDescriptor(T, 'label').get, getSettings: T.getSettings, getCapabilities: T.getCapabilities,
                         stop: T.stop, clone: T.clone };
        getter(T, 'label', function () { return fakes.get(this)?.device.label ?? native.label.call(this); });
        patch(T, 'getSettings', function () {
          const fake = fakes.get(this), base = native.getSettings.call(this);
          return fake ? { ...base, ...fake.settings, deviceId: fake.device.id, groupId: fake.device.group } : base;
        });
        patch(T, 'getCapabilities', function () {
          const fake = fakes.get(this);
          return fake ? { deviceId: fake.device.id, groupId: fake.device.group } : native.getCapabilities?.call(this) ?? {};
        });
        patch(T, 'stop', function () {
          const fake = fakes.get(this), live = this.readyState === 'live';
          native.stop.call(this);
          // Emptied after: the closures hold the clip's bytes, and `held` keeps the track (and so the pipe) alive.
          if (fake && live && --fake.pipe.live === 0) { fake.pipe.stops.forEach((stop) => stop()); fake.pipe.stops.length = 0; }
        });
        patch(T, 'clone', function () {
          const copy = native.clone.call(this), fake = fakes.get(this);
          return fake && this.readyState === 'live' ? own(copy, fake, fake.pipe) : copy;
        });

        const deviceInfo = (kind, d) => {
          const props = { deviceId: d.id, kind, label: d.label, groupId: d.group };
          const o = Object.create((window.InputDeviceInfo || window.MediaDeviceInfo).prototype);
          for (const [k, v] of Object.entries(props)) Object.defineProperty(o, k, { value: v, enumerable: true });
          Object.defineProperty(o, 'toJSON', { value: () => ({ ...props }) });
          Object.defineProperty(o, 'getCapabilities', { value: () => ({ deviceId: d.id, groupId: d.group }) });
          return o;
        };
        const M = MediaDevices.prototype;
        patch(M, 'getUserMedia', async (constraints) => {
          const video = constraints?.video, audio = constraints?.audio;
          if (!video && !audio) throw new TypeError('At least one of audio and video must be requested');
          const r = await post({ camera: !!video, mic: !!audio }).catch(() => ({ error: { name: 'NotFoundError', message: 'Requested device not found' } }));
          if (r?.error) throw fail(r.error.name, r.error.message);
          const pipe = { live: 0, stops: [] };
          try {
            const tracks = [];
            if (video) tracks.push(await cameraTrack(r.camera, r.devices.camera, video, pipe));
            if (audio) tracks.push(await micTrack(r.mic, r.devices.mic, pipe));
            // The app keeps a capturing tab awake, as Safari does, until every track from this call has stopped.
            post({ capturing: 1 }).catch(() => {});
            pipe.stops.push(() => post({ capturing: -1 }).catch(() => {}));
            return new MediaStream(tracks);
          } catch (e) { pipe.stops.forEach((stop) => stop()); throw e; }
        });
        patch(M, 'enumerateDevices', async () => {
          const { devices } = await post({ info: true }).catch(() => ({ devices: {} }));
          return Object.entries(kinds).filter(([, key]) => devices[key]).map(([kind, key]) => deviceInfo(kind, devices[key]));
        });
        patch(M, 'getSupportedConstraints', () => ({ aspectRatio: true, deviceId: true, echoCancellation: true, facingMode: true, frameRate: true,
          groupId: true, height: true, sampleRate: true, sampleSize: true, volume: true, width: true, displaySurface: true }));
        patch(M, 'getDisplayMedia', () => Promise.reject(fail('NotAllowedError', 'The request is not allowed by the user agent or the platform in the current context, possibly because the user denied permission.')));
        let ondevicechange = null;
        getter(M, 'ondevicechange', () => ondevicechange, (v) => { ondevicechange = v; });
        if (!navigator.mediaDevices) {
          // A real EventTarget, so addEventListener works, that is a MediaDevices to instanceof.
          const mediaDevices = Object.setPrototypeOf(new EventTarget(), M);
          getter(Navigator.prototype, 'mediaDevices', () => mediaDevices);
        }
      }

    """#

    /// navigator.geolocation answers with the workspace's position; watchPosition sees a change within a second.
    private static let geolocationPart = #"""
      if (window.Geolocation && window.GeolocationPosition && once('geolocation')) {
        const define = (o, props) => {
          for (const [k, v] of Object.entries(props)) Object.defineProperty(o, k, { value: v, enumerable: true });
          Object.defineProperty(o, 'toJSON', { value: () => JSON.parse(JSON.stringify(props)) });
          return o;
        };
        const position = (p) => define(Object.create(GeolocationPosition.prototype), {
          coords: define(Object.create(GeolocationCoordinates.prototype), { latitude: p.latitude, longitude: p.longitude, altitude: null,
            accuracy: p.accuracy, altitudeAccuracy: null, heading: null, speed: null }),
          timestamp: Date.now() });
        const denied = () => define(Object.create(GeolocationPositionError.prototype), { code: 1, message: 'User denied Geolocation' });
        const where = async () => (await post({ geolocation: true }).catch(() => null))?.geolocation;
        const answer = (p, success, failure) => { if (p) success(position(p)); else failure?.(denied()); };
        const G = Geolocation.prototype;
        patch(G, 'getCurrentPosition', function (success, failure) {
          if (typeof success !== 'function') throw new TypeError("Argument 1 ('successCallback') to Geolocation.getCurrentPosition must be a function");
          where().then((p) => answer(p, success, failure));
        }, 1);
        const watches = new Map();
        let nextWatch = 1;
        patch(G, 'watchPosition', function (success, failure) {
          if (typeof success !== 'function') throw new TypeError("Argument 1 ('successCallback') to Geolocation.watchPosition must be a function");
          const id = nextWatch++;
          let last;
          const poll = async () => {
            const p = await where();
            if (!watches.has(id)) return;
            const seen = JSON.stringify(p ?? null);
            if (seen !== last) { last = seen; answer(p, success, failure); }
            watches.set(id, setTimeout(poll, 1000));
          };
          watches.set(id, 0);
          poll();
          return id;
        }, 1);
        patch(G, 'clearWatch', function (id) { clearTimeout(watches.get(id)); watches.delete(id); }, 1);
      }

    """#

    /// navigator.permissions says granted for what the workspace fakes, denied for the rest of these three.
    private static let permissionsPart = #"""
      if (window.Permissions && window.PermissionStatus && once('permissions')) {
        const query = Permissions.prototype.query, state = Object.getOwnPropertyDescriptor(PermissionStatus.prototype, 'state')?.get;
        const states = new WeakMap();
        if (state) {
          patch(Permissions.prototype, 'query', async function (descriptor) {
            const status = await query.apply(this, arguments);
            const key = { camera: 'camera', microphone: 'mic', geolocation: 'geolocation' }[descriptor?.name];
            const set = key && await post({ info: true }).catch(() => null);
            if (set) states.set(status, set[key] ? 'granted' : 'denied');
            return status;
          }, 1);
          getter(PermissionStatus.prototype, 'state', function () { return states.get(this) ?? state.call(this); });
        }
      }
    """#
}
