# wkbrowser

A WebKit (WKWebView) browser for coding agents, driven by a playwright-cli-style CLI. It never activates or raises its window: agents work in the background while the window stays visible in the window list.

- One window. The sidebar groups tabs by agent session; a green dot marks the tab each agent is driving. Click a tab to watch it, hover it to close it, use the session's + for a new tab.
- Toolbar: back, forward, reload, a centered address field, new tab. ⌘T, ⌘W, ⌘L, ⌘R, ⌘[, ⌘] and the usual Edit shortcuts work.
- Each session gets a persistent WebKit profile. Sessions that pass the same `--profile` share logins, in parallel, which Chrome can't do with one profile dir. `--profile=ephemeral` keeps and shares nothing.
- Clicks and key presses are native AppKit events delivered straight to the tab's web view, so pages see `isTrusted == true`, and they reach tabs nobody is looking at.
- Input moves at a person's pace by default: the pointer glides to its target (Fitts's-law timing, a curved minimum-jerk path, off-centre aim, from the qa-video skill), so hover menus react, and `type` inserts a character at a time with human gaps. `--instant` jumps and inserts at once.
- Nothing pops up: popups become tabs, dialogs are answered in code (confirm and prompt dismissed unless `wkb dialog accept`) and reported under `### Events`, file choosers take files from `wkb upload`, and controls that open native pickers (select, date, colour) must be set with `fill`.

## Build and run

```sh
./scripts/build.sh                 # build/WKBrowser.app, bin/wkb (refuses while the app runs: bin/wkb quit)
ln -s "$PWD/bin/wkb" ~/.local/bin/wkb
wkb -s claude open example.com     # starts the app with open -g if needed
wkb -s claude snapshot
wkb -s claude click e2
wkb quit
./scripts/selftest.sh              # 50 checks in a separate instance on its own socket
```

`wkb help` lists the verbs. `WKB_SOCKET=/path` runs a separate instance next to the default one.

## How it stays quiet

The app is a regular app launched with `open -g`, never calls `activate`, and first shows its window with `orderBack`. A reopen only brings the window forward when you activated the app yourself (Dock click). All tabs are stacked unhidden in the same frame with WebKit's window occlusion detection off, so rendering, timers and screenshots continue in every tab even when the window is covered.

## Not here (yet)

- Not Playwright. There is no CDP, so Playwright, playwright-cli and Chrome extensions can't attach; every verb is implemented here.
- No network interception or mocking, no tracing or video, no downloads handling, no iframe-internal refs.
- `fill` and `type` use `execCommand('insertText')`, not key events (`type` per character). Only pointer input and `press` are native.
- Closing (red button) or minimizing the window pauses pages; `wkb show` puts it back, and screenshots refuse until then.
- `document.hasFocus()` is false in pages, since the window is never key while agents work. It only reports key to WebKit while the app is in the background, because WebKit drops mouse moves otherwise; pages therefore also react to your own pointer over the background window, as in Chrome, and a tab you clicked into yourself keeps `document.hasFocus()` true after you switch away.
- Untested: real logins, passkeys (WebKit allows them only for entitled browsers or associated domains), Cloudflare and other bot checks.
