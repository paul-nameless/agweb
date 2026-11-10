# agweb internals

Details behind the README: where data lives, how the app stays out of your way, and what it can't do.

## Where things are stored

- `~/Library/WebKit/dev.playground.agweb/WebsiteDataStore/<uuid>/`: each named profile's cookies, localStorage, IndexedDB and cache, owned by WebKit. The uuid is derived from the name.
- `~/Library/Application Support/agweb/`:
  - `profiles.json`: profile names, since WebKit only knows the uuids;
  - `session-cookies/<uuid>.plist`: session cookies, saved as pages change and on quit;
  - `profile-locks/<uuid>.lock`: held by every instance with the profile open, so another one can't delete it;
  - `workspaces.json`: open workspaces, their profile, tabs (URL, title), current tab and the displayed tab;
  - `agweb.sock`: the CLI's socket.

The `.plist` and `.json` files are 0600, since URLs and cookies can carry tokens. Fresh profiles live in memory only.

## How it stays quiet

The app is a regular app launched with `open -g`, never calls `activate`, and first shows its window with `orderBack`. A reopen only brings the window forward when you activated the app yourself (Dock click). All tabs are stacked in the same frame with WebKit's window occlusion detection off, so a tab keeps rendering even when the window is covered. Only the tabs that need it are shown: the displayed one, the one a command is running on, a recorded one, a tab with a key or button held down, and an agent's tab for 30 s after its last command on it. The rest are hidden and muted, so WebKit throttles them (no animation frames, slower timers, nothing painted) and after about 4 minutes suspends their process and frees its memory; a command wakes its tab in a few milliseconds. Reopened tabs get no web process until they load. `tab-list` and `list --json` show each tab as visible, hidden, suspended or not loaded.

## Not here (yet)

- Not Playwright. There is no CDP, so Playwright, playwright-cli and Chrome extensions can't attach; every verb is implemented here.
- Network: WebKit has no network API, so `requests` lists the page's documents plus fetch and XHR calls (with headers and text bodies, 64 KB each) from a page-level hook; `--static` adds resource timing entries without details. `route` answers fetch and XHR only, not navigations, images or scripts, and `--remove-header` is not supported. `state-save` reads localStorage only from origins open in the workspace.
- No `run-code` (there is no Playwright engine), tracing, Chromium-only options (`--config`, `--browser`) or cross-origin iframe refs.
- `fill` inserts text with `execCommand('insertText')`, not key events; `type` presses real keys, except characters with no US-keyboard key (é, emoji), which it inserts.
- Closing (red button) or minimizing the window pauses pages; `agweb show` puts it back, and screenshots refuse until then. Recordings get no frames meanwhile.
- Named profiles keep their logins across relaunches, session cookies included: agweb saves those about a second after each page change and on quit (0600, under `~/Library/Application Support/agweb/session-cookies/`) and restores them before the profile's first page loads, so SSO logins survive. A crash or `kill -9` loses what changed since the last page change, such as a login done by hand that never left its page. Instances on other sockets share profiles but not live cookies: the last one to save wins.
- HTML5-draggable sources (`draggable`, links, images) are dropped with DOM drag events rather than the pointer: a native drag would start an AppKit drag session that follows your real mouse.
- `document.hasFocus()` is false in pages, since the window is never key while agents work. It only reports key to WebKit while the app is in the background, because WebKit drops mouse moves otherwise; pages therefore also react to your own pointer over the background window, as in Chrome, and a tab you clicked into yourself keeps `document.hasFocus()` true after you switch away.
- Untested: real logins, passkeys (WebKit allows them only for entitled browsers or associated domains), Cloudflare and other bot checks.
