---
name: agweb
description: Drive a web browser with the agweb CLI (agweb, a WebKit browser that never steals focus). Use for opening sites, clicking, filling forms, screenshots, extracting page data and web app testing.
allowed-tools: Bash(agweb:*)
---

# agweb

Use one workspace per task, `-w <name>` named after it, and close it when done. A workspace starts with a fresh profile that keeps no logins; `-p <profile>` on `open` reuses a named profile's logins instead (shared by every workspace that names it, kept across runs). Never drive another agent's workspace.

```sh
agweb -w me open https://example.com      # -p NAME to reuse a named profile's logins
agweb -w me snapshot                      # tree with [ref=eN]; refs reset on every snapshot
agweb -w me click e3                      # ref or CSS selector; the pointer glides there first
agweb -w me dblclick e3 | drag e4 e9 | mousewheel 0 600   # positive dy scrolls down
agweb -w me hover e4                      # opens hover menus
agweb -w me mousemove 200 300             # viewport point in CSS pixels
agweb -w me fill e5 "text"                # text, <select> option, date, colour, number
agweb -w me type "text"                   # at the focused element, a character at a time (no key events)
agweb -w me press Enter                   # Tab, Escape, ArrowDown, Shift+Tab, Meta+a
agweb -w me eval "() => document.title"   # runs in the page, prints JSON
agweb -w me screenshot out.png
agweb -w me video-start out.mp4           # then work as usual; video-stop prints the file
agweb -w me tab-list | tab-new [url] | tab-select 1 | tab-close
agweb -w me upload e7 ./file.pdf          # file inputs; no dialog appears
agweb -w me console                       # page console since last call
agweb -w me close                         # when done; agweb profile-list shows named profiles
```

Popups your actions open become your current tab. confirm() and prompt() are dismissed unless you run `agweb -w me dialog-accept`; everything is listed under `### Events`. Use `fill`, not `click`, for selects and date or colour inputs. Text starting with dashes goes after `--`. Take a new snapshot after anything that changes the page. Pointer and typing move at a person's pace; add `--instant` when speed matters more than looking human (long text, many clicks).
