---
name: agweb
description: "Drive a real, visible WebKit browser from the shell with the agweb CLI (never steals focus; agents work in parallel, one workspace each). Use for any browser task: opening sites, logging in with a saved profile or a password from pass, 1Password or Bitwarden kept out of the transcript, passkeys, clicking, filling forms, reading page text or tables, screenshots, PDFs, waiting for SPAs, network calls and console errors, mocking APIs, a fake camera, microphone or location, cookies, uploads, downloads, demo videos, testing web apps. Use instead of playwright-cli."
allowed-tools: Bash(agweb:*)
---

# agweb

A browser window shared with other agents. Each task gets its own **workspace** (tabs); nothing you do activates the window or takes the keyboard from the person.

## The loop

```sh
agweb -w fix-login open https://app.example.com # one workspace per task, a unique name (fresh profile)
agweb -w fix-login snapshot # page tree with [ref=eN] handles
agweb -w fix-login click e12 # act; the reply lists what changed under ### Changes
agweb -w fix-login snapshot --diff # after goto or eval, or when the page changed by itself
agweb -w fix-login goto https://app.example.com/x # navigate; never eval "location.href=...", which tells you nothing
agweb -w fix-login close # when done; otherwise the workspace reopens after a restart, until it closes after days unused (7 by default; old tabs other than the current one go too)
```

- Name the workspace uniquely (a ticket, branch or PR id, else `task-7f3a`); a name in `agweb list` is someone else's. Never touch a workspace you didn't open: "clean up" means `close` yours (`tab-close` for one tab).
- Pass `-w` on every call or `export AGWEB_WORKSPACE=fix-login`; in zsh a function `a() { agweb -w fix-login "$@"; }` works, a variable holding `agweb -w fix-login` doesn't.
- `update`, `quit` and `close-all` hit every agent: only when the person asks.
- `goto`, `go-back` and `reload` wait for the page; after `goto`, Events say `redirected` on a login or SSO bounce.
- A tab left unused for 30 minutes (Settings) is unloaded to free memory; your next command reloads it, and Events say so: cookies, storage and history stay, but typed text, scroll position and the app's in-memory state are gone, so take a new snapshot. `agweb -w NAME unload off` keeps your workspace's pages loaded and its current tab running unseen (a page working on its own, like a game bot or a call; otherwise it slows 30 s after your last command and then freezes). A minimized, hidden or closed window still pauses it.
- Your tabs are muted unless shown; `agweb -w NAME sound on` lets them be heard behind other tabs (music), and a tab playing aloud is never unloaded.
- If Events say `the tab moved since your last command`, or `go-back` lands somewhere unexpected, `agweb history` shows the tab's entries (`-1` is where `go-back` goes).
- Keep stderr: errors say why and exit 1. Never `2>/dev/null`; chain dependent steps with `&&`, not `;`.
- Actions wait up to 5 s for their target to be visible and enabled (`--timeout=MS`, 0 to skip), so no `wait` before a `click`; `wait` for anything slower, `wait <target> --enabled` for a disabled button.
- After a snapshot, action and `wait` replies carry `### Changes`: the fetch/XHR calls they started (an action waits for them) and the tree lines added (`+`) or removed (`-`). Read it instead of taking another snapshot; over 20 lines it is cut, then `snapshot`.
- `### Events` lists alerts, confirms, popups, downloads and redirects, and what a page copied (`copied "..." to the workspace clipboard`).
- A page's copy (a copy button, `press Meta+c`) goes to the workspace's own clipboard, never the person's: `agweb --raw clipboard` prints it. To paste: `clipboard-set <text>`, then `press Meta+v` (the page's paste handler and its clipboard reads get it). Only when the person asks for it on their clipboard: `agweb --raw clipboard | pbcopy`.
- Without `-p` a workspace is fresh: its cookies, logins and passkeys live in memory and are gone at `close` or when agweb quits. Logins need a named profile (`-p`). With no profile and no credentials, `ask` the person to log in; never guess. Also `ask` for MFA codes, CAPTCHAs, a failed bot check and anything only a person may click. A Cloudflare checkbox ("Verify you are human") is the exception: the `### Page` note gives its spot, and `mousemove x y`, `mousedown`, `mouseup` there passes it.

## Targets

`e12` from the last snapshot; `role=button[name="Save"]` (name is a case-insensitive substring), `role=heading[level=1]`; `text=Save` (substring) or `text="Save"` (exact); a CSS selector. Role and text targets must match exactly one visible element; the error lists the matches with their refs. Append `>> nth=0` (or `nth=-1` for the last) to pick one of several. Open shadow roots and same-origin frames are searched; CSS looks there only when nothing the page itself matches is shown, and a selector can't cross into a shadow root or frame (target the input, not `host input`).

## Patterns

**Logging in, reusing a profile.** Logins, cookies and localStorage of `-p NAME` persist and are shared by every workspace naming it, in parallel.

```sh
agweb profile list # existing profiles and their proxies; the project's notes may name one
agweb -w task open -p work https://app.example.com # lands logged in if the profile has been used before
agweb -w task fill 'role=textbox[name="Email"]' "$EMAIL" # credentials come from the project (pass, env), never from you
agweb -w task fill 'role=textbox[name="Password"]' --secret-cmd 'pass show site' # never "$(pass show site)": that puts it in your transcript
agweb -w task click 'role=button[name="Sign in"]' && agweb -w task wait --url=/dashboard --timeout=60000
agweb -w task ask "Please sign in, then click Done" --url=/dashboard # no credentials: hand the tab to the person
```

The profile is fixed at `open`: `close`, then `open -p`. `--secret-cmd CMD` (`pass show site`, `op read op://vault/site/password`, `bw get password site`) and `--secret-file PATH` take the first line; the value shows as `<hidden>` in every reply.

HTTP Basic or Digest login (the reply's Note says `HTTP 401: … asks for a Basic login`): `agweb -w task goto URL --basic-auth USER --secret-cmd 'pass show staging'` (also on `open`; `USER:PASSWORD` for test logins). It holds for that site, in memory, until the workspace closes (with `-p`, WebKit keeps an accepted one for every workspace on the profile until agweb quits); a refused one is never sent again. With none, `ask` the person, who logs in with the bar on the tab.

A page that needs a request header: `goto URL --header 'x-tenant-id: 42'` (also `open`; that page load only).

Proxy: `agweb profile set work proxy socks5://user@host:1080 --secret-cmd 'pass show proxy'` (or `http://`, `https://`; `off` removes it). Set it before the profile's first `open`, or it waits for agweb's restart (the person's call). Nothing goes direct, but WebRTC leaks the real IP.

Passkeys: a site's passkey sign-up or sign-in button works with no prompt (Events: `passkey created for ...`). They are agweb's own, per profile: use `-p` for an account you'll come back to (a fresh workspace's go at `close`). agweb can't use the person's Apple Passwords or 1Password passkeys: for an account that has only those, `ask` the person to sign in, then add an agweb passkey in the account's security settings. `agweb -w task passkey list` lists the profile's passkeys; `passkey delete <id>` deletes one an agent made. Security keys: where the person switched them on (Settings; `agweb -w task passkey hardware` says whether), a sign-up and a sign-in no agweb passkey answers go to the YubiKey plugged into the Mac, and the person touches it and types its PIN in a bar in the tab, which you never see. So `ask` them first, then click the site's button and `wait`; Events show `security key: waiting for the person to touch it` and then `signed in to ... with the security key`. Only the person turns this on.

**Filling a form and verifying it.**

```sh
agweb -w t fill e3 "Paul" # replaces the field's text at once
agweb -w t select e4 "Green" # <select>: label or value; never click one
agweb -w t check e5
agweb -w t click 'role=button[name="Save"]'
agweb -w t wait --text="Saved" && agweb -w t console error # the result, then anything the page logged
```

`fill --submit` or `type --submit` presses Enter after.

**SPA navigation and waiting.** Prefer a condition over a pause.

```sh
agweb -w t goto https://app.example.com/orders && agweb -w t wait --load # loaded, no fetch/XHR for 0.5 s
agweb -w t click e9 && agweb -w t wait 'text=Order confirmed' # a visible element holding the text
agweb -w t wait "#spinner" --gone
agweb -w t wait --url=/orders/ --timeout=60000 # default 30000, cap 600000
agweb -w t wait 1500 # fixed pause; last resort
```

`--text=` matches anywhere in the page's text, hidden text included; `wait "text=..."` needs a visible element. `already true when wait started` means it matched text already there, such as your own message echoed in a chat. For a streamed answer, wait for the stop button or spinner to go (`wait e14 --gone`).

**Reading data.**

```sh
agweb -w t --raw markdown # an article as markdown; a listing or other page with no article comes back whole
agweb -w t --raw markdown e12 # one element; on a feed or listing, the list's container reads cleaner than the page
agweb -w t --raw markdown --all # the whole page: the article can leave out plans, prices or sidebars
agweb -w t snapshot e12 # structure: rows, cells, links, with refs to act on
agweb -w t --raw eval "[...document.querySelectorAll('table tr')].map(r => [...r.cells].map(c => c.innerText.trim()).join(' | ')).join('\n')"
agweb -w t --raw eval "[...document.querySelectorAll('article')].map(a => ({title: a.querySelector('h2')?.innerText, url: a.querySelector('a')?.href}))" # records as JSON: each field read inside its row, so a missing one can't shift the others
agweb -w t --raw eval "(el) => el.value" e5 # what a snapshot hides: values, attributes, computed style
agweb -w t --json eval "document.title" # {ok, result, page} for scripts
agweb -w t find "Invoice" # the whole page's lines holding the text, with refs, the lines above them and up to 10 after; --filename saves every match
```

`--raw` prints just the answer; Events and notes go to stderr. A snapshot prints at most 2000 lines and `markdown` 50 KB: `--filename=page.md` saves all of either, to grep or read in parts. `markdown` shortens images inlined as base64 to `![alt](<data:image/png… 4 KB cut>)`: to see one, `screenshot` its ref. `js` is `eval`, for sandboxes that refuse the word.

**Dropdowns and custom selects.**

```sh
agweb -w t select e4 "Green" # native <select>; fill also works, and for date/colour/number inputs
agweb -w t click e9 && agweb -w t click 'role=option[name="Alpha"]' # mat-select, headless UI
agweb -w t snapshot e9 # [value="Alpha"] confirms the choice
```

A custom combobox is not a field (`fill` says so): open it, then click the option.

**Iframes and frames.** Frames are in the snapshot, cross-origin ones too (a Stripe card field, a login widget). Every target reaches into a same-origin frame; in a cross-origin one, use its refs. `type` and `press` go to the focused frame.

```sh
agweb -w t fill e31 --secret-cmd 'pass show card/number' # a card field in Stripe's iframe; grouped digits are hidden too
```

**Dialogs, popups, new tabs.**

```sh
agweb -w t dialog-accept # before the click; confirm()/prompt() are dismissed by default. dialog-accept "answer" for prompt()
agweb -w t click e7 # ### Events: "alert: ...", "confirm accepted: ..."; alert text is in this reply, not later
agweb -w t click e8 # "popup opened as tab 1" and the popup is now current, with the tab list
agweb -w t wait --url=/share/ # also matches in a tab the page opens meanwhile, and says which
agweb -w t tab-list # tab-select 0 to go back; tab-close 1 when done with it
```

**Uploads and downloads.** No panels appear.

```sh
agweb -w t upload e7 ./report.pdf # the <input type=file> or the button that opens the chooser; several files allowed
agweb -w t download e8 --filename=out.csv # clicks and waits for the file (up to 2 min); replaces out.csv
```

Downloads a plain click starts go to `.agweb/` in your folder, or `--download-dir=DIR`.

**Debugging a broken page.**

```sh
agweb -w t console error # since page load
agweb -w t requests --filter=api # fetch/XHR and documents since load, numbered with status; --static lists images and scripts
agweb -w t response-body 3 # also request-headers, request-body, response-headers
agweb -w t screenshot --filename=bug.png # then look at it; screenshot e5 for one element, --full-page for all of it; a viewport shot's pixels are the CSS px mousemove takes, --full-resolution for small text (2x on Retina, 4x the image tokens)
agweb -w t highlight e5 # outline it for the person; --hide clears
```

Ads and trackers are blocked, so analytics, error reporting (Sentry, Datadog) and ad calls fail and `requests` marks them "blocked by adblock". Testing those: `agweb -w t adblock off`, then `reload`.

**Mocking an API.**

```sh
agweb -w t route "**/api/users" --status 500 --body '{"error":"boom"}' --content-type application/json
agweb -w t reload # routes apply to calls made after they are set; reload if the page fetched at load
agweb -w t requests # routed calls show "(routed)"
agweb -w t unroute # all, or unroute "**/api/users"
```

**Camera, microphone, location.** Fakes for testing video calls, recorders and maps; no prompt, no real device.

```sh
agweb -w t media ./clip.mp4 # getUserMedia gets its video as the camera and its audio as the mic, looped
agweb -w t media --mic ./speech.wav # or one at a time: --camera FILE, --mic FILE (audio or video)
agweb -w t geolocation 48.8584 2.2945 # navigator.geolocation answers with it (--accuracy=M); open pages see a change
agweb -w t media off # and geolocation off
```

Open pages get them at once (iframes after a reload). Without them a page is refused camera, mic and location. Events show each request.

**Recording a demo.**

```sh
agweb -w demo resize 1280 720 && agweb -w demo video-start demo.mp4 --size=1280x720 # about half the file of 1920x1080
# ... act at human pace (no --instant); idle time between commands is cut to 1.5 s, wait 2000 shows 2 s
agweb -w demo video-stop
```

**Alongside other agents.**

```sh
agweb list # who is here
agweb dashboard --filename=grid.png # every tab at once, to check on parallel work; dashboard --hide
agweb -w t show # put your tab in view for the person, without activating the window (brings back a window they minimized or hid)
agweb -w t scroll-into-view e40 # glide an element on screen for a screenshot or the person; actions scroll there by themselves
agweb -w t emulate --device=iphone # check the phone layout: 390x844 and an iPhone user agent, reloads; no touch or hover/pointer media
```

`--instant` skips human pacing for pointer verbs and `type`. `type` types where the focus is; `fill <target> <text>` types into an element. `mousewheel <dx> <dy> [target]` scrolls what is under the pointer (an editor or box). The rest (cookies, `state-save`/`state-load`, `pdf`, `emulate`, `drag`) is in `agweb help [command]`.

## Troubleshooting

- `no visible element matches ...`: not there yet (`wait` for it), a wrong name (`find` the text), or hidden.
- Empty or stale snapshot after navigating: `wait --load` or `wait` for a known element, then snapshot again.
- Logged out in a new workspace with the same profile: the site keeps its token in sessionStorage, which belongs to a tab, not the profile; log in again there.

## Coming from playwright-cli

- `-w name` replaces `-s=name`; `-p name` replaces `--profile`, `--persistent` and `--config`.
- No `run-code`: role and text targets, `eval`, `wait` and separate commands cover it. No `localstorage-*`: use `eval`.
- `state-load` reads playwright-cli's `state-save` files, so logins carry over: `open -p work`, then `state-load state.json`.
