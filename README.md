# agweb

A browser for coding agents on macOS. Agents drive it from the shell with a playwright-cli-style command, `agweb`, while you watch every tab in one window, and it never takes the keyboard from you.

macOS only. It is built on WebKit, the engine behind Safari.

## Why

- **It never steals focus.** No window comes to the front, nothing pops up. Dialogs, file pickers and downloads are answered in code, so you keep typing while agents browse.
- **You can always see it.** The dashboard (⌘D) shows every tab of every agent at once, live, with each agent's last command; click one to jump in and take over. And it is always a real window: some sites block headless browsers, and headless leaves you guessing what went wrong.
- **Many agents at once.** Each agent works in its own workspace with its own tabs, grouped by agent in the sidebar.
- **Log in once.** A named profile (`-p work`) keeps its logins and is shared by every agent using it, at the same time. Chrome can't share one profile between processes. Logins and tabs survive a restart.
- **Light on your Mac.** It uses less memory and CPU than Chrome-based tools: idle tabs are throttled and then suspended, so five idle pages take about 0% CPU and 560 MB.
- **Acts like a person.** Clicks and keys are native macOS events, and the pointer moves like a hand, so hover menus and drag-and-drop work.
- **Made for agents.** Snapshots give each element a ref that lasts while it is on the page. `snapshot --diff` and `find` show only what matters, and every action reports what it changed.
- **Passwords stay out of the transcript.** `fill --secret-cmd 'pass show site'` types a secret the agent never sees in replies. 1Password and Bitwarden CLIs work too.
- **Demo videos.** `video-start` records a tab to MP4, with the pointer and clicks drawn in.

## Install

Build from source (Xcode 16 or later):

```sh
./scripts/build.sh                      # build/Agweb.app and bin/agweb
ln -s "$PWD/bin/agweb" ~/.local/bin/agweb
agweb install-skill                     # teaches Claude Code and Codex to use it
```

## Use

```sh
agweb -w task open example.com          # a workspace for this task; starts the app if needed
agweb -w task snapshot                  # the page as a tree with [ref=eN] handles
agweb -w task click e2                  # the reply says what changed
agweb -w task fill e5 "hello" --submit
agweb -w task close
```

`agweb help` lists every command. Settings (⌘,) has text size, dashboard columns and a CPU and memory readout.

## Limits

- WebKit only. There is no Chrome DevTools Protocol, so Playwright and Chrome extensions can't attach, and Chrome-only sites may misbehave.
- The network log and API mocking cover fetch and XHR, not images, scripts or page loads.
- Not tried yet against passkeys or bot checks such as Cloudflare.

More in [docs/internals.md](docs/internals.md): where data is stored, how tabs are hidden and suspended, and the remaining gaps.

## Develop

`./scripts/selftest.sh` runs every command against a local page in a separate instance; `swift test` runs the unit tests. `AGWEB_SOCKET=/path` starts a second instance beside your own. [Defuddle](https://github.com/kepano/defuddle) (MIT) is bundled for `text`.
