---
name: agweb
description: Drive a web browser with the agweb CLI (agweb, a WebKit browser that never steals focus). Use for opening sites, clicking, filling forms, screenshots, extracting page data and web app testing.
allowed-tools: Bash(agweb:*)
---

# agweb

Always pass your own session with `-s <name>` (one per agent or task). Sessions with the same `--profile` share logins.

```sh
agweb -s=me open https://example.com      # start session, optional --profile=NAME
agweb -s=me snapshot                      # tree with [ref=eN]; refs reset on every snapshot
agweb -s=me click e3                      # ref or CSS selector; the pointer glides there first
agweb -s=me hover e4                      # opens hover menus
agweb -s=me mousemove 200 300             # viewport point in CSS pixels
agweb -s=me fill e5 "text"                # text, <select> option, date, colour, number
agweb -s=me type "text"                   # at the focused element, a character at a time (no key events)
agweb -s=me press Enter                   # Tab, Escape, ArrowDown, Shift+Tab, Meta+a
agweb -s=me eval "() => document.title"   # runs in the page, prints JSON
agweb -s=me screenshot out.png
agweb -s=me video-start out.mp4         # then work as usual; video-stop prints the file
agweb -s=me tab-list | tab-new [url] | tab-select 1 | tab-close
agweb -s=me upload e7 ./file.pdf          # file inputs; no dialog appears
agweb -s=me console                       # page console since last call
agweb -s=me close                         # when done
```

Popups your actions open become your current tab. confirm() and prompt() are dismissed unless you run `agweb -s=me dialog accept`; everything is listed under `### Events`. Use `fill`, not `click`, for selects and date or colour inputs. Text starting with dashes goes after `--`. Take a new snapshot after anything that changes the page. Pointer and typing move at a person's pace; add `--instant` when speed matters more than looking human (long text, many clicks).
