---
name: agweb
description: Drive a real, visible web browser with the agweb CLI (WebKit; never steals focus, agents work in parallel). Use for opening sites, logging in with a saved profile, clicking, filling forms, reading page text, screenshots, PDFs, waiting for pages, checking network calls, mocking APIs, cookies, recording videos and web app testing. Use instead of playwright-cli.
allowed-tools: Bash(agweb:*)
---

# agweb

A browser window you share with other agents. Each task gets its own **workspace** (tabs); nothing you do activates the window or takes the keyboard from the person.

## The loop

```sh
agweb -w fix-login open https://app.example.com    # start your workspace (fresh profile, nothing saved)
agweb -w fix-login snapshot                         # page tree with [ref=eN] handles
agweb -w fix-login click e12                        # act on a ref
agweb -w fix-login goto https://app.example.com/x   # navigate the same tab; waits for the page (open on a running workspace does the same)
agweb -w fix-login snapshot                         # refs reset on every snapshot: take a new one after changes
agweb -w fix-login close                            # always, when done: workspaces otherwise reopen after a restart
```

- Name the workspace after your task and pass `-w` on every call (or set `AGWEB_WORKSPACE`; a shell function `a() { agweb -w task "$@"; }` saves typing, a variable holding `agweb -w task` does not work in zsh). Never touch another agent's workspace (`agweb list` shows them).
- Navigate with `goto`, `go-back` and `reload`, not `eval "location.href=…"`: they wait for the new page, so the next `wait` or target can't match the old one.
- Don't send stderr to `/dev/null`: a failed `wait`, an ambiguous target or a bad option says why there.
- Every reply ends with `### Page` (URL, title), and `### Events` when something happened: popups, dialogs, downloads, console errors.

## Logins: profiles

- `-p NAME` on `open` uses a named profile: logins, cookies and storage persist across runs and are shared by every workspace naming it.
- Without `-p` the profile is fresh and thrown away on close.
- If the project's notes name a profile, use it. If a login is needed and there is none, ask the person to log in once in the window.
- `agweb profile-list` shows profiles. `profile-delete` removes one.

## Targets

Anything taking `<target>` accepts:
- a ref from the last snapshot: `e12`;
- `role=button[name="Save"]`, where the name is a case-insensitive substring;
- `text=Save` (substring) or `text="Save"` (exact);
- a CSS selector.

Role and text targets must match exactly one visible element, so add more of the name if the error says several match. Same-origin iframes and frames are searched and appear in snapshots.

- Every snapshot, even of one element, replaces the refs.
- Actions don't wait for an element to appear: on a page still changing, `wait` for it first.
- Between your commands your tab is hidden after 30 s (the page sees `document.hidden`, animations and audio stop) and is suspended after about 4 minutes; every command wakes it first, so this costs you nothing.
- After an action, agweb waits for a navigation it caused and for fetch/XHR calls it started (up to 5 s), so the next snapshot shows the answer.

## Reading the page

```sh
agweb -w t snapshot [target]                         # whole page or one element's subtree
agweb -w t --raw text [target]                       # an article's main content (or one element) as markdown
agweb -w t --raw eval "document.body.innerText"      # text; --raw prints just the value, strings unquoted
agweb -w t eval "() => [...document.querySelectorAll('tr')].map(r => r.innerText)"
agweb -w t eval "(el) => el.value" e5                # a function gets the target element
agweb -w t screenshot [target] [--full-page] [--filename=shot.png]
agweb -w t pdf report.pdf [--format=A4] | pdf --single-page out.pdf
agweb -w t snapshot --filename=page.md               # big output to a file instead of your context
```

## Acting

```sh
agweb -w t click e3 [right|middle] | dblclick e3 | hover e3
agweb -w t fill e5 "text" [--submit]                 # replaces the field's text; --submit presses Enter
agweb -w t select e7 "Option label or value" | check e8 | uncheck e8
agweb -w t type "text" [--submit]                    # types into the focused element
agweb -w t press Enter | press Shift+Tab | keydown Shift | keyup Shift
agweb -w t drag e4 e9 | mousemove 200 300 | mousedown | mouseup | mousewheel 0 600
agweb -w t upload e7 ./file.pdf                      # file inputs; no dialog appears
agweb -w t download e8 [--filename=out.csv]          # waits for the file; other downloads go to .agweb/
agweb -w t dialog-accept ["answer"] | dialog-dismiss # how confirm()/prompt() are answered (default: dismiss)
```

- The pointer and typing move at a person's pace. Add `--instant` for long text or many steps when looking human doesn't matter.
- Use `fill` or `select`, never `click`, for `<select>`, date and colour inputs; their native pickers are blocked.

## Waiting

Don't sleep in the shell; `wait` returns as soon as its condition holds.

```sh
agweb -w t wait 1500                                 # fixed pause, in ms
agweb -w t wait e14 | wait "text=Saved"              # until it is visible
agweb -w t wait "#spinner" --gone                    # until it disappears
agweb -w t wait --text="Order confirmed" | wait --url=/dashboard
agweb -w t wait --load                               # page loaded and no fetch/XHR for 0.5 s
```

Each wait times out after 30 s by default; `--timeout=ms` changes that, up to 10 minutes. `--text` matches anywhere in the page's text, including an earlier log line; `wait "text=…"` needs a visible element holding it.

## Tabs, network, state

```sh
agweb -w t tab-list | tab-new [url] | tab-select 1 | tab-close [1]
agweb -w t requests [--filter=api] [--static] | request 3 | response-body 3
agweb -w t route "**/api/users" --body '[]' --content-type application/json [--status 500] | unroute
agweb -w t cookie-list | cookie-set name value | cookie-delete name | cookie-clear
agweb -w t state-save s.json | state-load s.json     # cookies + localStorage, Playwright format
agweb -w t console [error]                           # console since the page loaded
agweb -w t resize 390 844 | emulate --color-scheme dark
agweb -w t video-start demo.mp4 | video-chapter "Step 2" | video-stop
agweb dashboard --filename=grid.png | dashboard --hide # every agent's tabs at once, e.g. to check on parallel work
```

- `requests` and `route` cover fetch and XHR calls (plus documents in `requests`); images and scripts aren't intercepted.

## Files

Screenshots, PDFs, videos, saved state and downloads go to `.agweb/` in your current folder unless you name them: `--filename=PATH` for one file, `--download-dir=DIR` (or `AGWEB_DOWNLOAD_DIR`) for downloads a click starts.

## Coming from playwright-cli

- `-w name` replaces `-s=name`.
- `-p name` replaces `--profile <dir>`, `--persistent` and `--config`. agweb is always WebKit and always visible.
- There is no `run-code`. Use role and text targets, `eval`, `wait` and separate commands.
- `--json` prints any reply as JSON. `list --json` lists workspaces.
- `state-load` reads playwright-cli's storage-state files (`state-save` there), so logins carry over: `agweb -w t open -p work`, then `agweb -w t state-load state.json`.
- Text starting with dashes goes after `--`: `agweb -w t type -- --verbose`.
