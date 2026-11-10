# agweb

A WKWebView browser for coding agents, driven by the `agweb` CLI over a Unix socket. `README.md` is the user-facing reference; `skill/SKILL.md` is the agent skill (not installed anywhere).

## The rule everything serves

Agent actions never activate the app, raise or focus its window, or pop anything up, and the window stays visible (headless is never the answer). Judge focus behaviour by what the person sees, not by logs.

## Layout

- `Sources/AgwebCore`: host-free code with unit tests: socket protocol, page scripts, address parsing, the human pointer and typing rhythm (`Motion.swift`).
- `Sources/AgwebApp`: the app. `Browser.swift` dispatches commands (one at a time per workspace, workspaces in parallel) and `BrowserState.swift` holds requests, routes, cookies and storage state, `Model.swift` holds workspaces, tabs and named profiles, `Input.swift` synthesizes native events, `Recorder.swift` records video, `Window.swift`/`Toolbar.swift` the UI.
- `Sources/agweb`: the CLI. It launches the app with `open -g` when nobody holds the socket's lock.

## Build and test

- `./scripts/build.sh` builds `build/agweb.app`, signed with the first Apple Development identity so privacy grants survive rebuilds, and links `bin/agweb`. Quit the app first.
- Builds need `CC=/usr/bin/clang`; a `cc` wrapper on PATH shadows the C compiler.
- `CC=/usr/bin/clang swift test` runs the unit tests; `./scripts/selftest.sh` drives every verb in a separate instance (see its header).
- Experiments go in an isolated instance (`AGWEB_SOCKET=/tmp/x.sock`), never in a standalone AppKit probe: an unbundled binary run from a terminal activates itself.

## WebKit facts that shaped the code

- Mouse and key events go straight to one web view (`webView.mouseDown` etc.), skipping `NSWindow.sendEvent`, so they reach stacked-under tabs and never activate the app.
- WKWebView has no `mouseMoved:`; moves use the `_simulateMouseMove:` SPI, and pages only see them because of `AgentWindow`.
- Private API is called through its IMP after `responds(to:)`; KVC on it raised an ObjC exception that wedged every command.
