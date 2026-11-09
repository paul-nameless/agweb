---
name: wkb
description: Drive a web browser with the wkb CLI (WKBrowser, a WebKit browser that never steals focus). Use for opening sites, clicking, filling forms, screenshots, extracting page data and web app testing.
allowed-tools: Bash(wkb:*)
---

# wkb

Always pass your own session with `-s <name>` (one per agent or task). Sessions with the same `--profile` share logins.

```sh
wkb -s=me open https://example.com      # start session, optional --profile=NAME
wkb -s=me snapshot                      # tree with [ref=eN]; refs reset on every snapshot
wkb -s=me click e3                      # ref or CSS selector; the pointer glides there first
wkb -s=me hover e4                      # opens hover menus and tooltips
wkb -s=me fill e5 "text"                # text, <select> option, date, colour, number
wkb -s=me type "text"                   # at the focused element, one key at a time
wkb -s=me press Enter                   # Tab, Escape, ArrowDown, Shift+Tab, Meta+a
wkb -s=me eval "() => document.title"   # runs in the page, prints JSON
wkb -s=me screenshot out.png
wkb -s=me tab-list | tab-new [url] | tab-select 1 | tab-close
wkb -s=me upload e7 ./file.pdf          # file inputs; no dialog appears
wkb -s=me console                       # page console since last call
wkb -s=me close                         # when done
```

Popups your actions open become your current tab. confirm() and prompt() are dismissed unless you run `wkb -s=me dialog accept`; everything is listed under `### Events`. Use `fill`, not `click`, for selects and date or colour inputs. Text starting with dashes goes after `--`. Take a new snapshot after anything that changes the page. Pointer and typing move at a person's pace; add `--instant` when speed matters more than looking human (long text, many clicks).
