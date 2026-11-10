#!/bin/sh
# Every verb, workspaces in parallel, against a local page, in a separate agweb instance on its own socket and
# window frame, so the browser you use is untouched. Fails if agweb ever becomes the frontmost app.
# Exits with the number of failed checks.
set -u
cd "$(dirname "$0")"
dir=$(mktemp -d /tmp/agweb-test.XXXXXX)
export AGWEB_SOCKET="$dir/s.sock"
unset AGWEB_PROFILE AGWEB_WORKSPACE
agweb="$PWD/../bin/agweb"
cp testpage.html "$dir/index.html"
cp frame.html frames.html side.html redirect.html "$dir/"
domain=dev.playground.agweb
person_frame=$(defaults read $domain agwebMainFrame 2>/dev/null)
defaults write $domain agwebTestFrame -string "{{200, 200}, {900, 600}}"

port=$(/usr/bin/python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
(server="$PWD/server.py"; cd "$dir" && exec /usr/bin/python3 "$server" "$port" >"$dir/server.log" 2>&1) &
server=$!
trap '"$agweb" quit >/dev/null 2>&1; kill $server 2>/dev/null; wait $server 2>/dev/null; defaults delete $domain agwebTestFrame 2>/dev/null; rm -r "$dir"' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do curl -s -o /dev/null "http://127.0.0.1:$port/" && break; sleep 0.3; done
u="http://127.0.0.1:$port/index.html"

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
    [ "$(frontmost)" = "$domain" ] && fail "agweb became the frontmost app after: agweb $*"
}
check() { run 0 "$@"; }
fails() { run 1 "$@"; }
lacks() {
    pattern=$1; shift
    out=$("$agweb" "$@" 2>&1) || { fail "agweb $*: failed: $out"; return; }
    if printf '%s' "$out" | grep -q -- "$pattern"; then fail "agweb $*: the output contains $pattern"; else printf 'ok    agweb %s (no %s)\n' "$*" "$pattern"; fi
}
# Waits for a quit instance to let go of its socket.
stopped() {
    for _ in 1 2 3 4 5 6 7 8 9 10; do [ -e "$AGWEB_SOCKET" ] || break; sleep 0.5; done
    sleep 1
}
video_seconds() { sed -n 's/.* frames, \([0-9.]*\) s.*/\1/p'; }

check "Title: agweb test" -w alpha open "$u" -p selftest-alpha
alpha_store=$(/usr/bin/python3 -c 'import hashlib, uuid; print(uuid.UUID(bytes=hashlib.sha256(b"agweb.profile.selftest-alpha").digest()[:16]))')
check "Title: agweb test" -w beta open "$u?beta" -p selftest-shared
check 'button "Press me" \[ref=e2\]' -w alpha snapshot
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
check "file chooser got" -w alpha upload '#file' /etc/hosts
fails "no file chooser opened" -w alpha upload e2 /etc/hosts
check "alert: hi" -w alpha click '#al'
check '"click trusted=true","keydown Enter trusted=true","submit:hello","file:hosts"' -w alpha eval 'window.log'
check '"2"' -w alpha eval "() => document.querySelector('#s').value"

echo "== the pointer glides: trusted mousemoves arrive, :hover follows, typing is per key"
check "Page" -w alpha mousemove 5 5 --instant
check 'false' -w alpha eval "() => { moves = 0; return document.querySelector('#b').matches(':hover') }"
check "Page" -w alpha hover '#b'
check 'true' -w alpha eval "() => document.querySelector('#b').matches(':hover') && moves > 5"
fails "inside the" -w alpha mousemove nan 5
fails "inside the" -w alpha mousemove 5 99999
check "Page" -w alpha eval "() => { q.focus(); q.setSelectionRange(99, 99); inputs = 0 }"
start=$(now)
check "Page" -w alpha type ' world'
/usr/bin/python3 -c "import sys; sys.exit(0 if $(now) - $start >= 0.6 else 1)" || fail "typing ' world' took under 0.6 s; it should go at a person's pace"
check "Page" -w alpha type '!' --instant
check '\["hello world!",7\]' -w alpha eval '[q.value, inputs]'

echo "== output modes and files"
check '^hello world!$' -w alpha --raw eval 'q.value'
check '"ok":true' -w alpha --json eval '1'
check '"workspaces":\[{' list --json
check "$dir/snap.md" -w alpha snapshot --filename="$dir/snap.md"
grep -q 'button "Press me"' "$dir/snap.md" || fail "snapshot --filename did not write the tree"
check "$dir/el.png" -w alpha screenshot '#b' --path="$dir/el.png"
[ "$(sips -g pixelWidth "$dir/el.png" | awk '/pixelWidth/ {print $2}')" -lt 400 ] || fail "screenshot '#b' is not just the button"
check "Screenshot" -w alpha screenshot --full-page --filename="$dir/full.jpg"
[ "$(sips -g pixelHeight "$dir/full.jpg" | awk '/pixelHeight/ {print $2}')" -gt 3000 ] || fail "screenshot --full-page is not the whole page"
check '^\[Next page\](/index.html?next)$' -w alpha --raw text 'a'
check "$dir/page.md" -w alpha text --filename="$dir/page.md"
grep -q 'Press me' "$dir/page.md" || fail "text --filename did not write the page"
check '"undefined"' -w alpha eval 'typeof Defuddle'
check "Page" -w alpha fill '#q' again --submit
check '"submit:again"' -w alpha eval 'log'
check "Page" -w alpha click '#b' --js
check '"click trusted=false"' -w alpha eval 'log'

echo "== locators, iframes, checkboxes, buttons and keys"
check '  - button "Inner button"' -w alpha snapshot
check "Page" -w alpha click 'role=button[name="inner"]'
check "Page" -w alpha click 'text=Inner button'
check '\["inner","inner"\]' -w alpha eval 'log.filter(x => x === "inner")'
fails 'matches .* elements: button "Press me" \[ref=e2\]; ' -w alpha click 'role=button'
check '^- form' -w alpha snapshot '#f'
lacks 'Press me' -w alpha snapshot '#f'
check '^inner$' -w alpha --raw eval '(el) => el.id' 'role=button[name="inner"]'
check "Page" -w alpha check 'text=Remember me'
check "Page" -w alpha check '#r2'
check '\[true,true\]' -w alpha eval '[cb.checked, r2.checked]'
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
check 'for text "Arrived late"' -w st2 wait --text='Arrived late'
check "Page" -w st2 eval "() => { setTimeout(() => late.remove(), 300) }"
check "#late to go" -w st2 wait '#late' --gone
fails "timed out" -w st2 wait '#nothing' --timeout=300
fails "invalid selector" -w st2 wait 'bad[[' --timeout=5000
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
fails "not recording" -w alpha video-chapter x
check "recording alpha" -w alpha video-start "$dir/v.mp4"
check "Page" -w alpha hover '#al'
check "Page" -w alpha eval "async () => { for (const c of ['#fee', '#efe', '#eef']) { document.body.style.background = c; await new Promise(r => setTimeout(r, 150)) } }"
fails "already recording" -w alpha video-start "$dir/w.mp4"
check 'chapter "Step one"' -w alpha video-chapter "Step one" --description "The first part" --duration 300
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
check "Page" -w alpha eval "() => { setTimeout(() => open('/index.html?ad'), 200) }"
sleep 1
check "0: (current)" -w alpha tab-list
check "opened in tab 1: .*index.html?next" -w alpha click 'text=Next page' middle
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
check "Safari/" -w alpha eval navigator.userAgent
check '() => 1' -w alpha eval '() => () => 1'
check '42' -w alpha eval '40 + 2 // trailing comment'
fails "already uses profile selftest-alpha" -w alpha open -p other
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
check 'combobox "Shipping speed" \[expanded\]' -w alpha snapshot
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
check 'for text "Side text"' -w fs wait --text='Side text'
check "Page" -w fs click 'text=Side button'
check '"side"' -w fs eval 'window.clicked'
check "workspace fs closed" -w fs close

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
check "Page" -w beta hover '#b'
check 'true' -w beta eval "() => document.querySelector('#b').matches(':hover') && moves > 5"
check "Screenshot" -w beta screenshot "$dir/beta1.png"
check "Page" -w beta eval "() => { document.body.style.background = '#c00' }"
check "Screenshot" -w beta screenshot "$dir/beta2.png"
cmp -s "$dir/beta1.png" "$dir/beta2.png" && fail "a hidden tab's screenshot did not change with the page"
check "loaded ?parallel-b\|loaded ?beta" -w beta console
check "Page" -w beta eval "() => { console.warn('careful'); console.error('bad') }"
check "1 new errors" -w beta eval 1
check "error: bad" -w beta console error
lacks "careful" -w beta console error
lacks "new errors" -w beta eval 1
check "Page" -w beta eval "() => { setTimeout(() => null.x, 0) }"
check "pageerror: TypeError: null is not an object" -w beta console error
check "warn: careful" -w beta console warning
check "warn: careful" -w beta console --clear
check "no console messages" -w beta console
check "Title" -w beta show
check "beta (profile selftest-shared" list
check "eph1 (fresh profile" list
check "selftest-shared: beta, gamma" profile-list
fails "in use by beta, gamma" profile-delete selftest-shared
out=$(AGWEB_SOCKET="$dir/o.sock" "$agweb" profile-delete selftest-shared 2>&1)
printf '%s' "$out" | grep -q "open in another agweb instance" || fail "another instance deleted a profile beta has open: $out"
AGWEB_SOCKET="$dir/o.sock" "$agweb" quit >/dev/null 2>&1
check "confirm() and prompt() will be accepted" -w beta dialog-accept
check "will be dismissed" -w beta dialog-dismiss

echo "== close and quit finish a recording; workspaces and tabs, a named profile, its session cookies and the window frame survive a relaunch"
check "recording" -w eph2 video-start "$dir/close.mp4"
check "### Video" -w eph2 close
LC_ALL=C grep -qa moov "$dir/close.mp4" || fail "close left the video without its index"
check "Page" -w beta eval "() => { document.cookie = 'kept=1; max-age=600'; document.cookie = 'sso=1' }"
check "autoload=1" -w beta tab-new "$u?autoload=1"
check "recording" -w beta video-start "$dir/quit.mp4"
check "### Video" quit
LC_ALL=C grep -qa moov "$dir/quit.mp4" || fail "quit left the video without its index"
stopped
# goto as the first command of a run must still bring the profile's session cookies back.
check "not reopened .*autoload=1" -w beta goto "$u?again"
check 'sso=1' -w beta eval 'document.cookie'
check "beta (profile selftest-shared" list
check "eph1 (fresh profile" list
check "index.html?again" -w beta tab-list
check 'button "Press me"' -w beta snapshot
check "bye" quit
stopped
# A run that never touches the profile must not save over its session cookies.
check 'button "Press me"' -w alpha snapshot
check "bye" quit
stopped
check "Title" -w delta open "$u" -p selftest-shared
check 'kept=1' -w delta eval "() => { const c = document.cookie; document.cookie = 'kept=; max-age=0'; return c }"
check 'sso=1' -w delta eval 'document.cookie'
case "$(defaults read $domain agwebTestFrame)" in *"{900, "*) ;; *) false ;; esac || fail "the test window's saved frame was not restored"
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
ls ~/Library/WebKit/$domain/WebsiteDataStore/ 2>/dev/null | grep -qix "$alpha_store" && fail "a relaunch left the deleted selftest-alpha's WebKit folder"

echo
if [ "$failures" -eq 0 ]; then echo "all checks passed"; else echo "$failures checks failed"; fi
exit "$failures"
