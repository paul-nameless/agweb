// Function bodies for callAsyncJavaScript. They run in the isolated "agweb" content world, which shares the DOM
// with the page but not its globals, so the page cannot see or clobber window.__agweb.
public enum PageScripts {
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
    const clean = (s) => (s || '').replace(/\\s+/g, ' ').trim().slice(0, 120);
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
    const nameOf = (el, role = roleOf(el)) => {
      const root = el.getRootNode();
      // Without aria-hidden parts: a required "*" and icon ligatures ("help") are not part of a name.
      const spoken = (n) => n.nodeType === 3 ? n.textContent : n.nodeType !== 1 || n.getAttribute('aria-hidden') === 'true' ? ''
        : [...n.childNodes].map(spoken).join(' ');
      const labelledBy = (el.getAttribute('aria-labelledby') || '').split(/\\s+/)
        .map(id => id && root.getElementById?.(id) || el.ownerDocument.getElementById(id)).filter(Boolean).map(spoken).join(' ');
      const button = el.tagName === 'INPUT' && ['submit', 'button', 'reset'].includes(el.type);
      return clean(
        labelledBy || el.getAttribute('aria-label') || el.labels?.[0]?.innerText || el.getAttribute('alt') ||
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
    const find = (target) => {
      if (/^e\\d+$/.test(target)) {
        const el = W.refs.get(target)?.deref();
        // An element of an iframe that navigated away stays connected to its old document, which has no window.
        if (!el || !el.isConnected || !el.ownerDocument.defaultView) throw new Error(`ref ${target} not found: the page changed; take a new snapshot`);
        return el;
      }
      let matches, m;
      if ((m = /^role=([\\w-]+)(?:\\[name=(?:"([^"]*)"|'([^']*)'|([^\\]]*))\\])?$/.exec(target))) {
        const role = m[1], name = (m[2] ?? m[3] ?? m[4])?.toLowerCase();
        matches = [...all(document)].filter(el => roleOf(el) === role && visible(el) && (name === undefined || nameOf(el).toLowerCase().includes(name)));
      } else if (target.startsWith('text=')) {
        // Not clean(): its 120-character cut would hide the end of a long paragraph.
        const whole = (s) => (s || '').replace(/\\s+/g, ' ').trim();
        const raw = target.slice(5), exact = /^".*"$/.test(raw), text = exact ? whole(raw.slice(1, -1)) : whole(raw).toLowerCase();
        const has = (el) => {
          if (!(el.textContent || '').toLowerCase().includes(exact ? text.toLowerCase() : text)) return false;
          const t = whole(el.innerText);
          return exact ? t === text : t.toLowerCase().includes(text);
        };
        // The innermost elements holding the text, not every ancestor of them.
        matches = [...all(document)].filter(el => !['SCRIPT', 'STYLE', 'HEAD', 'TITLE'].includes(el.tagName) && has(el) && visible(el) && ![...el.children].some(has));
      } else {
        const el = document.querySelector(target);
        if (!el) throw new Error(`no element matches ${target}`);
        return el;
      }
      const label = (el) => `${roleOf(el) || el.tagName.toLowerCase()} ${JSON.stringify(nameOf(el) || clean(el.innerText).slice(0, 40))} [ref=${refOf(el)}]`;
      const list = (els) => els.slice(0, 5).map(label).join('; ') + (els.length > 5 ? `; and ${els.length - 5} more` : '');
      if (matches.length === 0) {
        // A near miss: the elements of that role and their names, so the next try needs no snapshot.
        const role = m && target.startsWith('role=') ? m[1] : null;
        const near = role ? [...all(document)].filter(el => roleOf(el) === role && visible(el)) : [];
        throw new Error(`no visible element matches ${target}` + (near.length ? `; visible ${role}s: ${list(near)}` : ''));
      }
      if (matches.length > 1) {
        const listed = list(matches);
        throw new Error(`${target} matches ${matches.length} elements: ${listed}. Be more specific or use a ref from snapshot`);
      }
      return matches[0];
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

    /// The whole page, or with `target` only that element and what is inside it.
    public static let snapshot = find + """
    const root = target ? find(target) : null;
    for (const [ref, weak] of W.refs) if (!weak.deref()) W.refs.delete(ref);
    const lines = [];
    let truncated = false;
    const skip = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'svg', 'HEAD']);
    const leaf = new Set(['link', 'button', 'textbox', 'searchbox', 'combobox', 'checkbox', 'radio', 'slider', 'heading', 'img', 'switch', 'tab', 'menuitem', 'option',
      'cell', 'gridcell', 'columnheader', 'rowheader', 'generic']);
    const emit = (line) => {
      if (lines.length >= \(maxSnapshotLines)) { truncated = true; return false; }
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
      if (!role) { walk(node, depth); return; }
      const ref = refOf(node);
      let line = `${'  '.repeat(depth)}- ${role}`;
      // A container's text shows as its children, so only a leaf is named by its content.
      const name = nameOf(node, leaf.has(role) ? role : null);
      if (name) line += ` ${JSON.stringify(name)}`;
      if (role === 'heading') line += ` [level=${/^H[1-6]$/.test(node.tagName) ? node.tagName[1] : node.getAttribute('aria-level') || 2}]`;
      if (node.checked || node.getAttribute('aria-checked') === 'true') line += ' [checked]';
      if (node.getAttribute('aria-selected') === 'true') line += ' [selected]';
      if (node.getAttribute('aria-expanded') === 'true') line += ' [expanded]';
      if (node.disabled) line += ' [disabled]';
      // A password someone typed by hand must not reach an agent's transcript.
      if (node.type === 'password' || W.secrets?.has(node)) { if (node.value) line += ' [value=<hidden>]'; }
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
      if (node.tagName === 'SELECT') {
        for (const option of node.options) {
          emit(`${'  '.repeat(depth + 1)}- option ${JSON.stringify(clean(option.label))}${option.selected ? ' [selected]' : ''}`);
        }
      } else {
        walk(node, depth + 1, leaf.has(role));
      }
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
      if (controlRole(node)) { yield node; return; }
      for (const child of childrenOf(node)) yield* roled(child);
    };
    if (root) visit(root, 0); else walk(document.body || document.documentElement, 0);
    if (truncated) lines.push(`- (truncated at \(maxSnapshotLines) lines; use eval to read the rest)`);
    return JSON.stringify({ tree: lines.join('\\n'), next: W.next, doc: W.doc });
    """

    /// Markdown through Defuddle (loaded into this world first): one element converted whole, or the page's main
    /// content. A page with little article in it (a web app) is converted whole instead.
    public static let text = find + """
    const reply = (markdown, whole = false) => JSON.stringify({ markdown, whole });
    if (target) return reply(Defuddle.createMarkdownContent(find(target).outerHTML, location.href));
    const page = new Defuddle(document, { markdown: true, url: location.href }).parse();
    if (page.wordCount < 50) return reply(Defuddle.createMarkdownContent(document.body.innerHTML, location.href), true);
    return reply((page.title ? `# ${page.title}\\n\\n` : '') + page.content);
    """

    // Returns the element's center in CSS pixels (`reveal` brings it into view first), what actually sits there, and
    // what kind of control it is (some controls open native popups when clicked).
    public static let locate = find + """
    const el = find(target);
    const r = rectOf(el);
    const lx = r.local.left + r.width / 2, ly = r.local.top + r.height / 2;
    const hit = el.getRootNode().elementFromPoint?.(lx, ly) ?? el.ownerDocument.elementFromPoint(lx, ly);
    const covered = hit && hit !== el && !el.contains(hit) && !hit.contains(el) ? hit.tagName.toLowerCase() : null;
    const kindOf = (e) => !e ? '' : e.tagName === 'SELECT' ? 'select' : e.tagName === 'INPUT' ? (e.getAttribute('type') || 'text').toLowerCase() : e.tagName.toLowerCase();
    const kind = kindOf(el), hitKind = kindOf(hit);
    return JSON.stringify({ x: r.x + r.width / 2, y: r.y + r.height / 2, covered, kind, hitKind, width: r.width, height: r.height, viewportWidth: innerWidth, viewportHeight: innerHeight });
    """

    /// The element's box in the top viewport, after scrolling it into view, for element screenshots.
    public static let box = find + """
    const el = find(target);
    el.scrollIntoView({ block: 'nearest', inline: 'nearest', behavior: 'instant' });
    const r = rectOf(el);
    return JSON.stringify({ x: r.x, y: r.y, width: r.width, height: r.height, viewportWidth: innerWidth, viewportHeight: innerHeight });
    """

    /// Brings the element to the middle of the viewport unless all of it shows already, as Playwright's
    /// scrollIntoViewIfNeeded does, gliding there over a few hundred milliseconds when `smooth`. How much shows is
    /// the browser's own answer (an IntersectionObserver), so scroll containers and iframes clip it too. One bigger
    /// than the viewport counts as shown when part of it is, and goes to its start.
    public static let reveal = find + """
    const el = find(target);
    const r = rectOf(el);
    if (!r.width || !r.height) return 'no size';
    // A frozen page (window closed or minimized) runs no observers; then the box in the top viewport decides.
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

    /// For wait: whether the target is on the page and visible (with `attached`, there at all), or with `gone`
    /// whether not. Several matches fail the wait, as they would fail the action after it, and so does a ref that
    /// is gone for good; with `gone` they count as present and gone.
    public static let present = find + """
    let present;
    try { const el = find(target); present = attached || visible(el); } catch (e) {
      if (e.name === 'SyntaxError') throw new Error(`invalid selector ${target}`);
      if (!gone && /take a new snapshot/.test(e.message)) throw e;
      present = /matches \\d+ elements/.test(e.message);
      if (present && !gone) throw e;
    }
    return String(gone ? !present : present);
    """

    public static let hasText = """
    const texts = (doc) => [doc.body?.innerText ?? '', ...[...doc.querySelectorAll('iframe, frame')].flatMap(f => {
      try { return f.contentDocument ? texts(f.contentDocument) : []; } catch { return []; }
    })];
    return String(texts(document).some(t => t.includes(text)));
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

    // Page world, document start: forwards console output and uncaught errors to the app.
    public static let consoleHook = """
    (() => {
      const describe = (a) => {
        if (typeof a === 'string') return a;
        // WebKit's stack is only the frames, without V8's "TypeError: message" first line.
        if (a instanceof Error) return `${a.name}: ${a.message}` + (a.stack ? ` (at ${a.stack.split('\\n')[0]})` : '');
        try { return JSON.stringify(a) ?? String(a); } catch { return String(a); }
      };
      const post = (level, args) => {
        try { window.webkit.messageHandlers.agwebConsole.postMessage(`${level}: ${args.map(describe).join(' ')}`); } catch {}
      };
      for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
        const original = console[level];
        console[level] = function (...args) { post(level, args); return original.apply(this, args); };
      }
      addEventListener('error', e => post('pageerror', [e.error ?? e.message]));
      addEventListener('unhandledrejection', e => post('pageerror', [e.reason]));
    })();
    """
}
