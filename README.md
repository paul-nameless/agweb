# agweb

A browser for coding agents on macOS. Agents drive it from the shell with a playwright-cli-style command, `agweb`, while you watch every tab in one window, and it never takes the keyboard from you.

macOS only. It is built on WebKit, the engine behind Safari.

## Why

I built agweb for myself. I run several coding agents at once, and Playwright's Chrome windows kept popping up and taking my keyboard, while headless browsers got blocked by some sites and left me guessing what went wrong.

agweb is one window that never takes focus. Each agent works in its own workspace, the dashboard (⌘D) shows them all live, and when one needs me for a login or a CAPTCHA it asks and waits. Agents share my logins, type and move the pointer like a person, and get compact page snapshots that say what changed. Idle tabs are suspended: on my Mac, five open pages (Wikipedia, GitHub, Apple, Hacker News, MDN) settle at 0% CPU and about 590 MB. The same pages in Playwright's Chrome took about 1.6 GB with a visible window (730 MB headless), and Chrome's GPU process kept five to seven cores busy the whole time.

## Install

Needs macOS 26 or later. Build from source (Xcode 26 or later):

```sh
./scripts/build.sh                                  # build/Agweb.app
build/Agweb.app/Contents/Helpers/agweb install-cli  # links /usr/local/bin/agweb to the app
agweb install-skill                                 # teaches Claude Code and Codex to use it
```

Both are also in the Help menu and Settings. They are links into the app, so they update with it.

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

## Develop

`./scripts/selftest.sh` runs every command against a local page in a separate instance; `swift test` runs the unit tests. `AGWEB_ROOT=/tmp/dir` starts a second instance beside your own that keeps everything in that folder. [Defuddle](https://github.com/kepano/defuddle) (MIT) is bundled for `text`.
