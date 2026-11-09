#!/bin/sh
# Every verb, workspaces in parallel, against a local page, in a separate agweb instance on its own socket and
# window frame, so the browser you use is untouched. Fails if agweb ever becomes the frontmost app.
# Exits with the number of failed checks.
set -u
cd "$(dirname "$0")"
dir=$(mktemp -d /tmp/agweb-test.XXXXXX)
export AGWEB_SOCKET="$dir/s.sock"
agweb="$PWD/../bin/agweb"
cp testpage.html "$dir/index.html"
domain=dev.playground.agweb
person_frame=$(defaults read $domain "NSWindow Frame agwebMain" 2>/dev/null)
defaults write $domain "NSWindow Frame agwebTest" "200 200 900 600 0 0 1440 900"

port=$(/usr/bin/python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
(cd "$dir" && exec /usr/bin/python3 -m http.server "$port" --bind 127.0.0.1 >"$dir/server.log" 2>&1) &
server=$!
trap '"$agweb" quit >/dev/null 2>&1; kill $server 2>/dev/null; defaults delete $domain "NSWindow Frame agwebTest" 2>/dev/null; rm -r "$dir"' EXIT
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
    if "$agweb" "$@" 2>&1 | grep -q -- "$pattern"; then fail "agweb $*: the output contains $pattern"; else printf 'ok    agweb %s (no %s)\n' "$*" "$pattern"; fi
}
video_seconds() { sed -n 's/.* frames, \([0-9.]*\) s.*/\1/p'; }

check "Title: agweb test" -s alpha open "$u" --profile=selftest-alpha
check "Title: agweb test" -s beta open "$u?beta" --profile=selftest-shared
check 'button "Press me" \[ref=e2\]' -s alpha snapshot
check 'option "Two"' -s alpha snapshot
check "Page" -s alpha click e2
check "Page" -s alpha fill '#q' hello
check "Page" -s alpha press Enter
fails "native picker" -s alpha click '#s'
check "Page" -s alpha fill '#s' Two
check "Page" -s alpha eval "() => { s.focus() }"
fails "native picker" -s alpha press ArrowDown
check "Page" -s alpha fill '#pw' secret
check 'textbox \[value=<hidden>\]' -s alpha snapshot
lacks "secret" -s alpha snapshot
check "file chooser got" -s alpha upload '#file' /etc/hosts
fails "no file chooser opened" -s alpha upload e2 /etc/hosts
check "alert: hi" -s alpha click '#al'
check '"click trusted=true","keydown Enter trusted=true","submit:hello","file:hosts"' -s alpha eval 'window.log'
check '"2"' -s alpha eval "() => document.querySelector('#s').value"

echo "== the pointer glides: trusted mousemoves arrive, :hover follows, typing is per key"
check "Page" -s alpha mousemove 5 5 --instant
check 'false' -s alpha eval "() => { moves = 0; return document.querySelector('#b').matches(':hover') }"
check "Page" -s alpha hover '#b'
check 'true' -s alpha eval "() => document.querySelector('#b').matches(':hover') && moves > 5"
fails "inside the" -s alpha mousemove nan 5
fails "inside the" -s alpha mousemove 5 99999
check "Page" -s alpha eval "() => { q.focus(); q.setSelectionRange(99, 99); inputs = 0 }"
start=$(now)
check "Page" -s alpha type ' world'
/usr/bin/python3 -c "import sys; sys.exit(0 if $(now) - $start >= 0.6 else 1)" || fail "typing ' world' took under 0.6 s; it should go at a person's pace"
check "Page" -s alpha type '!' --instant
check '\["hello world!",7\]' -s alpha eval '[q.value, inputs]'

echo "== recording"
fails "must end in .mp4" -s alpha video-start "$dir"
fails "max-idle takes seconds" -s alpha video-start "$dir/v.mp4" --max-idle=soon
check "recording alpha" -s alpha video-start "$dir/v.mp4"
check "Page" -s alpha hover '#al'
check "Page" -s alpha eval "async () => { for (const c of ['#fee', '#efe', '#eef']) { document.body.style.background = c; await new Promise(r => setTimeout(r, 150)) } }"
fails "already recording" -s alpha video-start "$dir/w.mp4"
check "frames, " -s alpha video-stop
LC_ALL=C grep -qa moov "$dir/v.mp4" || fail "the video has no index (moov)"
fails "not recording" -s alpha video-stop
# A page that never stops changing: time between commands is still cut to max-idle.
check "Page" -s alpha eval "() => { window.blink = setInterval(() => document.body.style.background = document.body.style.background ? '' : '#eee', 100) }"
check "recording" -s alpha video-start "$dir/idle.mp4" --max-idle=0.5
sleep 3
seconds=$("$agweb" -s alpha video-stop | video_seconds)
/usr/bin/python3 -c "import sys; sys.exit(0 if 0 < ${seconds:-0} < 2.5 else 1)" || fail "3 s idle with --max-idle=0.5 gave a ${seconds:-?} s video"
check "Page" -s alpha eval "() => { clearInterval(window.blink); document.body.style.background = '' }"

echo "== tabs and popups"
check "popup opened as tab 1" -s alpha click '#pop'
check "1: (current)" -s alpha tab-list
check "0: (current)" -s alpha tab-select 0
check "1: (current)" -s alpha tab-select 1
fails "no tab 9" -s alpha tab-close 9
check "0: (current)" -s alpha tab-close 1
check "Page" -s alpha eval "() => { setTimeout(() => open('/index.html?ad'), 200) }"
sleep 1
check "0: (current)" -s alpha tab-list
check "index.html?next" -s alpha click 'a'
check "URL: $u\$" -s alpha go-back
check "index.html?next" -s alpha go-forward
check "index.html?next" -s alpha reload
check "#frag" -s alpha goto "$u#frag"
check "Safari/" -s alpha eval navigator.userAgent
check '() => 1' -s alpha eval '() => () => 1'
check '42' -s alpha eval '40 + 2 // trailing comment'
fails "already uses profile" -s alpha open --profile=other
fails "unknown command" -s alpha frobnicate
fails "missing <ref>" -s alpha click
fails "navigation failed" -s alpha goto http://127.0.0.1:1/
fails "boom" -s alpha eval '() => { throw new Error("boom") }'
fails "is not a field" -s alpha fill '#b' x
fails "no workspace\|no session" -s nobody snapshot

echo "== workspaces run in parallel"
start=$(now)
"$agweb" -s alpha eval '() => new Promise(r => setTimeout(r, 2000))' >/dev/null & a=$!
"$agweb" -s beta eval '() => new Promise(r => setTimeout(r, 2000))' >/dev/null & b=$!
wait $a || fail "parallel eval in alpha failed"
wait $b || fail "parallel eval in beta failed"
/usr/bin/python3 -c "import sys; sys.exit(0 if $(now) - $start < 3.5 else 1)" || fail "two 2 s evals in different workspaces took over 3.5 s"

echo "== profiles: separate unless named alike; ephemeral keeps nothing"
check '"who=alpha"' -s alpha eval "() => { document.cookie = 'who=alpha'; return document.cookie }"
check 'who=beta' -s beta eval "() => { document.cookie = 'who=beta'; return document.cookie }"
check '^### Result
"who=alpha"' -s alpha eval 'document.cookie'
check "Title" -s gamma open "$u?gamma" --profile=selftest-shared
check 'who=gamma' -s gamma eval "() => { document.cookie = 'who=gamma'; return document.cookie }"
check 'who=gamma' -s beta eval 'document.cookie'
check "Title" -s eph1 open "$u" --profile=ephemeral
check '"who=eph"' -s eph1 eval "() => { document.cookie = 'who=eph'; return document.cookie }"
check "Title" -s eph2 open "$u" --profile=ephemeral
check '""' -s eph2 eval 'document.cookie'

echo "== beta is not the displayed tab: snapshot, hover and screenshots still work"
check 'button "Press me"' -s beta snapshot
check "Page" -s beta hover '#b'
check 'true' -s beta eval "() => document.querySelector('#b').matches(':hover') && moves > 5"
check "Screenshot" -s beta screenshot "$dir/beta1.png"
check "Page" -s beta eval "() => { document.body.style.background = '#c00' }"
check "Screenshot" -s beta screenshot "$dir/beta2.png"
cmp -s "$dir/beta1.png" "$dir/beta2.png" && fail "a hidden tab's screenshot did not change with the page"
check "loaded ?parallel-b\|loaded ?beta" -s beta console
check "Title" -s beta show
check "selftest-shared" list

echo "== close and quit finish a recording; a named profile and the window frame survive a relaunch"
check "recording" -s eph2 video-start "$dir/close.mp4"
check "### Video" -s eph2 close
LC_ALL=C grep -qa moov "$dir/close.mp4" || fail "close left the video without its index"
check "Page" -s beta eval "() => { document.cookie = 'kept=1; max-age=600' }"
check "recording" -s beta video-start "$dir/quit.mp4"
check "### Video" quit
LC_ALL=C grep -qa moov "$dir/quit.mp4" || fail "quit left the video without its index"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -e "$AGWEB_SOCKET" ] || break; sleep 0.5; done
sleep 1
check "Title" -s delta open "$u" --profile=selftest-shared
check 'kept=1' -s delta eval "() => { const c = document.cookie; document.cookie = 'kept=; max-age=0'; return c }"
[ "$(defaults read $domain "NSWindow Frame agwebTest" | cut -d' ' -f3)" = 900 ] || fail "the test window's saved frame was not restored"
[ "$(defaults read $domain "NSWindow Frame agwebMain" 2>/dev/null)" = "$person_frame" ] || fail "the selftest changed the person's saved window frame"

echo
if [ "$failures" -eq 0 ]; then echo "all checks passed"; else echo "$failures checks failed"; fi
exit "$failures"
