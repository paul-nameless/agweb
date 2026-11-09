// Function bodies for callAsyncJavaScript. They run in the isolated "agweb" content world, which shares the DOM
// with the page but not its globals, so the page cannot see or clobber window.__agweb.
public enum PageScripts {
    public static let find = """
    const W = window.__agweb || (window.__agweb = { refs: new Map() });
    const find = (target) => {
      if (/^e\\d+$/.test(target)) {
        const el = W.refs.get(target);
        if (!el || !el.isConnected) throw new Error(`ref ${target} not found; take a new snapshot`);
        return el;
      }
      const el = document.querySelector(target);
      if (!el) throw new Error(`no element matches ${target}`);
      return el;
    };
    """

    public static let maxSnapshotLines = 2000

    public static let snapshot = find + """
    W.refs = new Map();
    let n = 0;
    const lines = [];
    let truncated = false;
    const skip = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'svg', 'HEAD']);
    const leaf = new Set(['link', 'button', 'textbox', 'searchbox', 'combobox', 'checkbox', 'radio', 'slider', 'heading', 'img', 'switch', 'tab', 'menuitem', 'option']);
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
      if (tag === 'iframe') return 'iframe';
      if (el.isContentEditable && !el.parentElement?.isContentEditable) return 'textbox';
      return null;
    };
    const clean = (s) => (s || '').replace(/\\s+/g, ' ').trim().slice(0, 120);
    const nameOf = (el) => clean(
      el.getAttribute('aria-label') || el.labels?.[0]?.innerText || el.getAttribute('alt') || el.getAttribute('title') ||
      el.getAttribute('placeholder') || (['INPUT', 'TEXTAREA', 'SELECT'].includes(el.tagName) ? '' : el.innerText) ||
      el.querySelector?.('img[alt]')?.getAttribute('alt') || el.value
    );
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
      return node.childNodes;
    };
    const walk = (root, depth) => {
      for (const node of childrenOf(root)) {
        if (truncated) return;
        if (node.nodeType === Node.TEXT_NODE) {
          const text = clean(node.textContent);
          if (text) emit(`${'  '.repeat(depth)}- text: ${JSON.stringify(text)}`);
          continue;
        }
        if (node.nodeType !== Node.ELEMENT_NODE || skip.has(node.tagName) || node.getAttribute('aria-hidden') === 'true') continue;
        const style = getComputedStyle(node);
        // display:contents boxes (every <slot> by default) have no rects but their children do.
        if (style.display === 'contents') { walk(node, depth); continue; }
        if (node.getClientRects().length === 0 || style.visibility === 'hidden') continue;
        const role = roleOf(node);
        if (!role) { walk(node, depth); continue; }
        const ref = `e${++n}`;
        W.refs.set(ref, node);
        let line = `${'  '.repeat(depth)}- ${role}`;
        const name = leaf.has(role) ? nameOf(node) : clean(node.getAttribute('aria-label'));
        if (name) line += ` ${JSON.stringify(name)}`;
        if (role === 'heading') line += ` [level=${/^H[1-6]$/.test(node.tagName) ? node.tagName[1] : node.getAttribute('aria-level') || 2}]`;
        if (node.checked) line += ' [checked]';
        if (node.disabled) line += ' [disabled]';
        if (['textbox', 'searchbox', 'combobox'].includes(role) && node.tagName !== 'SELECT' && node.value) line += ` [value=${JSON.stringify(clean(node.value))}]`;
        line += ` [ref=${ref}]`;
        if (node === document.activeElement) line += ' [focused]';
        if (!emit(line)) return;
        if (node.tagName === 'SELECT') {
          for (const option of node.options) {
            emit(`${'  '.repeat(depth + 1)}- option ${JSON.stringify(clean(option.label))}${option.selected ? ' [selected]' : ''}`);
          }
        } else if (!leaf.has(role)) {
          walk(node, depth + 1);
        }
      }
    };
    walk(document.body || document.documentElement, 0);
    if (truncated) lines.push(`- (truncated at \(maxSnapshotLines) lines; use eval to read the rest)`);
    return lines.join('\\n');
    """

    // Returns the element's center in CSS pixels after scrolling it into view, what actually sits there, and
    // what kind of control it is (some controls open native popups when clicked).
    public static let locate = find + """
    const el = find(target);
    el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
    const r = el.getBoundingClientRect();
    const x = r.left + r.width / 2, y = r.top + r.height / 2;
    const hit = el.getRootNode().elementFromPoint?.(x, y) ?? document.elementFromPoint(x, y);
    const covered = hit && hit !== el && !el.contains(hit) && !hit.contains(el) ? hit.tagName.toLowerCase() : null;
    const kind = el.tagName === 'SELECT' ? 'select' : el.tagName === 'INPUT' ? (el.getAttribute('type') || 'text').toLowerCase() : el.tagName.toLowerCase();
    return JSON.stringify({ x, y, covered, kind, width: r.width, height: r.height, viewportWidth: innerWidth, viewportHeight: innerHeight });
    """

    public static let viewport = """
    return JSON.stringify({ viewportWidth: innerWidth, viewportHeight: innerHeight });
    """

    public static let jsClick = find + """
    find(target).click();
    return 'ok';
    """

    public static let fill = find + """
    const el = find(target);
    const type = (el.getAttribute('type') || '').toLowerCase();
    if (el.tagName === 'INPUT' && ['checkbox', 'radio', 'file', 'submit', 'button', 'reset', 'image'].includes(type)) {
      throw new Error(type === 'file' ? 'use upload for file inputs' : `use click for ${type} inputs`);
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
    } else if (el.tagName === 'INPUT' && ['date', 'time', 'datetime-local', 'month', 'week', 'color', 'range', 'number'].includes(type)) {
      el.value = text;
      el.dispatchEvent(new Event('input', { bubbles: true }));
    } else {
      if (el.select) el.select(); else document.execCommand('selectAll');
      if (!(text ? document.execCommand('insertText', false, text) : document.execCommand('delete'))) {
        const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, text);
        el.dispatchEvent(new Event('input', { bubbles: true }));
      }
    }
    el.dispatchEvent(new Event('change', { bubbles: true }));
    return 'ok';
    """

    public static let insertText = """
    if (!document.execCommand('insertText', false, text)) throw new Error('no editable element is focused');
    return 'ok';
    """

    // Page world: arbitrary expression or function, result as JSON text. The newline keeps a trailing
    // line comment in `code` from swallowing the closing parenthesis.
    public static func evaluate(_ code: String) -> String {
        """
        const __value = (\(code)
        );
        const __result = typeof __value === 'function' ? await __value() : await __value;
        if (__result === undefined) return 'undefined';
        return JSON.stringify(__result) ?? String(__result);
        """
    }

    // Page world, document start: forwards console output and uncaught errors to the app.
    public static let consoleHook = """
    (() => {
      const describe = (a) => {
        if (typeof a === 'string') return a;
        if (a instanceof Error) return a.stack || `${a.name}: ${a.message}`;
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
