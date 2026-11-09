#!/bin/sh
# Every verb, two sessions in parallel, against a local page, in a separate WKBrowser instance on its own
# socket, so the browser you use is untouched. Keep another app frontmost while it runs: WKBrowser should
# never come forward. Exits non-zero if any check fails.
set -u
cd "$(dirname "$0")"
dir=$(mktemp -d /tmp/wkb-test.XXXXXX)
export WKB_SOCKET="$dir/s.sock"
wkb="$PWD/../bin/wkb"
cp testpage.html "$dir/index.html"

port=$(/usr/bin/python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
(cd "$dir" && exec /usr/bin/python3 -m http.server "$port" --bind 127.0.0.1 >"$dir/server.log" 2>&1) &
server=$!
trap '"$wkb" quit >/dev/null 2>&1; kill $server 2>/dev/null; rm -r "$dir"' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do curl -s -o /dev/null "http://127.0.0.1:$port/" && break; sleep 0.3; done
u="http://127.0.0.1:$port/index.html"

failures=0
# check <pattern> <wkb args...>: runs the command and requires its output (stdout+stderr) to match.
check() {
    pattern=$1; shift
    out=$("$wkb" "$@" 2>&1)
    if printf '%s' "$out" | grep -q -- "$pattern"; then
        printf 'ok    wkb %s\n' "$*"
    else
        printf 'FAIL  wkb %s\n      expected: %s\n%s\n' "$*" "$pattern" "$(printf '%s' "$out" | sed 's/^/      | /')"
        failures=$((failures + 1))
    fi
}

check "Title: wkb test" -s alpha open "$u" --profile=selftest-alpha
check "Title: wkb test" -s beta open "$u?beta" --profile=selftest-shared
check 'button "Press me" \[ref=e2\]' -s alpha snapshot
check 'option "Two"' -s alpha snapshot
check "Page" -s alpha click e2
check "Page" -s alpha fill '#q' hello
check "Page" -s alpha press Enter
check "native picker" -s alpha click '#s'
check "Page" -s alpha fill '#s' Two
check "file chooser got" -s alpha upload '#file' /etc/hosts
check "no file chooser opened" -s alpha upload e2 /etc/hosts
check "alert: hi" -s alpha click '#al'
check '"click trusted=true","keydown Enter trusted=true","submit:hello","file:hosts"' -s alpha eval 'window.log'
check '"2"' -s alpha eval "() => document.querySelector('#s').value"

echo "== the pointer glides: trusted mousemoves arrive, :hover follows, typing is per key"
check "Page" -s alpha hover '#al'
check 'true' -s alpha eval "() => document.querySelector('#al').matches(':hover') && moves > 5"
check "Page" -s alpha mousemove 5 5 --instant
check 'false' -s alpha eval "() => document.querySelector('#al').matches(':hover')"
check "Page" -s alpha eval "() => { q.focus(); q.setSelectionRange(99, 99) }"
start=$(date +%s)
check "Page" -s alpha type ' world'
[ $(($(date +%s) - start)) -ge 1 ] || { echo "FAIL  natural type finished in under a second"; failures=$((failures + 1)); }
check "Page" -s alpha type '!' --instant
check '"hello world!"' -s alpha eval 'q.value'
check "popup opened as tab 1" -s alpha click '#pop'
check "1: (current)" -s alpha tab-list
check "no tab 9" -s alpha tab-close 9
check "0: (current)" -s alpha tab-close 1
check "index.html?next" -s alpha click 'a'
check "URL: $u\$" -s alpha go-back
check "#frag" -s alpha goto "$u#frag"
check "Safari/" -s alpha eval navigator.userAgent
check '() => 1' -s alpha eval '() => () => 1'
check '42' -s alpha eval '40 + 2 // trailing comment'
check "already uses profile" -s alpha open --profile=other

echo "== both sessions at once"
"$wkb" -s alpha tab-new "$u?parallel-a" >/dev/null & a=$!
"$wkb" -s beta goto "$u?parallel-b" >/dev/null & b=$!
wait $a $b
check "parallel-a" -s alpha tab-list
check "parallel-b" -s beta tab-list

echo "== profiles: alpha's cookie stays in alpha; gamma shares beta's profile; ephemeral shares nothing"
check '"who=alpha"' -s alpha eval "() => { document.cookie = 'who=alpha'; return document.cookie }"
check '"who=beta"' -s beta eval "() => { document.cookie = 'who=beta'; return document.cookie }"
check "Title" -s gamma open "$u?gamma" --profile=selftest-shared
check '"who=beta"' -s gamma eval 'document.cookie'
check "Title" -s eph1 open "$u" --profile=ephemeral
check '"who=eph"' -s eph1 eval "() => { document.cookie = 'who=eph'; return document.cookie }"
check "Title" -s eph2 open "$u" --profile=ephemeral
check '""' -s eph2 eval 'document.cookie'

echo "== beta is not the displayed tab: snapshot and screenshot still work"
check 'button "Press me"' -s beta snapshot
check "Page" -s beta hover '#b'
check 'true' -s beta eval "() => document.querySelector('#b').matches(':hover') && moves > 5"
check "Screenshot" -s beta screenshot "$dir/beta.png"
check "loaded ?parallel-b" -s beta console
check "selftest-shared" list

echo
if [ "$failures" -eq 0 ]; then echo "all checks passed"; else echo "$failures checks failed"; fi
exit "$failures"
