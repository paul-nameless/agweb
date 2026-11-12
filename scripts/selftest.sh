#!/bin/sh
# Every verb, workspaces in parallel, against a local page, in a separate agweb instance with its own root
# (AGWEB_ROOT: socket, profiles, WebKit data, settings, window frame), so the browser you use is untouched. Fails if agweb ever becomes the frontmost app.
# Exits with the number of failed checks.
set -u
cd "$(dirname "$0")"
dir=$(mktemp -d /tmp/agweb-test.XXXXXX)
export AGWEB_ROOT="$dir/r"
unset AGWEB_PROFILE AGWEB_WORKSPACE
# Every command at once (the checks about human pace use `paced`), and tabs hide 3 s after a command, not 30.
export AGWEB_INSTANT=1 AGWEB_AWAKE_SECONDS=3
agweb=${AGWEB_CLI:-$PWD/../bin/agweb}
cp testpage.html "$dir/index.html"
cp frame.html frames.html side.html redirect.html "$dir/"
# The test build's bundle id (build.sh --test adds .test); the person's frame is checked under the id without it.
test_domain=$(plutil -extract CFBundleIdentifier raw "$(dirname "$(realpath "$agweb")")/../Info.plist")
domain=${test_domain%.test}
person_frame=$(defaults read $domain agwebMainFrame 2>/dev/null)
# Settings and the frame of this root (Agweb.settingsSuite).
suite=agweb.root$(printf %s "$AGWEB_ROOT" | tr / _)
defaults write "$suite" agwebMainFrame -string "{{200, 200}, {900, 600}}"
# A store no registry names, before any registry exists: the first launch must not sweep it.
unnamed="$AGWEB_ROOT/webkit/00000000-0000-0000-0000-000000000001"
mkdir -p "$unnamed"

# A free port the server really answers on, or stop: without it every check fails for the same reason.
server=
trap '"$agweb" quit >/dev/null 2>&1; [ -n "$server" ] && kill $server 2>/dev/null; wait 2>/dev/null; for d in "$suite" "agweb.root$(printf %s "$dir/o" | tr / _)"; do defaults delete "$d" 2>/dev/null; rm -f ~/Library/Preferences/"$d".plist; done; rm -r "$dir"' EXIT
for _ in 1 2 3; do
    port=$(/usr/bin/python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
    (script="$PWD/server.py"; cd "$dir" && exec /usr/bin/python3 "$script" "$port" >"$dir/server.log" 2>&1) &
    server=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do curl -sf -o /dev/null "http://127.0.0.1:$port/index.html" && break 2; sleep 0.3; done
    kill $server 2>/dev/null
    server=
done
[ -n "$server" ] || { echo "the test server did not start; see $dir/server.log"; cat "$dir/server.log"; exit 1; }
u="http://127.0.0.1:$port/index.html"
# Downloads and files nobody named land in the test's folder: the checkout may sit under ~/Downloads, which would
# make every rebuilt (newly signed) test app ask for access to it.
export AGWEB_DOWNLOAD_DIR="$dir/downloads"
# Installs land here, never in the person's /usr/local/bin or agents.
export AGWEB_HOME="$dir/home" AGWEB_CLI_LINK="$dir/usr/bin/agweb"
cd "$dir"

failures=0
fail() { printf 'FAIL  %s\n' "$1"; failures=$((failures + 1)); }
now() { /usr/bin/python3 -c 'import time; print(time.time())'; }
frontmost() { lsappinfo info -only bundleid "$(lsappinfo front)" | sed 's/.*="\(.*\)"/\1/'; }

# run <expected status: 0 or 1> <pattern> <agweb args...>: the exit status and the output (stdout+stderr) must match.
run() {
    want=$1 pattern=$2; shift 2
    out=$("$agweb" "$@" 2>&1); status=$?
    [ "$status" -ne 0 ] && status=1
    if [ "$status" -eq "$want" ] && printf '%s' "$out" | grep -q -- "$pattern"; then
        printf 'ok    agweb %s\n' "$*"
    else
        printf 'FAIL  agweb %s\n      expected exit %s and: %s\n%s\n' "$*" "$want" "$pattern" "$(printf '%s' "$out" | sed 's/^/      | /')"
        failures=$((failures + 1))
    fi
    case "$(frontmost)" in "$domain"|"$test_domain") fail "agweb became the frontmost app after: agweb $*" ;; esac
}
check() { run 0 "$@"; }
paced() { AGWEB_INSTANT=; check "$@"; AGWEB_INSTANT=1; }
fails() { run 1 "$@"; }
lacks() {
    pattern=$1; shift
    out=$("$agweb" "$@" 2>&1) || { fail "agweb $*: failed: $out"; return; }
    if printf '%s' "$out" | grep -q -- "$pattern"; then fail "agweb $*: the output contains $pattern"; else printf 'ok    agweb %s (no %s)\n' "$*" "$pattern"; fi
}
# Waits for a quit instance to let go of its socket.
stopped() {
    for _ in 1 2 3 4 5 6 7 8 9 10; do [ -e "$AGWEB_ROOT/agweb.sock" ] || break; sleep 0.5; done
    sleep 1
}
video_seconds() { sed -n 's/.* frames, \([0-9.]*\) s.*/\1/p'; }

check "Title: agweb test" -w alpha open "$u" -p selftest-alpha
[ -d "$unnamed" ] || fail "a launch without a profile registry swept the root's WebKit data"
alpha_store=$(/usr/bin/python3 -c 'import hashlib, uuid; print(uuid.UUID(bytes=hashlib.sha256(b"agweb.profile.selftest-alpha").digest()[:16]))')
ls "$AGWEB_ROOT/webkit" 2>/dev/null | grep -qix "$alpha_store" || fail "the profile's WebKit data is not in the root: $(ls "$AGWEB_ROOT" "$AGWEB_ROOT/webkit" 2>&1)"
ls ~/Library/WebKit/$domain/WebsiteDataStore/ 2>/dev/null | grep -qix "$alpha_store" && fail "a test profile's WebKit data went into the person's folder"
check "Title: agweb test" -w beta open "$u?beta" -p selftest-shared
check 'button "Press me" \[ref=e2\]' -w alpha snapshot
check "Linked $AGWEB_CLI_LINK" install-cli
check "installed at $AGWEB_CLI_LINK" install-cli --check
[ -x "$AGWEB_CLI_LINK" ] || fail "install-cli: $AGWEB_CLI_LINK does not lead to the CLI"
mkdir -p "$AGWEB_HOME/.codex/skills/agweb"
check "Codex: another agweb skill is there; left alone" install-skill
check "Claude Code: installed" install-skill --check
[ -f "$AGWEB_HOME/.claude/skills/agweb/SKILL.md" ] || fail "install-skill: no SKILL.md through the link"
check 'option "Two"' -w alpha snapshot
check "Page" -w alpha click e2
check "Page" -w alpha fill '#q' hello
check "Page" -w alpha press Enter
fails "native picker" -w alpha click '#s'
check "Page" -w alpha fill '#s' Two
check "Page" -w alpha eval "() => { s.focus() }"
fails "native picker" -w alpha press ArrowDown
check "Page" -w alpha fill '#pw' secret
check 'textbox \[value=<hidden>\]' -w alpha snapshot
lacks "secret" -w alpha snapshot
printf 's3cr3t tok3n\n' > "$dir/secret.txt"
check "Page" -w alpha fill '#q' --secret-cmd 'printf "s3cr3t tok3n\nsecond line"'
check 'textbox "Search" \[value=<hidden>\]' -w alpha snapshot
lacks "s3cr3t" -w alpha snapshot
check '^12$' -w alpha --raw eval 'q.value.length'
check '^<hidden>$' -w alpha --raw eval 'q.value'
lacks "s3cr3t" -w alpha --json eval '[q.value, JSON.stringify(q.value)]'
check '^<hidden>$' -w alpha --raw eval 'encodeURIComponent(q.value)'
check "Page" -w alpha eval "async () => { await fetch('/index.html?sec', { method: 'POST', body: q.value }) }"
sleep 0.3
n=$("$agweb" -w alpha requests --filter 'sec$' | sed -n 's/^\([0-9]*\)\. .*/\1/p' | tail -1)
check '^<hidden>$' -w alpha --raw request-body "${n:-0}"
check "Page" -w alpha fill '#q' --secret-cmd "printf '%s' 'Str0ng-P@ss/\"x'"
check '^<hidden>$' -w alpha --raw eval 'encodeURIComponent(q.value)'
check '^p=<hidden>$' -w alpha --raw eval 'new URLSearchParams({ p: q.value }).toString()'
lacks "Str0ng" -w alpha eval 'JSON.stringify(q.value)'
lacks "Str0ng" -w alpha --json eval 'q.value'
check "Page" -w alpha fill '#q' ''
check "Page" -w alpha fill '#q' --secret-file "$dir/secret.txt"
check '^12$' -w alpha --raw eval 'q.value.length'
out=$("$agweb" -w alpha fill '#q' --secret-cmd 'echo leaked; exit 3' 2>&1) && fail "a failing --secret-cmd filled the field"
printf '%s' "$out" | grep -q "exited with status 3" || fail "a failing --secret-cmd did not say so: $out"
printf '%s' "$out" | grep -q leaked && fail "a failing --secret-cmd printed what the command printed"
fails "cannot read" -w alpha fill '#q' --secret-file "$dir/nope.txt"
fails "the secret is empty" -w alpha fill '#q' --secret-cmd true
fails "over 4096 bytes" -w alpha fill '#q' --secret-cmd 'cat /dev/zero'
fails "over 4096 bytes" -w alpha fill '#q' --secret-file /dev/zero
check "Page" -w alpha fill '#q' --secret-cmd 'echo short; yes'
check '^5$' -w alpha --raw eval 'q.value.length'
fails "no text" -w alpha fill '#q' x --secret-cmd 'printf abcd'
fails "work with fill" -w alpha type --secret-cmd 'printf abcd'
check "Page" -w alpha fill '#q' hello
check "file chooser got" -w alpha upload '#file' /etc/hosts
fails "no file chooser opened" -w alpha upload e2 /etc/hosts
fails "no such file" -w alpha upload '#file' /nonexistent/agweb.xlsx
check "alert: hi" -w alpha click '#al'
check '"click trusted=true","keydown Enter trusted=true","submit:hello","file:hosts"' -w alpha eval 'window.log'
check '"2"' -w alpha eval "() => document.querySelector('#s').value"

echo "== the pointer glides: trusted mousemoves arrive, :hover follows, typing is per key"
check "Page" -w alpha mousemove 5 5 --instant
check 'false' -w alpha eval "() => { moves = 0; return document.querySelector('#b').matches(':hover') }"
paced "Page" -w alpha hover '#b'
check 'true' -w alpha eval "() => document.querySelector('#b').matches(':hover') && moves > 5"
fails "inside the" -w alpha mousemove nan 5
fails "inside the" -w alpha mousemove 5 99999
check "Page" -w alpha eval "() => { q.focus(); q.setSelectionRange(99, 99); inputs = 0 }"
start=$(now)
paced "Page" -w alpha type ' world'
/usr/bin/python3 -c "import sys; sys.exit(0 if $(now) - $start >= 0.6 else 1)" || fail "typing ' world' took under 0.6 s; it should go at a person's pace"
check "Page" -w alpha type '!' --instant
check '\["hello world!",7\]' -w alpha eval '[q.value, inputs]'
check "Page" -w alpha eval "() => { window.keys = []; q.addEventListener('keydown', e => keys.push(e.key + (e.isTrusted ? '' : '!'))) }"
paced "Page" -w alpha type 'Ab é'
check '"A","b"," "\]' -w alpha eval 'keys'
check 'hello world!Ab é' -w alpha eval 'q.value'
check "Page" -w alpha fill '#q' 'hello world!'

echo "== output modes and files"
check '^hello world!$' -w alpha --raw eval 'q.value'
check '"ok":true' -w alpha --json eval '1'
check '"workspaces":\[{' list --json
check "$dir/snap.md" -w alpha snapshot --filename="$dir/snap.md"
grep -q 'button "Press me"' "$dir/snap.md" || fail "snapshot --filename did not write the tree"
check "$dir/el.png" -w alpha screenshot '#b' --path="$dir/el.png"
[ "$(sips -g pixelWidth "$dir/el.png" | awk '/pixelWidth/ {print $2}')" -lt 400 ] || fail "screenshot '#b' is not just the button"
check "continues [0-9]* px below the viewport" -w alpha screenshot --filename="$dir/top.png"
check "Screenshot" -w alpha screenshot --full-page --filename="$dir/full.jpg"
[ "$(sips -g pixelHeight "$dir/full.jpg" | awk '/pixelHeight/ {print $2}')" -gt 3000 ] || fail "screenshot --full-page is not the whole page"
check '^\[Next page\](/index.html?next)$' -w alpha --raw text 'a'
check "$dir/page.md" -w alpha text --filename="$dir/page.md"
check "no article here" -w alpha text
lacks "no article" -w alpha --raw text
grep -q 'Press me' "$dir/page.md" || fail "text --filename did not write the page"
check '"undefined"' -w alpha eval 'typeof Defuddle'
check "Page" -w alpha fill '#q' again --submit
check '"submit:again"' -w alpha eval 'log'
check "Page" -w alpha click '#b' --js
check '"click trusted=false"' -w alpha eval 'log'

echo "== locators, iframes, checkboxes, buttons and keys"
ref=$("$agweb" -w alpha snapshot | sed -n 's/.*button "Press me" \[ref=\(e[0-9]*\)\].*/\1/p')
check "button \"Press me\" \[ref=$ref\]" -w alpha snapshot
check "no changes since the last snapshot" -w alpha snapshot --diff
check "Page" -w alpha eval "() => { const b = document.createElement('button'); b.id = 'added'; b.textContent = 'Added later'; document.querySelector('#f').append(b) }"
check '^+ *- button "Added later"' -w alpha --raw snapshot --diff
check '^1 line matching "added later"' -w alpha --raw find 'added later'
check '  - button "Added later" \[ref=' -w alpha find 'Added later'
fails "nothing on the page matches" -w alpha find 'no such words'
added=$("$agweb" -w alpha find 'Added later' | sed -n 's/.*"Added later" \[ref=\(e[0-9]*\)\].*/\1/p')
check "Page" -w alpha eval "() => document.querySelector('#added').remove()"
fails "ref $added not found: the page changed" -w alpha click "$added"
fails 'visible buttons: button "Press me" \[ref=' -w alpha click 'role=button[name="Pres me"]' --timeout=0
check "Page" -w alpha eval "() => { setTimeout(() => { const b = document.createElement('button'); b.id = 'later'; b.textContent = 'Later'; b.onclick = () => log.push('later'); document.body.append(b) }, 600) }"
check "Page" -w alpha click '#later'
check '"later"' -w alpha eval 'log'
check "Page" -w alpha eval "() => { const b = document.createElement('button'); b.id = 'grow'; b.textContent = 'Grow'; b.onclick = () => { const p = document.createElement('p'); p.textContent = 'Grown by a click'; b.after(p) }; document.body.append(b) }"
check "Snapshot" -w alpha snapshot
check '^+ *- text: "Grown by a click"' -w alpha --raw click '#grow'
check '^- call: POST http.*index.html?api => 501' -w alpha --raw click '#api'
check "Title" -w refs open "$u?refs"
old=$("$agweb" -w refs snapshot | sed -n 's/.*button "Press me" \[ref=\(e[0-9]*\)\].*/\1/p')
check "Title" -w refs goto "$u?refs2"
start=$(now)
fails "ref $old not found" -w refs click "$old"
/usr/bin/python3 -c "import sys; sys.exit(0 if $(now) - $start < 2 else 1)" || fail "a ref from the page before waited instead of failing at once"
lacks "button \"Press me\" \[ref=$old\]" -w refs snapshot
check '"changes":\["- call: POST http' -w refs --json click '#api'
check "closed" -w refs close
check "Title" -w asker open "$u?ask"
check "Page" -w asker eval "() => { setTimeout(() => { document.body.append('Logged in as tester') }, 800) }"
"$agweb" -w asker ask "Log in please" --text='Logged in as tester' --timeout=10000 >"$dir/ask.out" 2>&1 &
asking=$!
sleep 0.4
check '"asking":"Log in please"' list --json
wait $asking || fail "ask did not return when its text appeared: $(cat "$dir/ask.out")"
grep -q 'text "Logged in as tester" (the person didn' "$dir/ask.out" || fail "ask's reply: $(cat "$dir/ask.out")"
check '"asking":null' list --json
fails "timed out after 0.5 s waiting for the person" -w asker ask "Nobody will click" --timeout=500
check "closed" -w asker close
check '  - button "Inner button"' -w alpha snapshot
check "Page" -w alpha click 'role=button[name="inner"]'
check "Page" -w alpha click 'text=Inner button'
check '\["inner","inner"\]' -w alpha eval 'log.filter(x => x === "inner")'
fails 'matches .* elements: button "Press me" \[ref=e2\]; ' -w alpha click 'role=button'
check '^- form' -w alpha snapshot '#f'
lacks 'Press me' -w alpha snapshot '#f'
check '^inner$' -w alpha --raw eval '(el) => el.id' 'role=button[name="inner"]'
# eval hands over a target in a shadow root and in an iframe inside an iframe.
check "Page" -w ev open "$u"
check "Page" -w ev eval "() => { const h = document.createElement('div'); document.body.append(h); h.attachShadow({ mode: 'open' }).innerHTML = '<button>Shadow knob</button>'; const f = document.createElement('iframe'); f.srcdoc = \"<iframe srcdoc='<button>Nested knob</button>'></iframe>\"; document.body.append(f); }"
check "Page" -w ev wait 'role=button[name="Nested knob"]'
check '^Shadow knob$' -w ev --raw eval '(el) => el.textContent' 'role=button[name="Shadow knob"]'
check '^Nested knob$' -w ev --raw eval '(el) => el.textContent' 'role=button[name="Nested knob"]'
# A name longer than 120 characters ends in …, and the cut name still finds its element.
check "Page" -w ev eval "() => { const b = document.createElement('button'); b.textContent = 'Long word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word'; document.body.append(b); }"
check 'button "Long word word word word word word word word word word word word word word word word word word word word word word word…"' -w ev snapshot
check '^BUTTON$' -w ev --raw eval '(el) => el.tagName' 'role=button[name="Long word word word word word word word word word word word word word word word word word word word word word word word…"]'
check "closed" -w ev close
check "Page" -w alpha check 'text=Remember me'
check "Page" -w alpha check '#r2'
check '\[true,true\]' -w alpha eval '[cb.checked, r2.checked]'
check "Page" -w alpha check 'role=radio >> nth=0'
check '\[true,false\]' -w alpha eval '[r1.checked, r2.checked]'
check "Page" -w alpha check 'input[type=radio] >> nth=-1'
check "already true" -w alpha wait 'role=button[name*="press"]'
check "Page" -w alpha uncheck '#cb'
check 'false' -w alpha eval 'cb.checked'
fails "not a checkbox" -w alpha check '#b'
check "Page" -w alpha select '#s' One
fails "not a <select>" -w alpha select '#q' x
check "context menu suppressed" -w alpha click '#b' right
check "Page" -w alpha keydown Shift
check "Page" -w alpha mousemove 5 5 --instant
check "Page" -w alpha mousedown
check "Page" -w alpha mouseup
check "Page" -w alpha keyup Shift
check "Page" -w alpha click '#b' middle
check '\["2","0+shift","1"\]' -w alpha eval 'downs.slice(-3)'
check '"contextmenu"' -w alpha eval 'log'
check "Page" -w alpha highlight '#b'
check '^1$' -w alpha --raw eval "document.querySelectorAll('div[style*=\"2147483647\"]').length"
check "Page" -w alpha highlight --hide
check '^0$' -w alpha --raw eval "document.querySelectorAll('div[style*=\"2147483647\"]').length"
fails "did you mean tab-list" -w alpha tabs

echo "== network, routes, downloads and prompts"
check "Page" -w alpha click '#slow'
check '^1$' -w alpha --raw eval 'window.slowDone'
check "Page" -w alpha click '#api'
sleep 0.5
check 'POST\] http.*index.html?api => 501 \[fetch\]' -w alpha requests --filter 'api$'
n=$("$agweb" -w alpha requests --filter 'api$' | sed -n 's/^\([0-9]*\)\. .*/\1/p' | tail -1)
check '^x=1$' -w alpha request-body "${n:-0}"
check 'content-type: text/html' -w alpha response-headers "${n:-0}"
check "### Request ${n:-0}" -w alpha request "${n:-0}"
check 'x-req: yes' -w alpha request-headers "${n:-0}"
check 'Unsupported method' -w alpha response-body "${n:-0}"
fails "no request 999" -w alpha request 999
check "get 418" -w alpha route '**/index.html?api' --status 418 --body '{"mocked":true}' --content-type application/json --header 'x-test: 1'
check '\*\*/index.html?api => 418 application/json' -w alpha route-list
check "Page" -w alpha click '#api'
sleep 0.5
check '^{"mocked":true}$' -w alpha --raw eval 'api'
check '=> 418 (routed)' -w alpha requests --filter 'api$'
check '\[418,"{\\"mocked\\":true}","1"\]' -w alpha eval "() => new Promise(r => { const x = new XMLHttpRequest(); x.open('GET', '/index.html?api'); x.onload = () => r([x.status, x.responseText, x.getResponseHeader('x-test')]); x.send() })"
check "removed 1 routes" -w alpha unroute
check "no routes" -w alpha route-list
check "frame.html" -w alpha requests --static
check "api" -w alpha requests --clear
check "no requests" -w alpha requests --filter 'api$'
check "$dir/dl/saved.html" -w alpha download '#dl' --filename="$dir/dl/saved.html"
[ -s "$dir/dl/saved.html" ] || fail "download did not save the file"
check "$dir/dl/saved.html" -w alpha download '#dl' --filename="$dir/dl/saved.html"
[ -e "$dir/dl/saved (1).html" ] && fail "download --filename did not replace the file there"
check "Page" -w alpha click '#dl' --download-dir="$dir/dd"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$dir/dd/saved.html" ] && break; sleep 0.3; done
[ -s "$dir/dd/saved.html" ] || fail "a download the click started did not go to --download-dir"
check 'prompt() gets "Paul"' -w alpha dialog-accept Paul
check 'answered with "Paul"' -w alpha click '#pr'
check "will be dismissed" -w alpha dialog-dismiss

echo "== cookies, storage state, waits, colour scheme, pdf and resize"
check "Title" -w st open "$u"
check "set - token=abc" -w st cookie-set token abc --httpOnly
check "token=abc; domain=127.0.0.1" -w st cookie-list
check '^""$' -w st eval 'document.cookie'
check "Page" -w st eval "() => { localStorage.setItem('k', 'v1'); document.cookie = 'c1=one' }"
check "sameSite=lax" -w st cookie-set lax v --sameSite=Lax
check "token=abc" -w st cookie-get token
fails "no cookie nope" -w st cookie-get nope
expires=$(($(date +%s) + 86400))
check "set - sec=1; domain=127.0.0.1; path=/; expires=$expires; secure" -w st cookie-set sec 1 --domain=127.0.0.1 --expires=$expires --secure
check "deleted 1 cookies" -w st cookie-delete sec
check "$dir/state.json" -w st state-save "$dir/state.json"
grep -q '"name":"k","value":"v1"' "$dir/state.json" || fail "state-save left out localStorage"
check "deleted 3 cookies" -w st cookie-clear
check "no cookies" -w st cookie-list
check "Title" -w st2 open
check "localStorage waits for" -w st2 state-load "$dir/state.json"
check "Title" -w st2 goto "$u"
check '\["v1",.*c1=one' -w st2 eval '[localStorage.getItem("k"), document.cookie]'
check "lax=v.*sameSite=lax" -w st2 cookie-list
check "waited 300 ms" -w st2 wait 300
check "Page" -w st2 eval "() => { setTimeout(() => { const p = document.createElement('p'); p.id = 'late'; p.textContent = 'Arrived late'; document.body.prepend(p) }, 500) }"
check "for #late" -w st2 wait '#late'
check 'text "Arrived late"' -w st2 wait --text='Arrived late'
check 'already true when wait started: text "Arrived late"' -w st2 wait --text='Arrived late'
check "Page" -w st2 eval "() => { const p = document.createElement('p'); p.textContent = 'filler '.repeat(30) + 'the long tail'; document.body.append(p) }"
check "text=the long tail" -w st2 wait 'text=the long tail' --timeout=1000
check "Page" -w st2 eval "() => { setTimeout(() => late.remove(), 300) }"
check "#late to go" -w st2 wait '#late' --gone
fails "timed out" -w st2 wait '#nothing' --timeout=300
fails "now: no visible element matches role=button\[name=\"Kopieren\"\]; visible buttons" -w st2 wait 'role=button[name="Kopieren"]' --timeout=300
check "nothing visible matches text=\"Never here\"" -w st2 wait 'text="Never here"' --gone
fails "invalid selector" -w st2 wait 'bad[[' --timeout=5000
fails "matches [0-9]* elements" -w st2 wait 'role=button' --timeout=5000
check "network to go quiet" -w st2 wait --load
check "Page" -w st2 emulate --color-scheme light
check 'false' -w st2 eval "matchMedia('(prefers-color-scheme: dark)').matches"
check "Page" -w st2 emulate --color-scheme dark
check 'true' -w st2 eval "matchMedia('(prefers-color-scheme: dark)').matches"
check "$dir/page.pdf" -w st2 pdf "$dir/page.pdf" --format A4
LC_ALL=C grep -qa '/Type */Page' "$dir/page.pdf" || fail "pdf wrote no pages"
check "$dir/one.pdf" -w st2 pdf --single-page --filename="$dir/one.pdf"
check "viewport is 400x300" -w st2 resize 400 300
check '\[400,300\]' -w st2 eval '[innerWidth, innerHeight]'
check "Page" -w st2 click '#b'
check "Screenshot" -w st2 screenshot --filename="$dir/small.png"
[ "$(sips -g pixelHeight "$dir/small.png" | awk '/pixelHeight/ {print $2}')" -le 600 ] || fail "a 400x300 viewport's screenshot is taller than the viewport"
check "Page" -w st2 resize 1600 1200
check '\[1600,1200\]' -w st2 eval '[innerWidth, innerHeight]'
check "workspace st closed" -w st close
check "workspace st2 closed" -w st2 close

echo "== double click, drag and wheel"
check "Page" -w alpha dblclick '#b'
check '^1$' -w alpha eval 'dbl'
check "Page" -w alpha drag '#rng' '#lane'
check 'true' -w alpha eval "() => +rng.value > 50"
check "HTML5-draggable" -w alpha drag '#card' '#lane'
check '"card"' -w alpha eval 'dropped'
check "Page" -w alpha eval "() => scrollTo(0, 0)"
check "Page" -w alpha mousewheel 0 400
check 'true' -w alpha eval "() => scrollY > 300"
check "Page" -w alpha mousewheel 0 -400 --instant
check '^0$' -w alpha eval 'scrollY'
fails "positive dy" -w alpha mousewheel 0 down

echo "== recording"
fails "must end in .mp4" -w alpha video-start "$dir"
fails "max-idle takes seconds" -w alpha video-start "$dir/v.mp4" --max-idle=soon
fails "must end in .mp4" -w alpha video-start --filename="$dir/v.txt"
fails "size is WIDTHxHEIGHT" -w alpha video-start "$dir/v.mp4" --size=big
fails "video-chapter is gone" -w alpha video-chapter x
check "recording alpha" -w alpha video-start "$dir/v.mp4"
check "Page" -w alpha hover '#al'
check "Page" -w alpha eval "async () => { for (const c of ['#fee', '#efe', '#eef']) { document.body.style.background = c; await new Promise(r => setTimeout(r, 150)) } }"
fails "already recording" -w alpha video-start "$dir/w.mp4"
check "frames, " -w alpha video-stop
LC_ALL=C grep -qa moov "$dir/v.mp4" || fail "the video has no index (moov)"
fails "not recording" -w alpha video-stop
# A page that never stops changing: time between commands is still cut to max-idle.
check "Page" -w alpha eval "() => { window.blink = setInterval(() => document.body.style.background = document.body.style.background ? '' : '#eee', 100) }"
check "recording" -w alpha video-start "$dir/idle.mp4" --max-idle=0.5
sleep 3
seconds=$("$agweb" -w alpha video-stop | video_seconds)
/usr/bin/python3 -c "import sys; sys.exit(0 if 0 < ${seconds:-0} < 2.5 else 1)" || fail "3 s idle with --max-idle=0.5 gave a ${seconds:-?} s video"
check "Page" -w alpha eval "() => { clearInterval(window.blink); document.body.style.background = '' }"

echo "== tabs and popups"
check "popup opened as tab 1" -w alpha click '#pop'
lacks "### Tabs" -w alpha eval 1
check "1: (current)" -w alpha tab-list
check "0: (current)" -w alpha tab-select 0
check "1: (current)" -w alpha tab-select 1
fails "no tab 9" -w alpha tab-close 9
check "0: (current)" -w alpha tab-close 1
check "index.html?tabnew" -w alpha tab-new "$u?tabnew"
check "0: (current)" -w alpha tab-close 1
check "Page" -w alpha eval "() => { setTimeout(() => open('/index.html?ad'), 1000) }"
sleep 2
check "0: (current)" -w alpha tab-list
check "opened in tab 1: .*index.html?next" -w alpha click 'text=Next page' middle
check "0: (current)" -w alpha tab-close 1
check '      - generic "deploy to TEST" \[ref=' -w alpha snapshot '#dt'
check 'cell "deploy to TEST"' -w alpha snapshot '#dt'
check '^  - button "Far button"' -w alpha snapshot '#rbm'
check 'dialog' -w alpha find "Far button"
check "scrolled" -w alpha scroll-into-view '#far'
check "already in view" -w alpha scroll-into-view '#far'
check '"in view"' -w alpha js "(el) => el.getBoundingClientRect().bottom <= innerHeight ? 'in view' : 'not'" '#far'
check "^scrolled" -w alpha scroll-into-view '#deep'
check '"inner scrolled"' -w alpha js "() => box.scrollTop > 0 ? 'inner scrolled' : 'not'"
check "Page" -w alpha eval "scrollTo(0, 0)"
start=$(now)
paced "^scrolled" -w alpha scroll-into-view '#far'
/usr/bin/python3 -c "import sys; sys.exit(0 if $(now) - $start > 0.25 else 1)" || fail "scroll-into-view without --instant did not glide"
fails "has no size on screen" -w alpha scroll-into-view '#gone' --timeout=0
# A clipboard read is refused at once: WebKit's Paste menu would pop up at the real pointer.
check "Page" -w alpha click '#clip'
check '^NotAllowedError$' -w alpha --raw eval 'clip.dataset.got'
check "Page" -w alpha eval "scrollTo(0, 0)"
check "popup opened as tab 1: .*index.html?deployed" -w alpha click 'text=deploy to TEST'
check "0: (current)" -w alpha tab-close 1
before=$("$agweb" -w alpha tab-list | grep -c '^- ')
check "opened in tab 1: .*index.html?blank" -w alpha click '#blank' middle
[ "$("$agweb" -w alpha tab-list | grep -c '^- ')" = $((before + 1)) ] || fail "a middle click on a target=_blank link opened more than one tab"
check "0: (current)" -w alpha tab-close 1
check "Page" -w alpha keydown Meta
check "opened in tab 1: .*index.html?next" -w alpha click 'text=Next page'
check "Page" -w alpha keyup Meta
check "0: (current)" -w alpha tab-close 1
check "Page" -w alpha eval "() => { addEventListener('keydown', e => window.lastKey = e.key + ':' + e.code) }"
check "Page" -w alpha press F5
check '"F5:F5"' -w alpha eval 'window.lastKey'
check "index.html?next" -w alpha click 'a'
check "URL containing next" -w alpha wait --url=next
check "URL: $u\$" -w alpha go-back
check "index.html?next" -w alpha go-forward
check "index.html?next" -w alpha reload
check "#frag" -w alpha goto "$u#frag"
check "Page" -w alpha goto "http://127.0.0.1:$port/redirect.html"
check "URL containing redirected" -w alpha wait --url=redirected
check "redirected to http://localhost:$port/index.html?bounced" -w alpha goto "http://127.0.0.1:$port/x?to=http://localhost:$port/index.html%3Fbounced"
check "Page" -w alpha eval "location.href = '/index.html?evalnav'"
check '"?evalnav"' -w alpha eval 'location.search'
fails "up to 600000" -w alpha wait '#b' --timeout=700000
check "Page" -w alpha goto "$u"
check "Safari/" -w alpha eval navigator.userAgent
check '() => 1' -w alpha eval '() => () => 1'
check '42' -w alpha eval '40 + 2 // trailing comment'
fails "already uses profile selftest-alpha" -w alpha open -p other
fails "not profile other" -w alpha eval 1 -p other
check "Page" -w alpha eval 1 -p selftest-alpha
export AGWEB_PROFILE=other
check "Page" -w alpha eval 1
unset AGWEB_PROFILE
fails "unknown command" -w alpha frobnicate
fails "did you mean --submit" -w alpha fill '#q' x --sumbit
check "Page" -w alpha eval "() => { q.value = ''; q.focus() }"
check "Page" -w alpha type --instant -- '--x "q"'
check '"--x \\"q\\""' -w alpha eval 'q.value'
check "Page" -w alpha eval "() => { q.value = '' }"
check "Page" -w alpha type -- '--y teh'
check '"--y teh"' -w alpha eval 'q.value'
fails "missing <target>" -w alpha click
fails "navigation failed" -w alpha goto http://127.0.0.1:1/
fails "boom" -w alpha eval '() => { throw new Error("boom") }'
fails "is not a field" -w alpha fill '#b' x
fails "no workspace\|no session" -w nobody snapshot

echo "== frames, accessible names and controls inside controls"
check 'combobox "Shipping speed" \[expanded\] \[value="Express"\]' -w alpha snapshot
check 'option "Standard"' -w alpha snapshot
check 'link "Developers"' -w alpha snapshot
check '^    - columnheader "Fruit"' -w alpha snapshot '#tb'
check '^    - cell "Apples"' -w alpha snapshot '#tb'
check '^      - button "Buy"' -w alpha snapshot '#tb'
check '^#tb tr:nth-child(2)$' -w alpha --raw eval "(el) => el.matches('#tb tr:nth-child(2)') ? '#tb tr:nth-child(2)' : el.outerHTML" 'role=row[name="Apples"]'
check '  - textbox "Find"' -w alpha snapshot
check "Page" -w alpha fill 'role=textbox[name="Find"]' found
check '"found"' -w alpha eval 'dq.value'
check "Title: frames" -w fs open "http://127.0.0.1:$port/frames.html"
check 'button "Side button"' -w fs snapshot
check 'button "Inner button"' -w fs snapshot
check 'text "Side text"' -w fs wait --text='Side text'
check "Page" -w fs click 'text=Side button'
check '"side"' -w fs eval 'window.clicked'
check "workspace fs closed" -w fs close

echo "== an idle tab nobody watches is hidden; a command wakes it"
check "Title" -w vis open "$u"
check "Page" -w vis eval "() => { window.vis = []; addEventListener('visibilitychange', () => vis.push(document.visibilityState)) }"
sleep 4
check '"state":"hidden"' list --json
check '\["hidden","visible"\]' -w vis eval 'vis'
check '^30$' -w vis --raw eval "() => new Promise(r => { let n = 0; const f = () => ++n < 30 ? requestAnimationFrame(f) : r(n); requestAnimationFrame(f) })"
check "workspace vis closed" -w vis close

echo "== the dashboard shows every tab"
check "dashboard shown" dashboard --filename="$dir/dash.png"
[ "$(sips -g pixelWidth "$dir/dash.png" 2>/dev/null | awk '/pixelWidth/ {print $2}')" -gt 400 ] || fail "dashboard --filename wrote no picture"
check '"dashboard":true' list --json
check '"state":"hidden"' list --json
check "dashboard hidden" dashboard --hide
check '"dashboard":false' list --json

echo "== workspaces run in parallel"
start=$(now)
"$agweb" -w alpha eval '() => new Promise(r => setTimeout(r, 2000))' >/dev/null & a=$!
"$agweb" -w beta eval '() => new Promise(r => setTimeout(r, 2000))' >/dev/null & b=$!
wait $a || fail "parallel eval in alpha failed"
wait $b || fail "parallel eval in beta failed"
/usr/bin/python3 -c "import sys; sys.exit(0 if $(now) - $start < 3.5 else 1)" || fail "two 2 s evals in different workspaces took over 3.5 s"

echo "== profiles: fresh by default, shared when named alike"
check '"who=alpha"' -w alpha eval "() => { document.cookie = 'who=alpha'; return document.cookie }"
check 'who=beta' -w beta eval "() => { document.cookie = 'who=beta'; return document.cookie }"
check '^### Result
"who=alpha"' -w alpha eval 'document.cookie'
check "Title" -w gamma open "$u?gamma" -p selftest-shared
check 'who=gamma' -w gamma eval "() => { document.cookie = 'who=gamma'; return document.cookie }"
check 'who=gamma' -w beta eval 'document.cookie'
check "Title" -w eph1 open "$u"
check '"who=eph"' -w eph1 eval "() => { document.cookie = 'who=eph'; return document.cookie }"
check "Title" -w eph2 open "$u"
check '""' -w eph2 eval 'document.cookie'

echo "== beta is not the displayed tab: snapshot, hover and screenshots still work"
check 'button "Press me"' -w beta snapshot
paced "Page" -w beta hover '#b'
check 'true' -w beta eval "() => document.querySelector('#b').matches(':hover') && moves > 5"
check "Screenshot" -w beta screenshot "$dir/beta1.png"
check "Page" -w beta eval "() => { document.body.style.background = '#c00' }"
check "Screenshot" -w beta screenshot "$dir/beta2.png"
cmp -s "$dir/beta1.png" "$dir/beta2.png" && fail "a hidden tab's screenshot did not change with the page"
check "loaded ?parallel-b\|loaded ?beta" -w beta console
check "1 new error " -w beta eval "async () => { console.warn('careful'); console.error('bad'); await new Promise(r => setTimeout(r, 100)) }"
lacks "new error" -w beta eval 1
check "error: bad" -w beta console error
lacks "careful" -w beta console error
lacks "new error" -w beta eval 1
check "Page" -w beta eval "() => { setTimeout(() => null.x, 0) }"
check "pageerror: TypeError: null is not an object" -w beta console error
check "warn: careful" -w beta console warning
check "warn: careful" -w beta console --clear
check "no console messages" -w beta console
check "Page" -w beta eval "() => console.log('before-reload')"
check "Page" -w beta reload
lacks "before-reload" -w beta console
check "Title" -w beta show
check "beta (profile selftest-shared" list
check "eph1 (fresh profile" list
check "selftest-shared: beta, gamma" profile-list
fails "in use by beta, gamma" profile-delete selftest-shared
# Not `AGWEB_ROOT=... run`: sh keeps an assignment made before a function call.
out=$(AGWEB_ROOT="$dir/o" "$agweb" profile-list 2>&1) || fail "the instance on another root failed: $out"
printf '%s' "$out" | grep -q "no named profiles" || fail "an instance on another root sees this one's profiles: $out"
if [ "$test_domain" != "$domain" ]; then
    out=$(env -u AGWEB_ROOT "$agweb" list 2>&1) && fail "a test build ran without AGWEB_ROOT: $out"
    printf '%s' "$out" | grep -q "test build" || fail "a test build without AGWEB_ROOT said: $out"
fi
[ -S "$dir/o/agweb.sock" ] || fail "the instance on another root has no socket in its root"
AGWEB_ROOT="$dir/o" "$agweb" quit >/dev/null 2>&1
check "confirm() and prompt() will be accepted" -w beta dialog-accept
check "will be dismissed" -w beta dialog-dismiss

echo "== close and quit finish a recording; workspaces and tabs, a named profile, its session cookies and the window frame survive a relaunch"
check "recording" -w eph2 video-start "$dir/close.mp4"
check "### Video" -w eph2 close
LC_ALL=C grep -qa moov "$dir/close.mp4" || fail "close left the video without its index"
check "Page" -w beta eval "() => { document.cookie = 'kept=1; max-age=600'; document.cookie = 'sso=1' }"
# sessionStorage: a named profile's tab keeps it per origin, saved after commands and at quit; a fresh profile keeps none.
check "localhost" -w beta goto "http://localhost:$port/index.html?b2"
check "Page" -w beta eval "() => { sessionStorage.setItem('access_token', 'tok2') }"
check "index.html?beta" -w beta goto "$u?beta"
check "Page" -w beta eval "() => { sessionStorage.setItem('access_token', 'tok1'); setTimeout(() => sessionStorage.setItem('late', 'L'), 1500) }"
check "Page" -w eph1 eval "() => { sessionStorage.setItem('fresh', 'F') }"
sleep 2
check "dashboard shown" dashboard
check "recording" -w beta video-start "$dir/quit.mp4"
check "quit.mp4" quit
LC_ALL=C grep -qa moov "$dir/quit.mp4" || fail "quit left the video without its index"
stopped
# goto as the first command of a run must still bring the profile's session cookies back, and a detour through
# another origin first (an SSO bounce) must not use up the first origin's sessionStorage.
check "index.html?first" -w beta goto "http://localhost:$port/index.html?first"
check '"tok2"' -w beta eval "sessionStorage.getItem('access_token')"
check "index.html?again" -w beta goto "$u?again"
check 'sso=1' -w beta eval 'document.cookie'
check '\["tok1","L"\]' -w beta eval "[sessionStorage.getItem('access_token'), sessionStorage.getItem('late')]"
check '^null$' -w eph1 --raw eval "sessionStorage.getItem('fresh')"
check '"dashboard":true' list --json
check "dashboard hidden" dashboard --hide
check "beta (profile selftest-shared" list
check "eph1 (fresh profile" list
check "index.html?again" -w beta tab-list
check 'button "Press me"' -w beta snapshot
# Cleared (a logout) is saved too, so the next restart doesn't log back in.
check "Page" -w beta eval "() => { sessionStorage.clear() }"
check "bye" quit
stopped
# A run that never touches the profile must not save over its session cookies.
check 'button "Press me"' -w alpha snapshot
check '"dashboard":false' list --json
check "bye" quit
stopped
check "Title" -w delta open "$u" -p selftest-shared
check 'kept=1' -w delta eval "() => { const c = document.cookie; document.cookie = 'kept=; max-age=0'; return c }"
check 'sso=1' -w delta eval 'document.cookie'
check '^null$' -w beta --raw eval "sessionStorage.getItem('access_token')"
if [ "$test_domain" != "$domain" ] && defaults read "$test_domain" agwebMainFrame >/dev/null 2>&1; then fail "the test build saved its frame outside its root's settings"; fi
case "$(defaults read "$suite" agwebMainFrame)" in *"{900, "*) ;; *) false ;; esac || fail "the test window's saved frame was not restored"
[ "$(defaults read $domain agwebMainFrame 2>/dev/null)" = "$person_frame" ] || fail "the selftest changed the person's saved window frame"
check "workspace delta closed" close-all
check "profile selftest-shared deleted" profile-delete selftest-shared
check "Title" -w zeta open "$u" -p selftest-shared
check '^""$' -w zeta eval 'document.cookie'
check "workspace zeta closed" -w zeta close
check "profile selftest-shared deleted" profile-delete selftest-shared
check "profile selftest-alpha deleted" profile-delete selftest-alpha
lacks "selftest" profile-list
fails "no profile selftest-alpha" profile-delete selftest-alpha
# WebKit keeps a deleted profile's folder while it holds the store; the next launch removes it.
check "bye" quit
stopped
check "Title" -w last open "$u"
ls "$AGWEB_ROOT/webkit" 2>/dev/null | grep -qix "$alpha_store" && fail "a relaunch left the deleted selftest-alpha's WebKit folder"
# A damaged registry must not read as "every profile was deleted".
check "bye" quit
stopped
echo '{' >"$AGWEB_ROOT/profiles/profiles.json"
mkdir -p "$unnamed"
check "Title" -w last open "$u"
[ -d "$unnamed" ] || fail "a launch with a damaged profile registry swept the root's WebKit data"

echo
if [ "$failures" -eq 0 ]; then echo "all checks passed"; else echo "$failures checks failed"; fi
exit "$failures"
