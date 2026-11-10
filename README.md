# agweb

A WebKit (WKWebView) browser for coding agents, driven by a playwright-cli-style CLI. It never activates or raises its window: agents work in the background while the window stays visible in the window list.

## Why agweb

- It never takes focus. Nothing comes to the front, activates or pops up: dialogs, file choosers, downloads and context menus are answered in code, so you keep typing while agents browse.
- It stays visible. One window shows every agent's tabs grouped by task, with a dot on the tab each agent drives. Click in to watch, or press Cmd+D to see all tabs at once.
- Agents run in parallel, each in its own workspace with its own tabs.
- Agents share logins. Log in once to a named profile and every agent can use it at the same time, which Chrome can't do with one profile. SSO session cookies survive restarts.
- Workspaces and tabs reopen after a restart and load only when used.
- Idle tabs are throttled, then suspended: five idle pages take about 0% CPU and 560 MB, against half a core and 1 GB before.
- Clicks and keys are native events (`isTrusted`), and the pointer moves like a person's, so hover menus and drag-and-drop work.
- `video-start` records a tab to MP4 with the pointer and clicks drawn in, idle time cut and chapter cards.
- Commands follow playwright-cli. Snapshots carry refs, targets take `role=` and `text=`, `text` returns an article as markdown, actions wait for the network, and API calls can be mocked.

- Secrets stay out of transcripts: `fill --secret-cmd 'pass show site'` (or `op read`, `bw get`, `--secret-file`) fills a field from a command the CLI runs, and replies show `<hidden>` wherever the value would appear. It keeps passwords out of an agent's context, but an agent that wants the value can still get it, from a screenshot for one.

Coming: basic auth and permission prompts answered in code.

## Features

- One window. The sidebar groups tabs by workspace, one per agent task; a green dot marks the tab each agent is driving. Click a tab to watch it, hover it to close it, right-click a workspace for a new tab.
- Toolbar: the dashboard, back, forward, reload, a centered address field, new tab. ⌘T, ⌘W, ⌘L, ⌘R, ⌘[, ⌘], ⇧⌘[ and ⇧⌘] (previous and next tab, across workspaces, wrapping around) and the usual Edit shortcuts work.
- Dashboard (⌘D, or `agweb dashboard`): every tab at once as a grid of thumbnails, most recently active first, each with its workspace, profile, the agent's last command and whether it is hidden or suspended. Click a tile or a sidebar tab to go to it. Thumbnails refresh about once a second for tabs an agent is working on; idle ones keep their last picture, so the dashboard wakes nothing. `agweb dashboard --filename=grid.png` saves a picture of it. Settings (⌘,) picks its column count and can show each page's CPU and memory and agweb's total, sampled every 2 s only while the dashboard is open.
- Workspaces and their tabs survive a quit or restart: they are saved as they change and reopen at launch, each page loading when it is first shown or driven. `close` and `close-all` end them for good. Fresh-profile workspaces come back logged out.
- A workspace starts with a fresh profile that keeps nothing. `-p NAME` (or `AGWEB_PROFILE`) gives it a named, persistent profile instead, shared by every workspace naming it, in parallel, which Chrome can't do with one profile dir. `profile-list` and `profile-delete` manage them.
- Clicks and key presses are native AppKit events delivered straight to the tab's web view, so pages see `isTrusted == true`, and they reach tabs nobody is looking at.
- Commands follow playwright-cli's names and options (`agweb help`); targets also take `role=button[name="Save"]` and `text=Save`, and reach into same-origin iframes. `--raw`, `--json` and `--filename` reshape or redirect replies.
- Pointer verbs: `click` (left, right or middle), `dblclick`, `hover`, `drag`, `mousemove`, `mousedown`/`mouseup`, `mousewheel`; `keydown`/`keyup` hold keys, so `keydown Shift` then `click` shift-clicks. Input moves at a person's pace by default: the pointer glides to its target (Fitts's-law timing, a curved minimum-jerk path, off-centre aim, from the qa-video skill), so hover menus react, and `type` inserts a character at a time with human gaps. `--instant` jumps and inserts at once.
- `video-start` / `video-stop` record the workspace's tab to MP4 with the pointer and click rings drawn in. A frame is written only when the page or pointer changed, and time between agent commands is cut to 1.5 s (`--max-idle`), even while a caret blinks. A recording follows the workspace's current tab, so a popup the agent opens is filmed too.
- Nothing pops up: popups become tabs, dialogs are answered in code (confirm and prompt dismissed unless `agweb dialog-accept`) and reported under `### Events`, file choosers take files from `agweb upload`, downloads save without a panel (to `download --filename`, replacing a file there, else `.agweb/` in the folder the agent ran from, or `--download-dir`), an agent's right click gets no context menu (nor does yours on a tab while its agent is mid-command), and controls that open native pickers (select, date, colour) must be set with `fill` or `select`.
- `text` returns an article's main content, or one element, as markdown, through [Defuddle](https://github.com/kepano/defuddle) (MIT, bundled as `Resources/defuddle.js`); a page with little article in it, like a web app, is converted whole, and the reply says so.
- `wait` returns when an element shows or leaves, text or a URL appears, or the network goes quiet (`--load`); `pdf` prints the page with print styles (no panel) or `--single-page`; `emulate --color-scheme` sets one tab's dark or light mode.
- `resize` sets one tab's viewport inside the shared window, which keeps its size; larger than the window is clipped on screen but not in screenshots. `screenshot --full-page` grows the view to the page's height for the shot.

## Build and run

```sh
./scripts/build.sh                 # build/Agweb.app, bin/agweb (refuses while the app runs: bin/agweb quit)
ln -s "$PWD/bin/agweb" ~/.local/bin/agweb
agweb install-skill                # the agent skill for Claude Code and Codex (also Help ▸ Install Agent Skill, Settings)
agweb -w demo open example.com     # starts the app with open -g if needed
agweb -w demo snapshot
agweb -w demo click e2
agweb quit
./scripts/selftest.sh              # every verb, in a separate instance on its own socket
```

`agweb help` lists the verbs. `AGWEB_SOCKET=/path` runs a separate instance next to the default one, with its own `<socket>.workspaces.json`. `swift scripts/make-icon.swift` redraws the icon.

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
- `fill` and `type` use `execCommand('insertText')`, not key events (`type` per character). Only pointer input and `press` are native.
- Closing (red button) or minimizing the window pauses pages; `agweb show` puts it back, and screenshots refuse until then. Recordings get no frames meanwhile.
- Named profiles keep their logins across relaunches, session cookies included: agweb saves those about a second after each page change and on quit (0600, under `~/Library/Application Support/agweb/session-cookies/`) and restores them before the profile's first page loads, so SSO logins survive. A crash or `kill -9` loses what changed since the last page change, such as a login done by hand that never left its page. Instances on other sockets share profiles but not live cookies: the last one to save wins.
- HTML5-draggable sources (`draggable`, links, images) are dropped with DOM drag events rather than the pointer: a native drag would start an AppKit drag session that follows your real mouse.
- `document.hasFocus()` is false in pages, since the window is never key while agents work. It only reports key to WebKit while the app is in the background, because WebKit drops mouse moves otherwise; pages therefore also react to your own pointer over the background window, as in Chrome, and a tab you clicked into yourself keeps `document.hasFocus()` true after you switch away.
- Untested: real logins, passkeys (WebKit allows them only for entitled browsers or associated domains), Cloudflare and other bot checks.
