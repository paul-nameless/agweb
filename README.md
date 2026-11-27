# agweb

A browser for coding agents on macOS, built on WebKit (Safari's engine). I run several coding agents at once, and Playwright's Chrome windows kept stealing my keyboard, while headless browsers got blocked by some sites and left me guessing what went wrong. agweb is one window that never takes focus: agents drive it from the shell with `agweb`, a playwright-cli-style command, and you watch them all live.

![The dashboard: every agent's tabs at once](docs/images/dashboard.png)

Idle tabs are suspended: on my Mac five open pages sit at 0% CPU, where Chrome's GPU process kept five to seven cores busy.

| Five idle pages   | Memory |
|-------------------|--------|
| agweb             | 590 MB |
| Headless Chrome   | 730 MB |
| Playwright Chrome | 1.6 GB |

- **Never steals focus.** No window comes to the front, nothing pops up. Dialogs, changing tabs, file pickers and downloads are answered in code.
- **You can always see it.** The dashboard (⌘D) shows every tab of every agent at once, live, with each agent's last command. And it is always a real window: some sites block headless browsers, and headless leaves you guessing what went wrong.
- **Many agents at once.** Each agent works in its own workspace with its own tabs, grouped by agent in the sidebar.
- **Log in once.** A named profile (`-p work`) keeps its logins and is shared by every agent using it, at the same time.
- **A proxy per profile.** SOCKS5, HTTP or HTTPS: `agweb profile set work proxy socks5://user:password@host:1080`.
- **Light.** Idle tabs are throttled and then suspended, so open pages cost almost nothing once nobody uses them.
- **Acts like a person.** Clicks and keys are native macOS events, and the pointer moves like a hand, so hover menus and drag-and-drop work.
- **Made for agents.** Snapshots give each element a ref that lasts while it is on the page. `snapshot --diff` and `find` show only what matters, and every action reports what it changed.
- **Light on context.** `markdown` reads a page without the base64 of inline images (a Google results page drops from 758 KB to 23 KB) and stops at 50 KB with a note saying where; a snapshot stops at 2000 lines.
- **Passwords stay out of the transcript.** `fill --secret-cmd 'pass show site'` types a secret the agent never sees in replies. 1Password and Bitwarden CLIs work too.
- **Passkeys.** Agents sign up and sign in with passkeys, no prompt. Each profile keeps its own in your Keychain. They are agweb's alone: for now they can't be exported to Apple Passwords or 1Password, and agweb can't use the passkeys you keep there. A YubiKey or other USB security key works too, for the profiles you switch it on for in Settings: you touch it and type its PIN in a bar in the tab (experimental).
- **No ads.** Ads and trackers are blocked with uBlock Origin's lists, which agweb downloads every 4 days. An agent testing analytics can turn it off for its own workspace (`agweb -w task adblock off`).
- **Fake camera, mic and location.** `agweb media clip.mp4` plays a file to pages as camera and microphone, and `agweb geolocation 48.85 2.29` sets the position; no prompts, no real devices.
- **Demo videos.** `video-start` records a tab to MP4, with the pointer and clicks drawn in.


## Install

Runs on macOS 15.4 or later; macOS 26 or later is recommended, since a few features don't work on 15. Download `Agweb.dmg` from [Releases](../../releases), drag Agweb to Applications and open it. Then:

- Help ▸ Install Command Line Tool
- Help ▸ Install Agent Skill (for Claude Code and Codex).

Both are links into the app, so they update with it.

To update, use Agweb ▸ Check for Updates… or `agweb update`. agweb never updates by itself.

To build from source instead (Xcode 26 or later):

```sh
./scripts/build.sh
build/Agweb.app/Contents/Helpers/agweb install-cli
agweb install-skill
```

## Use

```sh
agweb -w task open en.wikipedia.org/wiki/WebKit   # a workspace for this task; starts the app if needed
agweb -w task snapshot                            # the page as a tree with [ref=eN] handles
agweb -w task click 'role=button[name="Main menu"]'
```

The click's reply already says what it did, so the agent needs no second snapshot:

```
### Changes
  - navigation "Site" [ref=e2]
-   - button "Main menu" [ref=e3]
+   - button "Main menu" [checked] [expanded] [ref=e3]
+   - list [ref=e1167]
+     - listitem [ref=e1168]
+       - link "Main page" [ref=e1169]
```

`agweb help` lists every command. Settings (⌘,) has text size, dashboard columns, a CPU and memory readout and the ad blocker switch.

## Compared with playwright-cli

Same commands where possible, so agents already know them; a Playwright name it lacks suggests its own (`scroll-to` → `scroll-into-view`). On top:

- **Replies say what changed**: fetches started, lines added or removed, dialogs, popups, downloads, console errors. No snapshot after every step, so far fewer tokens.
- **Refs last** while the element is on the page.
- **`ask`** hands the tab to you for a login, MFA code or CAPTCHA, without taking focus.
- **Actions wait** for the fetches they caused, so agents rarely sleep.
- **`markdown`** returns the page's article as markdown.
- **Shared logins**: agents on one profile run at once; a Chrome profile opens in one browser only.

## Limits

- WebKit only: no Chrome DevTools Protocol, so Playwright and Chrome extensions can't attach, and Chrome-only sites may misbehave.
- `route` mocks fetch and XHR only; `requests` lists images, scripts and styles by URL only (`--static`).
- The ad blocker can't run uBlock's scripts, so YouTube ads and some "turn off your ad blocker" walls get through.
- For what it can't do, use Playwright.

## Develop

`./scripts/selftest.sh` runs every command against a local page in a separate instance; `swift test` runs the unit tests. `AGWEB_ROOT=/tmp/dir` starts a second instance beside your own that keeps everything in that folder. [Defuddle](https://github.com/kepano/defuddle) (MIT) is bundled for `markdown`.
