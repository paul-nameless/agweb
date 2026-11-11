---
name: agweb
description: Drive a real, visible web browser from the shell with the agweb CLI (WebKit; never steals focus; agents work in parallel, each in its own workspace). Use for any browser task: opening sites, logging in with a saved profile or a password from pass, 1Password or Bitwarden kept out of the transcript, clicking, filling and submitting forms, reading page text or tables, screenshots, PDFs, waiting for SPAs, checking network calls and console errors, mocking APIs, cookies, uploads and downloads, recording demo videos, and testing web apps. Use instead of playwright-cli.
allowed-tools: Bash(agweb:*)
---

# agweb

A browser window shared with other agents. Each task gets its own **workspace** (tabs); nothing you do activates the window or takes the keyboard from the person.

## The loop

```sh
agweb -w fix-login open https://app.example.com # one workspace per task, a unique name (fresh profile)
agweb -w fix-login snapshot # page tree with [ref=eN] handles
agweb -w fix-login click e12 # act; the reply waits for the fetch it caused and lists it under ### Changes
agweb -w fix-login snapshot --diff                  # only what changed; often unneeded, see below
agweb -w fix-login goto https://app.example.com/x # navigate; never eval "location.href=..."
agweb -w fix-login close # when done; otherwise the workspace reopens after a restart
```

- Name the workspace uniquely: another agent may be running the same kind of task, and two agents in one workspace act on each other's tabs. Prefer an id you already have (ticket `PROJ-123`, branch, PR number), else a task name plus a random suffix (`fix-login-7f3a`). Run `agweb list` first; a name already listed belongs to someone else.
- Pass `-w` on every call, or `export AGWEB_WORKSPACE=fix-login`. A shell function `a() { agweb -w fix-login "$@"; }` works; a variable holding `agweb -w fix-login` does not in zsh. Never touch a workspace you didn't open (`agweb list` shows them all).
- `goto`, `go-back`, `reload` wait for the new page; `goto` and `open` also report `redirected to ...` under Events when a login or SSO bounce moved you. `eval "location.href=..."` tells you nothing.
- Keep stderr. Errors say why and exit 1: an ambiguous target, a timeout over the cap, a misspelled option. Never `2>/dev/null`; chain dependent steps with `&&`, not `;`.
- Actions (not `upload`) wait up to 5 s for their target to show (`--timeout=MS`, 0 to skip; fields only need to exist), so `click` right after the page changed is fine; `wait` for anything slower. A ref from an earlier page fails with `ref eN not found`.
- After a snapshot, `click`, `fill`, `type`, `press`, `check`, `select`, `hover` and `drag` replies carry `### Changes`: the fetch/XHR calls they started and the tree lines added (`+`) or removed (`-`) under their parents, so read that before taking another snapshot. Over 20 lines it is cut; `snapshot --diff` has the rest.
- Every reply ends with `### Page` (URL, title). `### Events` lists alerts, confirms, popups, downloads and redirects; `- Console: N new errors` means run `console error`.
- Logins need a named profile (`-p`). If none exists and you have no credentials, `ask` the person to log in once; never guess. `ask` is also for MFA codes, CAPTCHAs and anything only a person may click: it shows a bar with Done on the tab, without taking focus, and returns on Done, when the target, `--text` or `--url` appears, or after `--timeout` (default 10 min, up to 1 h).
- Between commands your tab is hidden after 30 s and suspended after ~4 min; every command wakes it, so nothing is lost.

## Targets

`e12` from the last snapshot; `role=button[name="Save"]` (name is a case-insensitive substring); `text=Save` (substring) or `text="Save"` (exact); a CSS selector. Role and text targets must match exactly one visible element; the error lists the matches with their refs. Same-origin iframes and open shadow roots are searched and appear in snapshots.

## Patterns

**Logging in, reusing a profile.** Logins, cookies and localStorage of `-p NAME` persist and are shared by every workspace naming it, in parallel.

```sh
agweb profile-list # existing profiles; the project's notes may name one
agweb -w task open -p work https://app.example.com # lands logged in if the profile has been used before
agweb -w task snapshot # a login form? credentials come from the project (pass, env), never from you
agweb -w task fill 'role=textbox[name="Email"]' "$EMAIL"
agweb -w task fill 'role=textbox[name="Password"]' --secret-cmd 'pass show site'   # never "$(pass show site)": that puts it in your transcript
agweb -w task click 'role=button[name="Sign in"]' && agweb -w task wait --url=/dashboard --timeout=60000
agweb -w task ask "Please sign in, then click Done" --url=/dashboard   # no credentials: hand the tab to the person (10 min)
```

A profile can't change on an open workspace: `close` it, then `open -p`. `--secret-cmd CMD` takes the first line CMD prints (`pass show site`, `op read op://vault/site/password`, `bw get password site`); `--secret-file PATH` the first line of a file. The value is never in a reply: the field shows `[value=<hidden>]` in snapshots, and `eval`, `console` and `request-body` print `<hidden>` wherever it appears. Use them for passwords and tokens; a one-time code is short and expires, so fill it plainly.

**Filling a form and verifying it.**

```sh
agweb -w t snapshot # find the fields
agweb -w t fill e3 "Paul" # replaces the field's text at once
agweb -w t select e4 "Green" # <select>: label or value; never click one
agweb -w t check e5
agweb -w t click 'role=button[name="Save"]' # the reply waits for the fetch/XHR the click started (up to 5 s)
agweb -w t snapshot --diff # verify, when ### Changes was cut short: [value="..."], [checked], [disabled], new text
agweb -w t wait --text="Saved" && agweb -w t console error # the result, then anything the page logged
```

`fill --submit` or `type --submit` presses Enter after. A validation message is just text: `wait --text="required"` catches it. For a custom field the snapshot lists as a `combobox` without an input, see dropdowns.

**SPA navigation and waiting.** Prefer a condition over a pause.

```sh
agweb -w t goto https://app.example.com/orders && agweb -w t wait --load # loaded, no fetch/XHR for 0.5 s
agweb -w t click e9 && agweb -w t wait 'text=Order confirmed' # a visible element holding the text
agweb -w t wait "#spinner" --gone
agweb -w t wait --url=/orders/ --timeout=60000 # default 30000, cap 600000
agweb -w t wait 1500 # fixed pause; last resort
```

`--text=` matches anywhere in the page's text, off-screen and screen-reader-only text included; `wait "text=..."` needs a visible element. `already true when wait started` in the reply means it matched text the page had before, such as your own message echoed in a chat. For a streamed answer, wait for the stop button or spinner to go (`wait e14 --gone`), or for text only the finished answer has. `wait` on a target fails when several match, as the `click` after it would: use more of the name, or the ref.

**Reading data.**

```sh
agweb -w t --raw text # an article as markdown (a page with no article comes back whole; without --raw the reply says so)
agweb -w t --raw text e12 # one element as markdown
agweb -w t snapshot e12 # structure: rows, cells, links, with refs to act on
agweb -w t --raw eval "[...document.querySelectorAll('table tr')].map(r => [...r.cells].map(c => c.innerText.trim()).join(' | ')).join('\n')"
agweb -w t --raw eval "(el) => el.value" e5 # what a snapshot hides: values, attributes, computed style
agweb -w t --raw eval "(el) => el.closest('.form-field').innerText" e9 # a custom control's shown choice
agweb -w t --json eval "document.title" # {ok, result, page} for scripts
agweb -w t find "Invoice"                              # just the lines holding the text, with refs and the lines above them
```

`--raw` prints just the answer, strings unquoted. A snapshot stops at 2000 lines and says so: snapshot a subtree or use `eval`. Lists and tables: `snapshot` the container for refs, `eval` for clean rows. A ref also works as a function argument in `eval`. `js` is the same command as `eval`, for sandboxes that refuse the word.

**Dropdowns and custom selects.**

```sh
agweb -w t select e4 "Green" # native <select>; fill also works, and for date/colour/number inputs
agweb -w t click e9 && agweb -w t click 'role=option[name="Alpha"]' # mat-select, headless UI
agweb -w t snapshot e9 # [value="Alpha"] confirms the choice
```

A custom combobox is not a field: `fill` says "is not a field". Open it, then click the option (the click waits for it to show).

**Iframes and frames.** Same-origin frames are in the snapshot and every target reaches into them. A cross-origin frame shows as an empty `iframe`: open its URL in a tab instead.

```sh
agweb -w t --raw eval "[...document.querySelectorAll('iframe')].map(f => f.src).join('\n')"
agweb -w t tab-new https://widget.example.com/embed
```

**Dialogs, popups, new tabs.**

```sh
agweb -w t dialog-accept # before the click; confirm()/prompt() are dismissed by default. dialog-accept "answer" for prompt()
agweb -w t click e7 # ### Events: "alert: ...", "confirm accepted: ..."; alert text is in this reply, not later
agweb -w t click e8 # "popup opened as tab 1" and the popup is now current, with the tab list
agweb -w t tab-list # tab-select 0 to go back; tab-close 1 when done with it
```

**Uploads and downloads.** No panels appear.

```sh
agweb -w t upload e7 ./report.pdf # the <input type=file> or the button that opens the chooser; several files allowed
agweb -w t download e8 --filename=out.csv # clicks and waits for the file (up to 2 min); replaces out.csv
```

Downloads a plain click starts go to `.agweb/` in your folder, or `--download-dir=DIR`, and appear under Events.

**Debugging a broken page.**

```sh
agweb -w t console error # since page load; `- Console: N new errors` in a reply is the cue
agweb -w t requests --filter=api # fetch/XHR and documents since load, numbered with status
agweb -w t response-body 3 # also request-headers, request-body, response-headers
agweb -w t screenshot --filename=bug.png # then look at it; screenshot e5 for one element, --full-page for all of it; read a long answer with text e5
agweb -w t highlight e5 # outline it for the person; --hide clears
```

`requests` and `route` cover fetch and XHR, not images or scripts (`requests --static` lists those without details).

**Mocking an API.**

```sh
agweb -w t route "**/api/users" --status 500 --body '{"error":"boom"}' --content-type application/json
agweb -w t reload # routes apply to calls made after they are set; reload if the page fetched at load
agweb -w t requests # routed calls show "(routed)"
agweb -w t unroute # all, or unroute "**/api/users"
```

**Recording a demo.**

```sh
agweb -w demo resize 1280 720 && agweb -w demo video-start demo.mp4 --size=1280x720
# ... act at human pace (no --instant); idle time between commands is cut to 1.5 s
agweb -w demo video-stop
```

**Alongside other agents.**

```sh
agweb list # who is here; their workspaces are not yours
agweb dashboard --filename=grid.png # every tab at once, to check on parallel work; dashboard --hide
agweb -w t show # put your tab in view for the person, without activating the window
agweb -w t scroll-into-view e40 # bring an element on screen for a screenshot or the person; actions scroll by themselves
```

Use `--instant` for pointer verbs and `type` when looking human doesn't matter. Everything else (cookies, `state-save`/`state-load`, `pdf`, `emulate`, `drag`, `mousewheel`, `keydown`) is in `agweb help`.

## Troubleshooting

- `no visible element matches ...`: the page isn't there yet (`wait` for it), the name is wrong (a `role=` miss lists that role's visible elements with refs; `find` the text), or the element is hidden.
- `... matches N elements: ...`: the error lists them with refs; use the ref, or more of the name.
- `ref eN not found: the page changed`: that element is gone (removed, re-rendered, or the page navigated); `snapshot --diff` or `find` for its new ref.
- Empty or stale snapshot after navigating: `wait --load` or `wait` for a known element, then snapshot again.
- `timed out after N s waiting for ...`: the condition never held; check `### Page` for where you are, `snapshot`, `console error`. `--timeout is milliseconds, up to 600000` means the value was over the cap.
- `select opens a native picker; use: agweb select ...` / `fill ... is not a field`: see dropdowns.
- `has no size on screen`: the element is collapsed; snapshot again, or `click --js` for a scripted click.
- Logged out in a new workspace with the same profile: the site keeps its token in sessionStorage, which belongs to a tab, not the profile (a restart keeps it, a new workspace starts without it); log in again there.
- `workspace X already uses fresh profile; close it first`: profiles are fixed at `open`.
- `no file chooser opened` / `no download started within 10 s`: target the input or the button that really opens it; snapshot again.
- `unknown option --x`: a misspelling is never ignored; text starting with dashes goes after `--`.
- `the window is closed or minimized` in a reply: pages are frozen and screenshots refuse; `agweb show`.
- `no workspace 'x'`: `open` first; `-w` differs from the one you opened.

## Coming from playwright-cli

- `-w name` replaces `-s=name`; `-p name` replaces `--profile`, `--persistent` and `--config`. Always WebKit, always visible.
- No `run-code`: role and text targets, `eval`, `wait` and separate commands cover it. No `localstorage-*`: use `eval`.
- `state-load` reads playwright-cli's `state-save` files, so logins carry over: `open -p work`, then `state-load state.json`.
