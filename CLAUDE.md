# agweb

A WKWebView browser for coding agents, driven by the `agweb` CLI over a Unix socket. `README.md` is the short pitch; `skill/SKILL.md` is the agent skill, symlinked from `~/.claude/skills/agweb`, so an edit reaches every new Claude session at once. `todo.org` (untracked) holds the backlog.

## The rule everything serves

Agent actions never activate the app, raise or focus its window, or pop anything up, and the window stays visible (headless is never the answer). Judge focus behaviour by what the person sees, not by logs.

## Layout

- `Sources/AgwebCore`: host-free code with unit tests: socket protocol, page scripts (`PageScripts.swift`, the injected JS), reply shaping (`Output.swift`), the command list and did-you-mean (`Commands.swift`), address parsing, the human pointer and typing rhythm (`Motion.swift`).
- `Sources/AgwebApp`: the app. `Browser.swift` dispatches commands (one at a time per workspace, workspaces in parallel) and `BrowserState.swift` holds requests, routes, cookies and storage state, `Model.swift` holds workspaces, tabs and named profiles (session cookies, locks), `Visibility.swift` decides which tabs WebKit sees, `SavedWorkspaces.swift` saves and reopens workspaces, tabs and their sessionStorage, `Dashboard.swift` the ⌘D grid, `Input.swift` synthesizes native events, `Recorder.swift` records video, `Window.swift`/`Toolbar.swift` the UI.
- `Sources/agweb`: the CLI. It launches the app with `open -g` when nobody holds the socket's lock.

## Build and test

- `./scripts/build.sh` builds `build/Agweb.app`, signed with the first Apple Development identity so privacy grants survive rebuilds, and links `bin/agweb`. It refuses while the app runs. The person uses that app: never quit, rebuild or restart it without asking.
- `scripts/build.sh --test` builds a throwaway copy in `/tmp/agtest` instead; `AGWEB_CLI=$(scripts/build.sh --test) scripts/selftest.sh` tests it without touching the running app.
- Builds need `CC=/usr/bin/clang`; a `cc` wrapper on PATH shadows the C compiler.
- `CC=/usr/bin/clang swift test` runs the unit tests; `./scripts/selftest.sh` drives every verb in a separate instance (see its header).
- Install Command Line Tool and Install Agent Skill link `/usr/local/bin/agweb` and `~/.claude|.codex/skills/agweb` into the running bundle (`LinkInstall.swift`); a link elsewhere is the person's and is left alone. An instance on its own socket never repairs them at launch, and `AGWEB_CLI_LINK`/`AGWEB_HOME` move them for the selftest.
- Experiments go in an isolated instance (`AGWEB_SOCKET=/tmp/x.sock`), never in a standalone AppKit probe: an unbundled binary run from a terminal activates itself.

## WebKit facts that shaped the code

- Mouse and key events go straight to one web view (`webView.mouseDown` etc.), skipping `NSWindow.sendEvent`, so they reach stacked-under tabs and never activate the app.
- WKWebView has no `mouseMoved:`; moves use the `_simulateMouseMove:` SPI, and pages only see them because of `AgentWindow`.
- Private API is called through its IMP after `responds(to:)`; KVC on it raised an ObjC exception that wedged every command.
- WebKit sees a page as hidden only when its view (or an ancestor) is hidden, it is out of the window, or the window is closed or occluded; stacked siblings don't count. So tabs nobody needs are hidden explicitly, and `inactiveSchedulingPolicy = .suspend` then suspends their process after about 4 minutes. A hidden or suspended tab still answers scripts and `takeSnapshot`; commands wake their tab first.
- WebKit numbers the middle button 4 in `WKNavigationAction.buttonNumber`, and opens nothing on a middle click by itself.
- A reopened tab's sessionStorage is saved by script and put back by a document-start user script, before the page's own scripts read it.

## Storage

- `~/Library/WebKit/dev.playground.agweb/WebsiteDataStore/<uuid>/`: a named profile's WebKit data; the uuid is derived from the name. Fresh profiles live in memory only.
- `~/Library/Application Support/agweb/`: `profiles.json` (names), `session-cookies/<uuid>.plist` (saved a second after each page change and on quit, restored before the profile's first load; a `kill -9` loses what changed since), `profile-locks/<uuid>.lock`, `workspaces.json`, `agweb.sock`. Files carrying URLs or cookies are 0600.

## Known gaps

- No CDP: Playwright and extensions can't attach; no `run-code`, tracing or cross-origin iframe refs.
- `requests` and `route` see documents, fetch and XHR from a page hook (64 KB bodies), not images or scripts; no `--remove-header`. `state-save` reads localStorage only from origins open in the workspace.
- HTML5 draggables get DOM drag events: a native drag would follow the person's real mouse.
- `document.hasFocus()` is false, since the window is never key while agents work. The window reports key to WebKit only while the app is in the background (WebKit drops mouse moves otherwise), so pages also react to the person's pointer over it.
- A closed or minimized window pauses pages; screenshots refuse and recordings get no frames until `agweb show`.
- Instances on other sockets share profiles but not live cookies: the last save wins.
- Passkeys need an entitled browser or associated domains.
