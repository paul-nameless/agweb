# wkbrowser

A WKWebView browser for coding agents, driven by the `wkb` CLI over a Unix socket. `README.md` is the user-facing reference; `skill/SKILL.md` is the agent skill (not installed anywhere).

## The rule everything serves

Agent actions never activate the app, raise or focus its window, or pop anything up, and the window stays visible (headless is never the answer). Judge focus behaviour by what the person sees, not by logs.

## Layout

- `Sources/WKBCore`: socket protocol (`Protocol.swift`) and the JS bodies run in pages (`PageScripts.swift`).
- `Sources/WKBrowser`: the app. `Browser.swift` dispatches commands (one at a time per session, sessions in parallel), `Model.swift` holds sessions/tabs, `Input.swift` synthesizes native events, `Motion.swift` the human pointer and typing rhythm, `Window.swift`/`Toolbar.swift` the UI.
- `Sources/wkb`: the CLI. It launches the app with `open -g` when needed.

## Build and test

- `./scripts/build.sh` builds `build/WKBrowser.app` and links `bin/wkb`. It refuses while that app runs (`bin/wkb quit` first): overwriting a running signed binary kills it.
- Builds need `CC=/usr/bin/clang` (the script sets it); a `cc` wrapper on PATH shadows the C compiler.
- `./scripts/selftest.sh` runs every verb in a separate instance on its own `WKB_SOCKET`; keep another app frontmost while it runs. Exit code = failures.
- Experiments go in an isolated instance (`WKB_SOCKET=/tmp/x.sock`), never in a standalone AppKit probe: an unbundled binary run from a terminal activates itself.

## WebKit facts that shaped the code

- Mouse and key events go straight to one web view (`webView.mouseDown` etc.), skipping `NSWindow.sendEvent`, so they reach stacked-under tabs and never activate the app.
- WKWebView has no `mouseMoved:`; moves use the `_simulateMouseMove:` SPI. WebKit drops moves unless the window is key, and reads key state only when it changes, so `AgentWindow` reports key while the app is inactive. Toggling it per move does not work.
- Private API is called through its IMP after `responds(to:)`. KVC on `_windowOcclusionDetectionEnabled` raised an ObjC exception that wedged every command.
- Controls that open native pickers (select, date, colour) must be set with `fill`; a native click would pop a menu on the person's screen.
