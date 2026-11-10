# agweb

A WebKit (WKWebView) browser for coding agents, driven by a playwright-cli-style CLI. It never activates or raises its window: agents work in the background while the window stays visible in the window list.

- One window. The sidebar groups tabs by workspace, one per agent task; a green dot marks the tab each agent is driving. Click a tab to watch it, hover it to close it, use the workspace's + for a new tab.
- Toolbar: back, forward, reload, a centered address field, new tab. ⌘T, ⌘W, ⌘L, ⌘R, ⌘[, ⌘] and the usual Edit shortcuts work.
- A workspace starts with a fresh profile that keeps nothing. `-p NAME` (or `AGWEB_PROFILE`) gives it a named, persistent profile instead, shared by every workspace naming it, in parallel, which Chrome can't do with one profile dir. `profile-list` and `profile-delete` manage them.
- Clicks and key presses are native AppKit events delivered straight to the tab's web view, so pages see `isTrusted == true`, and they reach tabs nobody is looking at.
- Commands follow playwright-cli's names and options (`agweb help`); targets also take `role=button[name="Save"]` and `text=Save`, and reach into same-origin iframes. `--raw`, `--json` and `--filename` reshape or redirect replies.
- Pointer verbs: `click` (left, right or middle), `dblclick`, `hover`, `drag`, `mousemove`, `mousedown`/`mouseup`, `mousewheel`; `keydown`/`keyup` hold keys, so `keydown Shift` then `click` shift-clicks. Input moves at a person's pace by default: the pointer glides to its target (Fitts's-law timing, a curved minimum-jerk path, off-centre aim, from the qa-video skill), so hover menus react, and `type` inserts a character at a time with human gaps. `--instant` jumps and inserts at once.
- `video-start` / `video-stop` record the workspace's tab to MP4 with the pointer and click rings drawn in. A frame is written only when the page or pointer changed, and time between agent commands is cut to 1.5 s (`--max-idle`), even while a caret blinks. A recording follows the workspace's current tab, so a popup the agent opens is filmed too.
- Nothing pops up: popups become tabs, dialogs are answered in code (confirm and prompt dismissed unless `agweb dialog-accept`) and reported under `### Events`, file choosers take files from `agweb upload`, downloads save without a panel (to `download --filename`, else `~/Downloads`), an agent's right click gets no context menu, and controls that open native pickers (select, date, colour) must be set with `fill` or `select`.
- `resize` sets one tab's viewport inside the shared window, which keeps its size; larger than the window is clipped on screen but not in screenshots. `screenshot --full-page` grows the view to the page's height for the shot.

## Build and run

```sh
./scripts/build.sh                 # build/agweb.app, bin/agweb (refuses while the app runs: bin/agweb quit)
ln -s "$PWD/bin/agweb" ~/.local/bin/agweb
agweb -w demo open example.com     # starts the app with open -g if needed
agweb -w demo snapshot
agweb -w demo click e2
agweb quit
./scripts/selftest.sh              # every verb, in a separate instance on its own socket
```

`agweb help` lists the verbs. `AGWEB_SOCKET=/path` runs a separate instance next to the default one.

## How it stays quiet

The app is a regular app launched with `open -g`, never calls `activate`, and first shows its window with `orderBack`. A reopen only brings the window forward when you activated the app yourself (Dock click). All tabs are stacked unhidden in the same frame with WebKit's window occlusion detection off, so rendering, timers and screenshots continue in every tab even when the window is covered.

## Not here (yet)

- Not Playwright. There is no CDP, so Playwright, playwright-cli and Chrome extensions can't attach; every verb is implemented here.
- Network: WebKit has no network API, so `requests` lists the page's documents plus fetch and XHR calls (with headers and text bodies, 64 KB each) from a page-level hook; `--static` adds resource timing entries without details. `route` answers fetch and XHR only, not navigations, images or scripts, and `--remove-header` is not supported. `state-save` reads localStorage only from origins open in the workspace.
- No `run-code` (there is no Playwright engine), tracing, `pdf` or cross-origin iframe refs.
- `fill` and `type` use `execCommand('insertText')`, not key events (`type` per character). Only pointer input and `press` are native.
- Closing (red button) or minimizing the window pauses pages; `agweb show` puts it back, and screenshots refuse until then. Recordings get no frames meanwhile.
- Named profiles keep their logins across relaunches, session cookies included: agweb saves those on quit (0600, under `~/Library/Application Support/agweb/session-cookies/`) and restores them when the profile next opens, so SSO logins survive. A crash or `kill -9` loses the session cookies of that run.
- HTML5-draggable sources (`draggable`, links, images) are dropped with DOM drag events rather than the pointer: a native drag would start an AppKit drag session that follows your real mouse.
- `document.hasFocus()` is false in pages, since the window is never key while agents work. It only reports key to WebKit while the app is in the background, because WebKit drops mouse moves otherwise; pages therefore also react to your own pointer over the background window, as in Chrome, and a tab you clicked into yourself keeps `document.hasFocus()` true after you switch away.
- Untested: real logins, passkeys (WebKit allows them only for entitled browsers or associated domains), Cloudflare and other bot checks.
