---
name: agweb
description: Drive a web browser with the agweb CLI (agweb, a WebKit browser that never steals focus). Use for opening sites, clicking, filling forms, screenshots, extracting page data, checking network calls, mocking APIs and web app testing.
allowed-tools: Bash(agweb:*)
---

# agweb

Use one workspace per task, `-w <name>` named after it, and close it when done. A workspace starts with a fresh profile that keeps no logins; `-p <profile>` on `open` reuses a named profile's logins instead (shared by every workspace that names it, kept across runs). Never drive another agent's workspace.

Targets are a snapshot ref (`e3`), `role=button[name="Save"]`, `text=Save` (substring) or `text="Save"` (exact), or a CSS selector. Role and text targets must match one visible element; same-origin iframes are searched too.

```sh
agweb -w me open https://example.com      # -p NAME to reuse a named profile's logins
agweb -w me snapshot [target]             # tree with [ref=eN]; refs reset on every snapshot
agweb -w me click e3 [right|middle]       # the pointer glides there first
agweb -w me dblclick e3 | drag e4 e9 | hover e4 | mousewheel 0 600
agweb -w me mousemove 200 300 | mousedown | mouseup     # viewport CSS pixels; moves drag while down
agweb -w me check e6 | uncheck e6 | select e7 "Two"
agweb -w me fill e5 "text" [--submit]     # text, <select> option, date, colour, number
agweb -w me type "text" [--submit]        # at the focused element, a character at a time (no key events)
agweb -w me press Enter | keydown Shift | keyup Shift
agweb -w me eval "() => document.title"   # in the page, prints JSON; eval "(el) => el.value" e5 for one element
agweb -w me --raw eval "document.body.innerText"   # just the value, strings unquoted
agweb -w me screenshot [target] [--full-page] [--filename=out.png]
agweb -w me download e8 [--filename=out.pdf]       # other downloads land in ~/Downloads, listed under ### Events
agweb -w me requests [--filter=api] | request 3 | response-body 3
agweb -w me route "**/api/users" --body '[]' --content-type application/json | unroute
agweb -w me cookie-list | cookie-set k v | state-save s.json | state-load s.json
agweb -w me resize 390 844                # this tab's viewport only
agweb -w me video-start out.mp4 | video-chapter "Step 1" | video-stop
agweb -w me tab-list | tab-new [url] | tab-select 1 | tab-close
agweb -w me upload e7 ./file.pdf          # file inputs; no dialog appears
agweb -w me console [error]               # page console since load
agweb -w me close                         # when done; agweb profile-list shows named profiles
```

Popups your actions open become your current tab. confirm() and prompt() are dismissed unless you run `agweb -w me dialog-accept [answer]`; everything is listed under `### Events`. Use `fill` or `select`, not `click`, for selects and date or colour inputs. Text starting with dashes goes after `--`. Take a new snapshot after anything that changes the page. `--filename` writes snapshot, eval or request output to a file; `--json` prints one JSON object. Pointer and typing move at a person's pace; add `--instant` when speed matters more than looking human. There is no `run-code` or `wait`: use targets, `eval`, and `sleep` in the shell.
