# agweb

A WKWebView browser for coding agents, driven by the `agweb` CLI over a Unix socket. `README.md` is the short pitch; `skill/SKILL.md` is the agent skill, symlinked from `~/.claude/skills/agweb`, so an edit reaches every new Claude session at once. `todo.org` (untracked) holds the backlog.

## The rule everything serves

Agent actions never activate the app, raise or focus its window, or pop anything up, and the window stays visible (headless is never the answer). Judge focus behaviour by what the person sees, not by logs.

## Layout

- `Sources/AgwebCore`: host-free code with unit tests.
  - `PageScripts.swift`: the injected JS.
  - `Output.swift`: reply shaping.
  - `Commands.swift`: the command list and did-you-mean.
  - `Motion.swift`: the human pointer and typing rhythm.
  - `FilterList.swift`: filter lists to WebKit content rules.
  - `Passkey.swift`: WebAuthn encoding and the public suffix check.
  - `ProxySpec.swift`, `ProxyRegistry.swift`: a profile's proxy URL and `profiles/proxies.json`.
  - Also the socket protocol and address parsing.
- `Sources/AgwebApp`: the app.
  - `Browser.swift`: dispatches commands, one at a time per workspace, workspaces in parallel.
  - `BrowserState.swift`: requests, routes, cookies and storage state.
  - `Model.swift`: workspaces, tabs and named profiles (session cookies, locks).
  - `Visibility.swift`: which tabs WebKit sees (`unload off` keeps a workspace's current tab running); turns off the secure input WebKit leaves on in the background.
  - `SavedWorkspaces.swift`: saves and reopens workspaces, tabs, their sessionStorage and when each was last used.
  - `Cleanup.swift`: closes workspaces and tabs unused for Settings' days (7 by default), at launch and hourly.
  - `Unload.swift`: ends the page process of a tab unused for Settings' minutes (30 by default; 5 when macOS reports memory pressure), keeping its URL, title and history; the next command or display reloads it (a POST's result by its address, without resending the form). Never the displayed tab, one playing sound one can hear, or a workspace with `unload off`. `sound on` keeps a workspace's hidden tabs unmuted, and the person's Mute/Unmute Tab overrides it (Visibility.swift). In a tab whose process was unloaded or crashed, a form resubmission (back or forward onto a POST's result) is cancelled unless it is an explicit reload.
  - `Dashboard.swift`: the ⌘D grid; `Thumbnails.swift`: its pictures, taken only while a tab is awake (as it goes hidden, after a tab loads, as an agent's command ends and for 25 s after, as the dashboard opens or comes back into view, at quit), never on a timer or by waking a suspended one; while the window can't be seen the dashboard does nothing.
  - `AdBlock.swift`: fetches uBlock Origin's lists every 4 days and puts the compiled rules on every content controller (off for the instance in Settings, for one workspace with `agweb -w NAME adblock off`).
  - `Input.swift`: synthesizes native events.
  - `ClipboardRouting.swift`: a page's copy goes to the person's clipboard after their own click and to the workspace's after an agent's; pages never write the system clipboard themselves.
  - `Passkeys.swift`: agweb's own passkey authenticator. `PageScripts.passkeyShim` sends a page's `navigator.credentials` requests to it; it answers only during or just after an agent's command or the person's click in that tab, for the origin WebKit reports.
  - `PasskeyStores.swift`: passkeys per profile (Keychain, file, or in memory for a fresh workspace).
  - `SecurityKey.swift`: a USB security key (YubiKey) beside agweb's passkeys, for profiles the person switched it on for in Settings (never an agent): sign-ups, and sign-ins no agweb passkey answers, go to the key, with the PIN and touch in a bar in the tab (`KeyCeremony`), and every step in `<root>/logs/security-key.log`. Two backends while we learn which works: `SecurityKeyWebKit.swift` drives WebKit's own client (`_WKWebAuthenticationPanel`, declared in the `WebAuthnSPI` Objective-C target), `SecurityKeyCTAP.swift` speaks CTAP2 over HID itself (framing, CBOR and PIN protocols in `AgwebCore/CTAP.swift`).
  - `Recorder.swift`: records video.
  - `Window.swift`, `Toolbar.swift`, `Settings.swift`: the UI.
- `Sources/agweb`: the CLI. It launches the app with `open -g` when nobody holds the socket's lock, passing `AGWEB_ROOT` on.

## Build and test

- `./scripts/build.sh` builds `build/Agweb.app`, signed with the first Apple Development identity so privacy grants survive rebuilds, and links `bin/agweb`. It refuses while the app runs. The person uses that app: never quit, rebuild or restart it without asking.
- `scripts/build.sh --test [DIR]` builds a throwaway copy in DIR (default `/tmp/agtest`) with the bundle id `<id>.test`; `AGWEB_CLI=$(scripts/build.sh --test) scripts/selftest.sh` tests it without touching the running app.
- Builds need `CC=/usr/bin/clang`; a `cc` wrapper on PATH shadows the C compiler.
- `CC=/usr/bin/clang swift test` runs the unit tests; `./scripts/selftest.sh` drives every verb in a separate instance (see its header).
- `scripts/bench.py` (see its header) times 23 commands on big local pages, each page in a fresh test instance, against `scripts/bench-baseline.json` (this Mac's); run it by hand before a release (the local `/perf-check` skill), not on every commit. `docs/benchmarks.md` has the history.
- Install Command Line Tool and Install Agent Skill link `/usr/local/bin/agweb` and `~/.claude|.codex/skills/agweb` into the running bundle (`LinkInstall.swift`); a link elsewhere is the person's and is left alone. An instance on its own root never repairs them at launch, and `AGWEB_CLI_LINK`/`AGWEB_HOME` move them for the selftest.
- Local builds (`scripts/build.sh`, flag `AGWEB_COMMAND_LOG`) append every command to `<root>/logs/commands.jsonl` for debugging agent reports; typed text, query strings and most option values are left out (`CommandLog.swift`).
- Experiments go in an isolated instance, never in a standalone AppKit probe: an unbundled binary run from a terminal activates itself.
- The person's instance owns the default root, `~/Library/Application Support/agweb`; never quit, rebuild or restart it unasked. Tests, debugging and experiments get a root of their own, sharing nothing with it: `export AGWEB_ROOT=/tmp/agw-fix; A=$(scripts/build.sh --test $AGWEB_ROOT)`, then `$A ...`, and `trash $AGWEB_ROOT` when done. Keep the root short (the socket inside it caps near 104 bytes). A test build refuses to run without `AGWEB_ROOT`, so a forgotten export can't reach the person's instance.

## WebKit facts that shaped the code

- Mouse and key events go straight to one web view (`webView.mouseDown` etc.), skipping `NSWindow.sendEvent`, so they reach stacked-under tabs and never activate the app.
- WKWebView has no `mouseMoved:`; moves use the `_simulateMouseMove:` SPI, and pages only see them because of `AgentWindow`.
- Private API is called through its IMP after `responds(to:)`; KVC on it raised an ObjC exception that wedged every command.
- WebKit sees a page as hidden only when its view (or an ancestor) is hidden, it is out of the window, or the window is closed or occluded; stacked siblings don't count. So tabs nobody needs are hidden explicitly (the displayed one too while the window can't be seen), and `inactiveSchedulingPolicy = .suspend` then suspends their process after about 4 minutes. A hidden or suspended tab still answers scripts and `takeSnapshot`; commands wake their tab first.
- Suspension keeps the page in memory (8 sites: 1621 MB loaded, 1135 MB suspended, 193 MB with no process), so Unload.swift ends idle tabs' processes. `_killWebContentProcess` does nothing on macOS 26, so it sends SIGKILL to `_webProcessIdentifier` (a popup shares its opener's pid) and WebKit reports a crash. The web view keeps its back/forward list but reports no URL or title until `reload()`; cookies, sessionStorage and localStorage live outside the page process and survive. `reload()` of a POST's result sends the form again.
- `AgentWindow` reports key while agweb is in the background, so WebKit turns on secure input for a focused password field there, blinding every event tap on the Mac; `releaseSecureInput` (Visibility.swift) turns it off. `ioreg -l -w 0 | grep SecureInputPID` shows it (the PID it names can be another app).
- WebKit numbers the middle button 4 in `WKNavigationAction.buttonNumber`, and opens nothing on a middle click by itself.
- App Nap throttles agweb in the background (a `goto` took 0.75 s instead of 0.37 s): `Browser.handle` and a recording hold a latency-critical user-initiated activity; idle pages may still nap.
- A reopened tab's sessionStorage is saved by script and put back by a document-start user script, before the page's own scripts read it.
- A WKWebView's page and its web content process run as long as anything holds the view, and the sidebar's SwiftUI rows keep closed tabs for minutes; a script still waiting on the page holds the view too, through `withTimeout`'s task, so a timed-out `eval` kept its page forever. `closeTab` therefore ends the page with the `_close` SPI; a pending script then fails at once only when the process ends with the page (a popup sharing its opener's process waits out its timeout). `launchctl print pid/<app pid>` lists an instance's own WebContent processes.

## Storage

- `~/Library/WebKit/<bundle id>/WebsiteDataStore/<uuid>/`: a named profile's WebKit data in the default root; any other root keeps it in `<root>/webkit/<uuid>/` through WebKit SPI (`Profiles.makeStore`) and its settings in the defaults domain `Agweb.settingsSuite`. The uuid is derived from the name. Fresh profiles live in memory only. The launch sweep of deleted profiles' folders is skipped when the registry can't be read.
- The root (`~/Library/Application Support/agweb/` by default): `agweb.sock`, `workspaces.json`, `profiles/profiles.json` (names; stays a plain list, since a build that can't read it would rewrite it down to one name and sweep the rest), `profiles/proxies.json` (each named profile's proxy and its password, 0600; the CLI resolves `--secret-cmd`, the app never runs one), `profiles/session-cookies/<uuid>.plist` (saved a second after each page change and on quit, restored before the profile's first load; a `kill -9` loses what changed since), `profiles/locks/<uuid>.lock`, `adblock/` (the lists, `state.json`, compiled rules in `compiled/`), `thumbnails/` (a named profile's tabs' dashboard pictures, named in `workspaces.json`; fresh workspaces keep none), `logs/`. Files carrying URLs or cookies are 0600.
- Passkeys: the person's instance keeps one login Keychain item per passkey (service `<bundle id>.passkey`); any other root keeps `<root>/passkeys.json` (0600), unless `AGWEB_PASSKEY_STORE=keychain`. `AGWEB_PASSKEY_SECONDS` shortens the time a page may ask after a command (selftest).

## Known gaps

- No CDP: Playwright and extensions can't attach; no `run-code` or tracing. Cross-origin frames are reached through WebKit's private frame tree (`Tab.subframes`): only by their refs, not CSS, role or text targets.
- `requests` and `route` see documents, fetch and XHR from a page hook (64 KB bodies), not images or scripts; no `--remove-header`. `state-save` reads localStorage only from origins open in the workspace.
- HTML5 draggables get DOM drag events: a native drag would follow the person's real mouse.
- `document.hasFocus()` is false, since the window is never key while agents work. The window reports key to WebKit only while the app is in the background (WebKit drops mouse moves otherwise), so pages also react to the person's pointer over it.
- A closed, minimized or hidden window pauses pages; screenshots refuse and recordings get no frames until `agweb show`. Agents' `open` and `dashboard` bring back only a closed window, never one the person minimized or hid.
- macOS 15 runs agweb, but a page's copy from inside a frame is refused and the secure input WebKit leaves on in the background isn't released (probably WebKit SPI missing there); CI's selftest skips those checks there.
- A profile's proxy (`WKWebsiteDataStore.proxyConfigurations`) is fixed per run: WebKit keeps a store's connections, tunnels through the old proxy included, after a change and after its workspaces close, so a change waits for the next start. Loopback, link-local and the Mac's own addresses skip the proxy, and so does WebRTC (a page's STUN request goes direct over UDP and gets the real public IP); no DNS leaks otherwise (checked in mDNSResponder's log, which names each lookup's process: on socks5 and http only the proxy resolved a page's names, for navigation, images, fetch, WebSocket and a tab restored after relaunch; WebKit did no `dns-prefetch` or `preconnect` lookups even on a direct profile). An HTTP proxy must allow CONNECT to any port (WebKit tunnels plain http:// too; stock Squid refuses port 80, and the page fails with "The network connection was lost"). Tested on the SPI store path only (test builds can't use the default root's `forIdentifier:` stores). An `https://` proxy with a self-signed or wrong-name certificate is refused before any CONNECT, with WebKit's message blaming the page's certificate; one with a trusted certificate was never tested. Checking the proxy's certificate can make trustd fetch its issuer (Let's Encrypt's `ye2.i.lencr.org`) directly. Squid and gost (in Docker) work for https pages.
- Agweb answers passkey requests with its own passkeys, or a USB security key where the person switched that on; the person's Apple Passwords passkeys need Apple's browser entitlement (applied for). Neither security key backend has been tried on a real key by us; a key holding several accounts for a site answers with the first, and NFC and Bluetooth keys aren't used.
