# agweb

A browser for coding agents on macOS. Agents drive it from the shell with a playwright-cli-style command, `agweb`, while you watch every tab in one window, and it never takes the keyboard from you.

macOS only. It is built on WebKit, the engine behind Safari.

## Why

I built agweb for myself. I run several coding agents at once, and Playwright's Chrome windows kept popping up and taking my keyboard, while headless browsers got blocked by some sites and left me guessing what went wrong.

agweb is one window that never takes focus. Each agent works in its own workspace, the dashboard (⌘D) shows them all live, and when one needs me for a login or a CAPTCHA it asks and waits. Agents share my logins, type and move the pointer like a person, and get compact page snapshots that say what changed. Idle tabs are suspended, so five open pages take 0% CPU and about 590 MB.

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

More in [docs/internals.md](docs/internals.md): where data is stored, how tabs are hidden and suspended, and the remaining gaps.

## Develop

`./scripts/selftest.sh` runs every command against a local page in a separate instance; `swift test` runs the unit tests. `AGWEB_SOCKET=/path` starts a second instance beside your own. [Defuddle](https://github.com/kepano/defuddle) (MIT) is bundled for `text`.
