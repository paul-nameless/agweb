#!/bin/sh
# Every verb, workspaces in parallel, against a local page, in a separate agweb instance with its own root
# (AGWEB_ROOT: socket, profiles, WebKit data, settings, window frame), so the browser you use is untouched. Fails if agweb ever becomes the frontmost app.
# Exits with the number of failed checks.
set -u
cd "$(dirname "$0")"
scripts=$PWD
dir=$(mktemp -d /tmp/agweb-test.XXXXXX)
export AGWEB_ROOT="$dir/r"
unset AGWEB_PROFILE AGWEB_WORKSPACE
# Every command at once (the checks about human pace use `paced`), and tabs hide 3 s after a command, not 30.
# A page may use passkeys 2 s after a command, not 10.
export AGWEB_INSTANT=1 AGWEB_AWAKE_SECONDS=3 AGWEB_PASSKEY_SECONDS=2
agweb=${AGWEB_CLI:-$PWD/../bin/agweb}
cp testpage.html "$dir/index.html"
cp frame.html frames.html side.html redirect.html later.html passkey.html "$dir/"
# The test build's bundle id (build.sh --test adds .test); the person's frame is checked under the id without it.
test_domain=$(plutil -extract CFBundleIdentifier raw "$(dirname "$(realpath "$agweb")")/../Info.plist")
domain=${test_domain%.test}
# Older WebKit differs in a few checks below: they run only where they pass (macOS 15 is supported but not tested there).
macos=$(sw_vers -productVersion | cut -d. -f1)
skip() { printf 'skip  %s\n' "$1"; }
person_frame=$(defaults read $domain agwebMainFrame 2>/dev/null)
# Settings and the frame of this root (Agweb.settingsSuite).
suite=agweb.root$(printf %s "$AGWEB_ROOT" | tr / _)
defaults write "$suite" agwebMainFrame -string "{{200, 200}, {900, 600}}"
# A store no registry names, before any registry exists: the first launch must not sweep it.
unnamed="$AGWEB_ROOT/webkit/00000000-0000-0000-0000-000000000001"
mkdir -p "$unnamed"

# A free port the server really answers on, or stop: without it every check fails for the same reason.
server= proxy=
# AGWEB_SELFTEST_LOG=FILE keeps the instance's command log (each command's ms) for timing a run.
trap '[ -n "${pids:-}" ] && kill $pids 2>/dev/null; [ -n "${AGWEB_SELFTEST_LOG:-}" ] && cp "$AGWEB_ROOT/logs/commands.jsonl" "$AGWEB_SELFTEST_LOG" 2>/dev/null; "$agweb" quit >/dev/null 2>&1; for r in o u g; do AGWEB_ROOT="$dir/$r" "$agweb" quit >/dev/null 2>&1; done; [ -s "$dir/proxy.pid" ] && kill "$(cat "$dir/proxy.pid")" 2>/dev/null; [ -n "$server" ] && kill $server 2>/dev/null; [ -n "$proxy" ] && kill $proxy 2>/dev/null; wait 2>/dev/null; for d in "$suite" "agweb.root$(printf %s "$dir/o" | tr / _)" "agweb.root$(printf %s "$dir/u" | tr / _)" "agweb.root$(printf %s "$dir/g" | tr / _)"; do defaults delete "$d" 2>/dev/null; rm -f ~/Library/Preferences/"$d".plist; done; rm -r "$dir"' EXIT
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
# The proxy section's password and a name only its proxy knows (a resolver that answers every name would fail the direct checks).
pw=pw-$$-selftest proxied="http://proxied.agweb.test:$port/index.html"
# Ad blocking is on by default; this instance compiles a local list instead of fetching uBlock Origin's.
printf '||127.0.0.1^*blockapi\n/blockme.png\n' >"$dir/blocklist.txt"
export AGWEB_ADBLOCK_LISTS="http://127.0.0.1:$port/blocklist.txt"
# Check for Updates reads this release instead of GitHub's; the checks below rewrite it.
release() { printf '{"tag_name":"v%s","html_url":"http://127.0.0.1:%s/","body":"notes","assets":[{"name":"Agweb.dmg","browser_download_url":"http://127.0.0.1:%s/Agweb.dmg"}]}' "$1" "$port" "$port" >"$dir/release.json"; }
version=$(plutil -extract CFBundleShortVersionString raw "$(dirname "$(realpath "$agweb")")/../Info.plist")
release "$version"
export AGWEB_UPDATE_FEED="http://127.0.0.1:$port/release.json"
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
# CI runners activate every app they launch, `open -g` or not (TextEdit too). There a launch may leave agweb in front:
# Finder takes it back before the next command, and only a command that launched nothing fails for being in front.
ours() { case "$(frontmost)" in "$domain"|"$test_domain") return 0 ;; esac; return 1; }
running() { lsappinfo find bundleid="$test_domain" | grep -q .; }

# run <expected status: 0 or 1> <pattern> <agweb args...>: the exit status and the output (stdout+stderr) must match.
run() {
    want=$1 pattern=$2; shift 2
    launch=
    if [ -n "${AGWEB_CI:-}" ]; then
        ours && osascript -e 'tell application "Finder" to activate' >/dev/null
        running || launch=1
    fi
    out=$("$agweb" "$@" 2>&1); status=$?
    [ "$status" -ne 0 ] && status=1
    if [ "$status" -eq "$want" ] && printf '%s' "$out" | grep -q -- "$pattern"; then
        printf 'ok    agweb %s\n' "$*"
    else
        printf 'FAIL  agweb %s\n      expected exit %s and: %s\n%s\n' "$*" "$want" "$pattern" "$(printf '%s' "$out" | sed 's/^/      | /')"
        failures=$((failures + 1))
    fi
    ours && [ -z "$launch" ] && fail "agweb became the frontmost app after: agweb $*"
}
check() { run 0 "$@"; }
paced() { AGWEB_INSTANT=; check "$@"; AGWEB_INSTANT=1; }
fails() { run 1 "$@"; }
lacks() {
    pattern=$1; shift
    out=$("$agweb" "$@" 2>&1) || { fail "agweb $*: failed: $out"; return; }
    if printf '%s' "$out" | grep -q -- "$pattern"; then fail "agweb $*: the output contains $pattern"; else printf 'ok    agweb %s (no %s)\n' "$*" "$pattern"; fi
}
# Waits for a quit instance to let go of its socket's lock, which it holds until it exits.
stopped() {
    /usr/bin/python3 -c 'import fcntl, os, sys, time
end = time.time() + 10
while time.time() < end:
    fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB); os.close(fd); sys.exit(0)
    except BlockingIOError:
        os.close(fd); time.sleep(0.02)
sys.exit(1)' "$AGWEB_ROOT/agweb.sock.lock" || fail "the quit instance still held its socket after 10 s"
    if [ -n "${AGWEB_CI:-}" ]; then for _ in 1 2 3 4 5 6 7 8 9 10; do running || break; sleep 0.5; done; fi
}
video_seconds() { sed -n 's/.* frames, \([0-9.]*\) s.*/\1/p'; }

check "Title: agweb test" -w alpha open "$u" -p selftest-alpha
[ -d "$unnamed" ] || fail "a launch without a profile registry swept the root's WebKit data"
pk_store=$(/usr/bin/python3 -c 'import hashlib, uuid; print(uuid.UUID(bytes=hashlib.sha256(b"agweb.profile.selftest-pk").digest()[:16]))')
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

# The sections below run at once, each in workspaces of its own, in this one instance: the checks must hold while it is
# busy with all of them. Each prints to its own file, shown in order once all are done. The sections after them share
# state they can't share (the dashboard, secure input, the timing of parallel workspaces, profiles, relaunches) and run alone.
lanes=
# The instances on roots of their own start now, at once, before the lanes: a CI runner brings every app it launches
# to the front, which would fail whatever lane's command was running then. Each checks its own start here.
printf '<title>Unload one</title><p>one' >"$dir/un1.html"
printf '<title>Unload two</title><p>two<input id=t>' >"$dir/un2.html"
printf '<title>Order</title><form method=post action=/order><button id=go>Go</button></form>' >"$dir/order.html"
(
    export AGWEB_ROOT="$dir/u" AGWEB_UNLOAD_SECONDS=2 AGWEB_AWAKE_SECONDS=1
    "$agweb" -w shown open "http://127.0.0.1:$port/un1.html" >"$dir/u.launch" 2>&1
) & l1=$!
( AGWEB_ROOT="$dir/o" "$agweb" profile >"$dir/o.launch" 2>&1 ) & l2=$!
# A damaged profile registry must not read as "every profile was deleted".
(
    export AGWEB_ROOT="$dir/g"
    kept="$AGWEB_ROOT/webkit/00000000-0000-0000-0000-000000000002"
    mkdir -p "$AGWEB_ROOT/profiles" "$kept"
    echo '{' >"$AGWEB_ROOT/profiles/profiles.json"
    out=$("$agweb" -w g open "$u" 2>&1) || { echo "the instance with a damaged registry did not start: $out"; exit 1; }
    [ -d "$kept" ] || { echo "a launch with a damaged profile registry swept the root's WebKit data"; exit 1; }
    "$agweb" quit >/dev/null 2>&1
) >"$dir/g.out" 2>&1 & l3=$!
wait $l1 $l2
wait $l3 || fail "$(cat "$dir/g.out")"
[ -n "${AGWEB_CI:-}" ] && ours && osascript -e 'tell application "Finder" to activate' >/dev/null


lane_alpha() {
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
fails "no such file" -w alpha upload '#file' /nonexistent/agweb.xlsx
check "alert: hi" -w alpha click '#al'
check '"click trusted=true","keydown Enter trusted=true","submit:hello","file:hosts"' -w alpha eval 'window.log'
check '"2"' -w alpha eval "() => document.querySelector('#s').value"

fails "already uses profile selftest-alpha" -w alpha open -p other
fails "not profile other" -w alpha eval 1 -p other
check "Page" -w alpha eval 1 -p selftest-alpha
export AGWEB_PROFILE=other
check "Page" -w alpha eval 1
unset AGWEB_PROFILE
}
lanes="$lanes alpha"

lane_ptr() {
check "Title: agweb test" -w ptr open "$u"
# The tab on screen: its typing keeps the keyboard, where the other lanes' tabs hand it back after each key.
check "Title" -w ptr show
check "Page" -w ptr fill '#q' hello
echo "== the pointer glides: trusted mousemoves arrive, :hover follows, typing is per key"
check "Page" -w ptr mousemove 5 5 --instant
check 'false' -w ptr eval "() => { moves = 0; return document.querySelector('#b').matches(':hover') }"
paced "Page" -w ptr hover '#b'
check 'true' -w ptr eval "() => document.querySelector('#b').matches(':hover') && moves > 5"
fails "inside the" -w ptr mousemove nan 5
fails "inside the" -w ptr mousemove 5 99999
check "Page" -w ptr eval "() => { q.focus(); q.setSelectionRange(99, 99); inputs = 0 }"
start=$(now)
paced "Page" -w ptr type ' world'
/usr/bin/python3 -c "import sys; sys.exit(0 if $(now) - $start >= 0.6 else 1)" || fail "typing ' world' took under 0.6 s; it should go at a person's pace"
check "Page" -w ptr type '!' --instant
check '\["hello world!",7\]' -w ptr eval '[q.value, inputs]'
check "Page" -w ptr eval "() => { window.keys = []; q.addEventListener('keydown', e => keys.push(e.key + (e.isTrusted ? '' : '!'))) }"
paced "Page" -w ptr type 'Ab é'
check '"A","b"," "\]' -w ptr eval 'keys'
check 'hello world!Ab é' -w ptr eval 'q.value'
check "Page" -w ptr fill '#q' 'hello world!'

"$agweb" -w ptr close >/dev/null 2>&1
}
lanes="$lanes ptr"

lane_out() {
check "Title: agweb test" -w out open "$u"
check "Page" -w out fill '#q' 'hello world!'
echo "== output modes and files"
check '^hello world!$' -w out --raw eval 'q.value'
check '"ok":true' -w out --json eval '1'
check '"workspaces":\[{' list --json
check "$dir/snap.md" -w out snapshot --filename="$dir/snap.md"
grep -q 'button "Press me"' "$dir/snap.md" || fail "snapshot --filename did not write the tree"
check "$dir/el.png" -w out screenshot '#b' --path="$dir/el.png"
[ "$(sips -g pixelWidth "$dir/el.png" | awk '/pixelWidth/ {print $2}')" -lt 400 ] || fail "screenshot '#b' is not just the button"
check "continues [0-9]* px below the viewport" -w out screenshot --filename="$dir/top.png"
check "Screenshot" -w out screenshot --full-page --filename="$dir/full.jpg"
[ "$(sips -g pixelHeight "$dir/full.jpg" | awk '/pixelHeight/ {print $2}')" -gt 3000 ] || fail "screenshot --full-page is not the whole page"
check '^\[Next page\](/index.html?next)$' -w out --raw markdown 'a'
check "$dir/page.md" -w out markdown --filename="$dir/page.md"
check "no article here" -w out markdown
check "^agweb: Note: no article here" -w out --raw markdown
grep -q 'Press me' "$dir/page.md" || fail "markdown --filename did not write the page"
# A chat keeps the document at the window's height (here plus the body's margin) and scrolls its messages inside; a long page whose root sets
# overflow scrolls by itself, and its full page has no blank band.
printf '<html><body style="height:100vh;display:flex;flex-direction:column"><div style="flex:1;overflow:auto"><div id="big" style="height:2500px">big</div><div style="height:1500px"></div></div></body></html>' > "$dir/chat.html"
printf '<!doctype html><html style="overflow-y:scroll"><body style="margin:0"><div style="height:5000px">tall</div></body></html>' > "$dir/rootscroll.html"
height() { sips -g pixelHeight "$1" | awk '/pixelHeight/ {print $2}'; }
check "Page" -w out goto "http://127.0.0.1:$port/chat.html"
check "Screenshot" -w out screenshot --full-page --filename="$dir/chat.png"
[ "$(height "$dir/chat.png")" -ge 4000 ] || fail "screenshot --full-page missed a chat's scrolled messages"
check "Screenshot" -w out screenshot '#big' --filename="$dir/big.png"
[ "$(height "$dir/big.png")" -eq 2500 ] || fail "screenshot of an element taller than the viewport is not all of it"
# One pixel per CSS pixel; --full-resolution has the screen's.
dpr=$("$agweb" -w out --raw eval 'devicePixelRatio')
check "Screenshot" -w out screenshot '#big' --full-resolution --filename="$dir/bighi.png"
[ "$(height "$dir/bighi.png")" -eq $((2500 * dpr)) ] || fail "screenshot --full-resolution is not at the screen's density"
check "Page" -w out goto "http://127.0.0.1:$port/rootscroll.html"
check "Screenshot" -w out screenshot --full-page --filename="$dir/root.png"
[ "$(height "$dir/root.png")" -eq 5000 ] || fail "screenshot --full-page of a page with root overflow is not its height"
# An app shell with a max-height stops growing: the shot ends with it and says what stays hidden.
printf '<!doctype html><body style="margin:0"><div style="height:100vh;max-height:1200px;display:flex;flex-direction:column"><div style="flex:1;overflow:auto"><div style="height:4000px">msgs</div></div><div style="height:100px">composer</div></div></body>' > "$dir/capped.html"
check "Page" -w out goto "http://127.0.0.1:$port/capped.html"
check "box that doesn't grow with the window" -w out screenshot --full-page --filename="$dir/capped.png"
[ "$(height "$dir/capped.png")" -eq 1200 ] || fail "screenshot --full-page of a capped app shell has a blank band"
"$agweb" -w out close >/dev/null 2>&1
}
lanes="$lanes out"

lane_lst() {
# A listing whose main part keeps under half the page comes back whole; a page that says it is an article stays one.
links=$(for i in $(seq 1 60); do printf '<li><a href="/s%d">Story number %d about something new today</a></li>' $i $i; done)
# Inline data: images (Google's thumbnails) keep their alt and type, not their base64; one with no alt goes.
pic="data:image/png;base64,$(printf 'iVBORw0K%.0s' $(seq 1 60))" # longer than the placeholders Defuddle drops itself
para="<p>$(for i in $(seq 1 90); do printf 'word%d ' $i; done)<img width=\"300\" height=\"200\" alt=\"Tiny dot\" src=\"$pic\"><img alt=\"\" src=\"$pic\"><img alt=\"\" src=\"$pic\" srcset=\"/lazy-real.jpg 800w\"></p>"
printf '<html><head><title>List</title>%s</head><body><nav><ul>%s</ul></nav><main><article><h1>Top</h1>%s</article></main></body></html>' '' "$links" "$para" > "$dir/listing.html"
printf '<html><head><title>Story</title>%s</head><body><nav><ul>%s</ul></nav><main><article><h1>Top</h1>%s</article></main></body></html>' '<meta property="og:type" content="article">' "$links" "$para" > "$dir/story.html"
check "Page" -w lst open "http://127.0.0.1:$port/listing.html"
check "no article here, so this is the whole page" -w lst markdown
check "agweb: Note: no article here" -w lst --raw markdown
check "Story number 60" -w lst --raw markdown
check '!\[Tiny dot\](<data:image/png… [0-9]* KB cut>)' -w lst --raw markdown
check "2 inline images" -w lst markdown
check 'lazy-real.jpg' -w lst --raw markdown
lacks "base64" -w lst markdown --all
check "Page" -w lst goto "http://127.0.0.1:$port/story.html"
check "main content only: [0-9]* of [0-9]* words on the page; markdown --all for all of it" -w lst markdown
lacks "Story number 60" -w lst --raw markdown
check '!\[Tiny dot\](<data:image/png… [0-9]* KB cut>)' -w lst --raw markdown
lacks "base64" -w lst markdown
# A page past 50 KB prints its start and says where it was cut; --filename saves all of it.
big="<p>$(for i in $(seq 1 9000); do printf 'para%d ' $i; done)</p><p>The very end</p>"
printf '<html><head><title>Big</title></head><body>%s</body></html>' "$big" > "$dir/big.html"
check "Page" -w lst goto "http://127.0.0.1:$port/big.html"
check "(cut at [0-9]* KB of [0-9]* KB: markdown <ref> reads one part, --filename=page.md saves all of it)$" -w lst --raw markdown
lacks "The very end" -w lst markdown
check "^agweb: Note: markdown cut at [0-9]* KB of [0-9]* KB; --filename saves all of it" -w lst --raw markdown
check "$dir/big.md" -w lst markdown --filename="$dir/big.md"
grep -q 'The very end' "$dir/big.md" || fail "markdown --filename did not save the whole page"
# A snapshot prints 2000 lines; --filename saves every one, and a plain snapshot after it is capped again.
printf '<html><body><ul>%s</ul></body></html>' "$(for i in $(seq 1 2500); do printf '<li><a href="/l%d">Link %d</a></li>' $i $i; done)" > "$dir/many.html"
check "Page" -w lst goto "http://127.0.0.1:$port/many.html"
check "truncated at 2000 lines; snapshot --filename saves all of them" -w lst snapshot
check "$dir/many.md" -w lst snapshot --filename="$dir/many.md"
grep -q 'link "Link 2500"' "$dir/many.md" || fail "snapshot --filename did not save every line"
! grep -q 'truncated at' "$dir/many.md" || fail "snapshot --filename was cut"
check "truncated at 2000 lines" -w lst snapshot
# find searches the whole page, past the snapshot's cap.
check 'link "Link 2400" \[ref=' -w lst find "Link 2400"
check "cut at 2000 lines; find --filename saves every match" -w lst find "Link" --max-results=1500
check "$dir/found.md" -w lst find "Link" --filename="$dir/found.md"
grep -q '^2500 lines matching' "$dir/found.md" && grep -q 'link "Link 2500"' "$dir/found.md" || fail "find --filename did not save every match"
# A page too big to look for its article in comes back whole, saying so.
printf '<html><body>%s</body></html>' "$(for i in $(seq 1 6000); do printf '<p><b>w%d</b> <i>v</i></p>' $i; done)" > "$dir/huge.html"
check "Page" -w lst goto "http://127.0.0.1:$port/huge.html"
check "a very large page (1[0-9]* elements), so this is all of it" -w lst markdown
check "closed" -w lst close
}
lanes="$lanes lst"

lane_nav() {
check "Title: agweb test" -w nav open "$u"
check "Page" -w nav eval "() => { const d = document.createElement('div'); d.id = 'veiled'; d.hidden = true; d.textContent = 'Hidden waiting state'; document.body.append(d) }"
lacks "Hidden waiting state" -w nav markdown
lacks "Hidden waiting state" -w nav markdown body
check "#veiled is hidden on the page" -w nav markdown '#veiled'
check "Page" -w nav eval "() => { const g = document.getElementById('veiled'); g.hidden = false; g.textContent = '' }"
check "#veiled shows no text yet" -w nav markdown '#veiled'
check "Page" -w nav eval "() => document.getElementById('veiled').remove()"
# A hidden copy first (a collapsed quick-login form): CSS targets the one a person sees.
check "Page" -w nav eval "() => { for (const hidden of [true, false]) { const i = document.createElement('input'); i.className = 'twin'; i.hidden = hidden; document.body.append(i) } }"
check "already true when wait started" -w nav wait '.twin'
check "Page" -w nav fill '.twin' seen
check '"seen"' -w nav eval "() => document.querySelectorAll('.twin')[1].value + document.querySelectorAll('.twin')[0].value"
fails "now: .twin\[hidden\] is on the page but hidden" -w nav wait '.twin[hidden]' --timeout=300
check "Page" -w nav eval "() => document.querySelectorAll('.twin').forEach(e => e.remove())"
check "Cloudflare check.*mousemove [0-9]* [0-9]*" -w nav goto "$u?challenge=1"
check '"note":"Cloudflare check' -w nav --json markdown
lacks "Cloudflare check" -w nav go-back
# Across a page change to another site (a new web process), as a challenge page hands over to the real one.
check "Page" -w nav eval "() => setTimeout(() => location.assign('http://localhost:$port/side.html'), 1000)"
check "waited .* s for text=\"Side button\"" -w nav wait 'text="Side button"' --timeout=10000
check "URL: $u\$" -w nav go-back
check '"undefined"' -w nav eval 'typeof Defuddle'
check "Page" -w nav fill '#q' again --submit
check '"submit:again"' -w nav eval 'log'
check "Page" -w nav click '#b' --js
check '"click trusted=false"' -w nav eval 'log'
"$agweb" -w nav close >/dev/null 2>&1
}
lanes="$lanes nav"

lane_loc() {
check "Title: agweb test" -w loc open "$u"
echo "== locators, iframes, checkboxes, buttons and keys"
ref=$("$agweb" -w loc snapshot | sed -n 's/.*button "Press me" \[ref=\(e[0-9]*\)\].*/\1/p')
check "button \"Press me\" \[ref=$ref\]" -w loc snapshot
check "no changes since the last snapshot" -w loc snapshot --diff
check "Page" -w loc eval "() => { const b = document.createElement('button'); b.id = 'added'; b.textContent = 'Added later'; document.querySelector('#f').append(b) }"
check '^+ *- button "Added later"' -w loc --raw snapshot --diff
check '^1 line matching "added later"' -w loc --raw find 'added later'
check '  - button "Added later" \[ref=' -w loc find 'Added later'
fails "nothing on the page matches" -w loc find 'no such words'
added=$("$agweb" -w loc find 'Added later' | sed -n 's/.*"Added later" \[ref=\(e[0-9]*\)\].*/\1/p')
check "Page" -w loc eval "() => document.querySelector('#added').remove()"
fails "ref $added (button \"Added later\") not found: the page changed" -w loc click "$added"
fails 'visible buttons: button "Press me" \[ref=' -w loc click 'role=button[name="Pres me"]' --timeout=0
check "Page" -w loc eval "() => { setTimeout(() => { const b = document.createElement('button'); b.id = 'later'; b.textContent = 'Later'; b.onclick = () => log.push('later'); document.body.append(b) }, 600) }"
check "Page" -w loc click '#later'
check '"later"' -w loc eval 'log'
check "Page" -w loc eval "() => { const b = document.createElement('button'); b.id = 'grow'; b.textContent = 'Grow'; b.onclick = () => { const p = document.createElement('p'); p.textContent = 'Grown by a click'; b.after(p) }; document.body.append(b) }"
check "Snapshot" -w loc snapshot
check '^+ *- text: "Grown by a click"' -w loc --raw click '#grow'
check '^- call: POST http.*index.html?api => 501' -w loc --raw click '#api'
check '  - button "Inner button"' -w loc snapshot
check "Page" -w loc click 'role=button[name="inner"]'
check "Page" -w loc click 'text=Inner button'
check '\["inner","inner"\]' -w loc eval 'log.filter(x => x === "inner")'
fails 'matches .* elements: button "Press me" \[ref=e2\]; ' -w loc click 'role=button'
check '^- form' -w loc snapshot '#f'
lacks 'Press me' -w loc snapshot '#f'
# CSS compares a URL attribute as written; the miss names the element whose resolved URL matched.
fails 'no element matches .*CSS matches action as the page writes it ("go"), not the resolved URL: form' -w loc snapshot "form[action=\"${u%/*}/go\"]"
check 'hidden on the page, so no tree; eval reads it' -w loc --raw snapshot '#tok'
check '^inner$' -w loc --raw eval '(el) => el.id' 'role=button[name="inner"]'
check "Page" -w loc check 'text=Remember me'
check "Page" -w loc check '#r2'
check '\[true,true\]' -w loc eval '[cb.checked, r2.checked]'
check "Page" -w loc check 'role=radio >> nth=0'
check '\[true,false\]' -w loc eval '[r1.checked, r2.checked]'
check "Page" -w loc check 'input[type=radio] >> nth=-1'
check "already true" -w loc wait 'role=button[name*="press"]'
fails "type takes only the text" -w loc type '#q' hello
check "agweb type:" help type
check "Page" -w loc eval "() => { const b = document.createElement('button'); b.id = 'later'; b.disabled = true; b.textContent = 'Later'; document.body.prepend(b); setTimeout(() => b.disabled = false, 400); const n = b.cloneNode(true); n.id = 'never'; document.body.prepend(n) }"
fails "#never is disabled after 300 ms" -w loc click '#never' --timeout=300
check "#later to be enabled" -w loc wait '#later' --enabled
check "Page" -w loc eval "() => { const c = document.createElement('input'); c.type = 'checkbox'; c.id = 'locked'; c.checked = true; c.disabled = true; document.body.prepend(c) }"
check "Page" -w loc check '#locked' --timeout=300
fails "#locked is disabled" -w loc uncheck '#locked' --timeout=300
check "agweb go-forward:" help go-forward
check "agweb 0." version
check "agweb 0." --version
lacks "dialog-accept" help markdown
check "Page" -w loc eval "() => ['later', 'never', 'locked'].forEach(id => document.getElementById(id).remove())"
check "Page" -w loc uncheck '#cb'
check 'false' -w loc eval 'cb.checked'
fails "not a checkbox" -w loc check '#b'
check "Page" -w loc select '#s' One
fails "not a <select>" -w loc select '#q' x
check "context menu suppressed" -w loc click '#b' right
check "Page" -w loc keydown Shift
check "Page" -w loc mousemove 5 5 --instant
check "Page" -w loc mousedown
check "Page" -w loc mouseup
check "Page" -w loc keyup Shift
check "Page" -w loc click '#b' middle
check '\["2","0+shift","1"\]' -w loc eval 'downs.slice(-3)'
check '"contextmenu"' -w loc eval 'log'
check "Page" -w loc highlight '#b'
check '^1$' -w loc --raw eval "document.querySelectorAll('div[style*=\"2147483647\"]').length"
check "Page" -w loc highlight --hide
check '^0$' -w loc --raw eval "document.querySelectorAll('div[style*=\"2147483647\"]').length"
fails "did you mean tab-list" -w loc tabs
"$agweb" -w loc close >/dev/null 2>&1
}
lanes="$lanes loc"

lane_refs() {
check "Title" -w refs open "$u?refs"
old=$("$agweb" -w refs snapshot | sed -n 's/.*button "Press me" \[ref=\(e[0-9]*\)\].*/\1/p')
check "Title" -w refs goto "$u?refs2"
start=$(now)
fails "ref $old not found" -w refs click "$old"
/usr/bin/python3 -c "import sys; sys.exit(0 if $(now) - $start < 2 else 1)" || fail "a ref from the page before waited instead of failing at once"
lacks "button \"Press me\" \[ref=$old\]" -w refs snapshot
check '"changes":\["- call: POST http' -w refs --json click '#api'
check "closed" -w refs close
}
lanes="$lanes refs"


lane_ev() {
# eval hands over a target in a shadow root and in an iframe inside an iframe.
check "Page" -w ev open "$u"
check "Page" -w ev eval "() => { const h = document.createElement('div'); document.body.append(h); h.attachShadow({ mode: 'open' }).innerHTML = '<button>Shadow knob</button>'; const f = document.createElement('iframe'); f.srcdoc = \"<iframe srcdoc='<button>Nested knob</button>'></iframe>\"; document.body.append(f); }"
check "Page" -w ev wait 'role=button[name="Nested knob"]'
check '^Shadow knob$' -w ev --raw eval '(el) => el.textContent' 'role=button[name="Shadow knob"]'
check '^Nested knob$' -w ev --raw eval '(el) => el.textContent' 'role=button[name="Nested knob"]'
# CSS reaches into open shadow roots and frames too, when the page itself has no match (rapi-doc's API pages).
check "Page" -w ev eval "() => { const h = document.createElement('div'); document.body.append(h); h.attachShadow({ mode: 'open' }).innerHTML = '<section id=op><h2>GET /op</h2><input data-pname=\\'ident\\'><button>TRY</button></section>' }"
check 'button "TRY" \[ref=' -w ev snapshot '#op'
check 'button "TRY" \[ref=' -w ev find "GET /op"
# Text in a shadow root counts for wait --text and text, as on screen.
check 'text "GET /op"' -w ev wait --text="GET /op" --timeout=2000
check "GET /op" -w ev markdown --all
# Only shown shadow text counts: not a hidden child or a style's CSS; text loose in a shadow root does.
check "Page" -w ev eval "() => { const h = document.createElement('div'); document.body.append(h); const r = h.attachShadow({ mode: 'open' }); r.innerHTML = '<style>/* Phantomcss */</style><div hidden>Phantomtext</div>'; r.append('Loose words') }"
check 'text "Loose words"' -w ev wait --text="Loose words" --timeout=2000
fails "timed out" -w ev wait --text=Phantomtext --timeout=500
fails "timed out" -w ev wait --text=Phantomcss --timeout=500
check "Page" -w ev fill 'input[data-pname="ident"]' 42
check '^42$' -w ev --raw eval '(el) => el.value' 'input[data-pname="ident"]'
# A name longer than 120 characters ends in …, and the cut name still finds its element.
check "Page" -w ev eval "() => { const b = document.createElement('button'); b.textContent = 'Long word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word'; document.body.append(b); }"
check 'button "Long word word word word word word word word word word word word word word word word word word word word word word word…"' -w ev snapshot
check '^BUTTON$' -w ev --raw eval '(el) => el.tagName' 'role=button[name="Long word word word word word word word word word word word word word word word word word word word word word word word…"]'
check "closed" -w ev close
}
lanes="$lanes ev"

lane_hist() {
# history lists the tab's entries; go-back says when it has nowhere to go, and the next command when something else moved the tab.
check "Page" -w hist open "$u"
check "no earlier page in this tab" -w hist go-back
check "index.html?next" -w hist click 'text=Next page'
check "(current): \[.*\](.*index.html?next)" -w hist history
check "- -1: \[.*\]($u)$" -w hist history
# Later than eval's own reply takes (a move during a command counts as seen).
check "Page" -w hist eval "() => { setTimeout(() => location.assign('$u?moved'), 800) }"
# Not a command meanwhile: it would count as having seen the move.
sleep 1.5
check "the tab moved since your last command, to .*?moved" -w hist go-back
check "+1: .*?moved" -w hist history
# --raw keeps only the answer, so the move goes to stderr.
check "Page" -w hist eval "() => { setTimeout(() => location.assign('$u?moved2'), 800) }"
sleep 1.5
check "agweb: the tab moved since your last command, to .*?moved2" -w hist --raw eval "1"
# A script replacing the page counts too; a URL change inside the page doesn't.
check "Page" -w hist eval "() => { setTimeout(() => location.replace('$u?swapped'), 800) }"
sleep 1.5
check "the tab moved since your last command, to .*?swapped" -w hist eval "1"
check "Page" -w hist eval "() => { setTimeout(() => history.replaceState(null, '', '?state'), 800) }"
sleep 1.5
lacks "the tab moved" -w hist eval "1"
"$agweb" -w hist close >/dev/null 2>&1
}
lanes="$lanes hist"

lane_hist2() {
check "Title: agweb test" -w hist2 open "$u"
# The agent's own navigations are no move.
check "Page" -w hist2 open "$u?again"
lacks "the tab moved" -w hist2 reload
lacks "the tab moved" -w hist2 goto "$u?gone"
lacks "the tab moved" -w hist2 go-back
check "Page" -w hist2 eval "location.href = '$u?evalnav'"
lacks "the tab moved" -w hist2 history
# Only the entries around the current one, saying how many are left out.
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do "$agweb" -w hist2 goto "$u?n=$i" >/dev/null; done
check "Note: [0-9]* earlier not shown; --max-results=100 for all" -w hist2 history
lacks "^- -13: " -w hist2 history
check "^- -13: " -w hist2 history --max-results=100
lacks "^- -8: " -w hist2 history --max-results=8
check "closed" -w hist2 close
}
lanes="$lanes hist2"

lane_net() {
check "Title: agweb test" -w net open "$u"
echo "== network, routes, downloads and prompts"
check "Page" -w net click '#slow'
check '^1$' -w net --raw eval 'window.slowDone'
check "Page" -w net click '#api'
sleep 0.5
check 'POST\] http.*index.html?api => 501 \[fetch\]' -w net requests --filter 'api$'
n=$("$agweb" -w net requests --filter 'api$' | sed -n 's/^\([0-9]*\)\. .*/\1/p' | tail -1)
check '^x=1$' -w net request-body "${n:-0}"
check 'content-type: text/html' -w net response-headers "${n:-0}"
check "### Request ${n:-0}" -w net request "${n:-0}"
check 'x-req: yes' -w net request-headers "${n:-0}"
check 'Unsupported method' -w net response-body "${n:-0}"
fails "no request 999" -w net request 999
check "get 418" -w net route '**/index.html?api' --status 418 --body '{"mocked":true}' --content-type application/json --header 'x-test: 1'
check '\*\*/index.html?api => 418 application/json' -w net route-list
check "Page" -w net click '#api'
sleep 0.5
check '^{"mocked":true}$' -w net --raw eval 'api'
check '=> 418 (routed)' -w net requests --filter 'api$'
check '\[418,"{\\"mocked\\":true}","1"\]' -w net eval "() => new Promise(r => { const x = new XMLHttpRequest(); x.open('GET', '/index.html?api'); x.onload = () => r([x.status, x.responseText, x.getResponseHeader('x-test')]); x.send() })"
check "removed 1 routes" -w net unroute
check "no routes" -w net route-list
check "frame.html" -w net requests --static
check "api" -w net requests --clear
check "no requests" -w net requests --filter 'api$'

echo "== ad blocking"
check "ad blocking on: 3 network and 0 hiding rules from blocklist.txt" -w adb adblock update
# The page itself always loads, even one a filter names.
check "Title: agweb test" -w adb open "$u?blockapi"
check '^blocked$' -w adb --raw eval "() => fetch('/index.html?blockapi').then(() => 'loaded', () => 'blocked')"
check 'blockapi => blocked by adblock \[fetch\]' -w adb requests --filter 'blockapi$'
check '^ok$' -w adb --raw eval "() => new Promise(r => { const i = new Image(); i.onload = i.onerror = () => r('ok'); i.src = '/blockme.png' })"
check '1 more blocked by adblock' -w adb requests --filter blockme
check '### Blocked by adblock' -w adb requests --static --filter blockme
check 'ad blocking off in workspace adb' -w adb adblock off
check '^loaded$' -w adb --raw eval "() => fetch('/index.html?blockapi').then(() => 'loaded', () => 'blocked')"
check '^blocked$' -w net --raw eval "() => fetch('/index.html?blockapi').then(() => 'loaded', () => 'blocked')"
check 'ad blocking on:' -w adb adblock on
check '^blocked$' -w adb --raw eval "() => fetch('/index.html?blockapi').then(() => 'loaded', () => 'blocked')"
fails "adblock takes on, off, update" -w adb adblock bogus
fails "no workspace 'nosuch'" -w nosuch adblock off
check "agweb adblock:" help adblock
check "closed" -w adb close
check "$dir/dl/saved.html" -w net download '#dl' --filename="$dir/dl/saved.html"
[ -s "$dir/dl/saved.html" ] || fail "download did not save the file"
check "$dir/dl/saved.html" -w net download '#dl' --filename="$dir/dl/saved.html"
[ -e "$dir/dl/saved (1).html" ] && fail "download --filename did not replace the file there"
check "Page" -w net click '#dl' --download-dir="$dir/dd"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$dir/dd/saved.html" ] && break; sleep 0.3; done
[ -s "$dir/dd/saved.html" ] || fail "a download the click started did not go to --download-dir"
# A URL that answers with a file: WebKit downloads it and stops the load; goto, open and tab-new wait for the
# download and print where it went, and the page stays as it was.
check "^$dir/downloads/report.html$" -w net goto "$u?attach=report.html"
[ -s "$dir/downloads/report.html" ] || fail "goto to an attachment did not save it"
check "URL: $u\$" -w net goto "$u?attach=named.html" --filename="$dir/dl/named.html"
[ -s "$dir/dl/named.html" ] && grep -q "agweb test" "$dir/dl/named.html" || fail "goto --filename did not save the file there"
check "^$dir/downloads/first.html$" -w attach open "$u?attach=first.html"
check "closed" -w attach close
# Changes start from the page as it is: a goto between the agent's snapshot and an action is not the action navigating.
check "Snapshot" -w net snapshot
check "Page" -w net goto "$u"
lacks "navigated" -w net fill '#q' changed
check 'prompt() gets "Paul"' -w net dialog-accept Paul
check 'answered with "Paul"' -w net click '#pr'
check "will be dismissed" -w net dialog-dismiss
"$agweb" -w net close >/dev/null 2>&1
}
lanes="$lanes net"

lane_st() {
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
check "Page" -w st2 eval "() => { setTimeout(() => { const p = document.createElement('p'); p.id = 'late'; p.textContent = 'Arrived late'; document.body.prepend(p) }, 1500) }"
check "for #late" -w st2 wait '#late'
check 'text "Arrived late"' -w st2 wait --text='Arrived late'
check 'already true when wait started: text "Arrived late"' -w st2 wait --text='Arrived late'
check "Page" -w st2 eval "() => { const p = document.createElement('p'); p.textContent = 'filler '.repeat(30) + 'the long tail'; document.body.append(p) }"
check "text=the long tail" -w st2 wait 'text=the long tail' --timeout=1000
check "Page" -w st2 eval "() => { setTimeout(() => late.remove(), 1000) }"
check "#late to go" -w st2 wait '#late' --gone
fails "timed out" -w st2 wait '#nothing' --timeout=300
fails "now: no visible element matches role=button\[name=\"Kopieren\"\]; visible buttons" -w st2 wait 'role=button[name="Kopieren"]' --timeout=300
check "nothing visible matches text=\"Never here\"" -w st2 wait 'text="Never here"' --gone
fails "invalid selector" -w st2 wait 'bad[[' --timeout=5000
check '"agweb test"' -w st2 eval '(el) => el.textContent' 'role=heading[level=1]'
fails "no visible element matches role=heading" -w st2 eval '(el) => 1' 'role=heading[name="agweb"][level=2]' --timeout=1000
fails "role=heading\[level=2\]" -w st2 wait 'role=heading[level=x]' --timeout=1000
fails "put statements in" -w st2 eval 'a = 1; a'
fails "JSON Parse error: Unexpected identifier \"x\"$" -w st2 eval '() => JSON.parse("x")'
fails "SyntaxError" -w st2 eval "'abc"
lacks "Script error" -w st2 console error
check "Page" -w st2 eval "() => { dispatchEvent(new ErrorEvent('error', { message: 'Script error.' })) }"
check "pageerror: Script error. (at :0)" -w st2 console error
fails '^Error: invalid selector "": the target is empty' -w st2 wait '' --timeout=5000
fails 'invalid selector "  ": the target is empty' -w st2 fill '  ' hello
fails 'invalid selector " >> nth=0": the target is empty' -w st2 click ' >> nth=0'
fails 'invalid selector "": the target is empty' -w st2 snapshot ''
fails 'invalid selector "": the target is empty' -w st2 markdown ''
fails 'invalid selector "": the target is empty' -w st2 highlight '' --hide
fails "matches [0-9]* elements" -w st2 wait 'role=button' --timeout=5000
check "network to go quiet" -w st2 wait --load
check "Page" -w st2 emulate --color-scheme light
check 'false' -w st2 eval "matchMedia('(prefers-color-scheme: dark)').matches"
check "Page" -w st2 emulate --color-scheme dark
check 'true' -w st2 eval "matchMedia('(prefers-color-scheme: dark)').matches"
check "$dir/page.pdf" -w st2 pdf "$dir/page.pdf" --format A4
LC_ALL=C grep -qa '/Type */Page' "$dir/page.pdf" || fail "pdf wrote no pages"
check "$dir/one.pdf" -w st2 pdf --single-page --filename="$dir/one.pdf"
check "viewport is 401x301" -w st2 resize 401 301
check '\[401,301\]' -w st2 eval '[innerWidth, innerHeight]'
check "Page" -w st2 click '#b'
# One pixel per CSS pixel, odd sides included (on Retina WebKit rounds a snapshot to whole points).
check "Screenshot" -w st2 screenshot --filename="$dir/small.png"
[ "$(sips -g pixelWidth -g pixelHeight "$dir/small.png" | awk '/pixel/ {printf "%s ", $2}')" = "401 301 " ] || fail "a 401x301 viewport's screenshot is not 401x301"
check "Page" -w st2 resize 1600 1200
check '\[1600,1200\]' -w st2 eval '[innerWidth, innerHeight]'
check "workspace st closed" -w st close
check "workspace st2 closed" -w st2 close
}
lanes="$lanes st"

lane_drag() {
check "Title: agweb test" -w drag open "$u"
echo "== double click, drag and wheel"
check "Page" -w drag dblclick '#b'
check '^1$' -w drag eval 'dbl'
check "Page" -w drag drag '#rng' '#lane'
check 'true' -w drag eval "() => +rng.value > 50"
check "HTML5-draggable" -w drag drag '#card' '#lane'
check '"card"' -w drag eval 'dropped'
check "Page" -w drag eval "() => scrollTo(0, 0)"
check "Page" -w drag mousewheel 0 400
check 'true' -w drag eval "() => scrollY > 300"
check "Page" -w drag mousewheel 0 -400 --instant
check '^0$' -w drag eval 'scrollY'
fails "positive dy" -w drag mousewheel 0 down
# The wheel goes to what is under the pointer: a scroll box scrolls, the page doesn't.
check "Page" -w drag mousewheel 0 200 '#box'
check 'true' -w drag eval "() => box.scrollTop > 100 && (window.boxY ??= scrollY) === scrollY"
check "Page" -w drag mousewheel 0 100 '#box' --instant
check 'true' -w drag eval "() => box.scrollTop > 250 && scrollY === boxY"

echo "== recording"
fails "must end in .mp4" -w drag video-start "$dir"
fails "max-idle takes seconds" -w drag video-start "$dir/v.mp4" --max-idle=soon
fails "must end in .mp4" -w drag video-start --filename="$dir/v.txt"
fails "size is WIDTHxHEIGHT" -w drag video-start "$dir/v.mp4" --size=big
fails "video-chapter is gone" -w drag video-chapter x
check "recording drag" -w drag video-start "$dir/v.mp4"
check "Page" -w drag hover '#al'
check "Page" -w drag eval "async () => { for (const c of ['#fee', '#efe', '#eef']) { document.body.style.background = c; await new Promise(r => setTimeout(r, 150)) } }"
fails "already recording" -w drag video-start "$dir/w.mp4"
check "frames, " -w drag video-stop
LC_ALL=C grep -qa moov "$dir/v.mp4" || fail "the video has no index (moov)"
fails "not recording" -w drag video-stop
# A page that never stops changing: time between commands is still cut to max-idle.
check "Page" -w drag eval "() => { window.blink = setInterval(() => document.body.style.background = document.body.style.background ? '' : '#eee', 100) }"
check "recording" -w drag video-start "$dir/idle.mp4" --max-idle=0.5
sleep 3
seconds=$("$agweb" -w drag video-stop | video_seconds)
/usr/bin/python3 -c "import sys; sys.exit(0 if 0 < ${seconds:-0} < 2.5 else 1)" || fail "3 s idle with --max-idle=0.5 gave a ${seconds:-?} s video"
check "Page" -w drag eval "() => { clearInterval(window.blink); document.body.style.background = '' }"
"$agweb" -w drag close >/dev/null 2>&1
}
lanes="$lanes drag"

lane_tabs() {
check "Title: agweb test" -w tabs open "$u"
echo "== tabs and popups"
check "popup opened as tab 1" -w tabs click '#pop'
lacks "### Tabs" -w tabs eval 1
check "1: (current)" -w tabs tab-list
check "0: (current)" -w tabs tab-select 0
check "1: (current)" -w tabs tab-select 1
fails "no tab 9" -w tabs tab-close 9
check "0: (current)" -w tabs tab-close 1
check "index.html?tabnew" -w tabs tab-new "$u?tabnew"
check "0: (current)" -w tabs tab-close 1
check "Page" -w tabs eval "() => { setTimeout(() => open('/index.html?ad'), 800) }"
sleep 1.3
check "0: (current)" -w tabs tab-list
# A tab the page opens during a wait (Loom's share page when an upload ends) is where the URL shows; a wait that
# times out still says a tab opened. The timers fire well after the wait started: an idle page can't open windows.
check "Page" -w tabs eval "() => { setTimeout(() => open('/index.html?shared'), 1500) }"
check "for a URL containing shared in tab 1, which the page opened (now current)" -w tabs wait --url=shared --timeout=5000
check "0: (current)" -w tabs tab-close 1
check "Page" -w tabs eval "() => { setTimeout(() => open('/index.html?unwanted'), 1200) }"
fails "popup opened as tab 1: .*unwanted" -w tabs wait --url=never --timeout=2500
check "0: (current)" -w tabs tab-close 1
check "opened in tab 1: .*index.html?next" -w tabs click 'text=Next page' middle
check "0: (current)" -w tabs tab-close 1
"$agweb" -w tabs close >/dev/null 2>&1
}
lanes="$lanes tabs"

lane_tabs2() {
check "Title: agweb test" -w tabs2 open "$u"
check '      - generic "deploy to TEST" \[ref=' -w tabs2 snapshot '#dt'
check 'cell "deploy to TEST"' -w tabs2 snapshot '#dt'
check '^  - button "Far button"' -w tabs2 snapshot '#rbm'
check 'dialog' -w tabs2 find "Far button"
check "scrolled" -w tabs2 scroll-into-view '#far'
check "already in view" -w tabs2 scroll-into-view '#far'
check '"in view"' -w tabs2 js "(el) => el.getBoundingClientRect().bottom <= innerHeight ? 'in view' : 'not'" '#far'
check "^scrolled" -w tabs2 scroll-into-view '#deep'
check '"inner scrolled"' -w tabs2 js "() => box.scrollTop > 0 ? 'inner scrolled' : 'not'"
check "Page" -w tabs2 eval "scrollTo(0, 0)"
start=$(now)
paced "^scrolled" -w tabs2 scroll-into-view '#far'
/usr/bin/python3 -c "import sys; sys.exit(0 if $(now) - $start > 0.25 else 1)" || fail "scroll-into-view without --instant did not glide"
fails "has no size on screen" -w tabs2 scroll-into-view '#gone' --timeout=0
# A clipboard read after an agent's click gets the workspace clipboard at once: WebKit's Paste menu would pop up at
# the real pointer.
check "Page" -w tabs2 click '#clip'
check '^read$' -w tabs2 --raw eval 'clip.dataset.got'
check "Page" -w tabs2 eval "scrollTo(0, 0)"
check "popup opened as tab 1: .*index.html?deployed" -w tabs2 click 'text=deploy to TEST'
check "0: (current)" -w tabs2 tab-close 1
before=$("$agweb" -w tabs2 tab-list | grep -c '^- ')
check "opened in tab 1: .*index.html?blank" -w tabs2 click '#blank' middle
[ "$("$agweb" -w tabs2 tab-list | grep -c '^- ')" = $((before + 1)) ] || fail "a middle click on a target=_blank link opened more than one tab"
check "0: (current)" -w tabs2 tab-close 1
check "Page" -w tabs2 keydown Meta
check "opened in tab 1: .*index.html?next" -w tabs2 click 'text=Next page'
check "Page" -w tabs2 keyup Meta
check "0: (current)" -w tabs2 tab-close 1
"$agweb" -w tabs2 close >/dev/null 2>&1
}
lanes="$lanes tabs2"

lane_tabs3() {
check "Title: agweb test" -w tabs3 open "$u"
check "Page" -w tabs3 eval "() => { addEventListener('keydown', e => window.lastKey = e.key + ':' + e.code) }"
check "Page" -w tabs3 press F5
check '"F5:F5"' -w tabs3 eval 'window.lastKey'
# KeyboardEvent.code names, as games read them.
check "Page" -w tabs3 press KeyW
check '"w:KeyW"' -w tabs3 eval 'window.lastKey'
check "index.html?next" -w tabs3 click 'a'
check "URL containing next" -w tabs3 wait --url=next
check "URL: $u\$" -w tabs3 go-back
check "index.html?next" -w tabs3 go-forward
check "index.html?next" -w tabs3 reload
check "#frag" -w tabs3 goto "$u#frag"
check "Page" -w tabs3 goto "http://127.0.0.1:$port/redirect.html"
check "URL containing redirected" -w tabs3 wait --url=redirected
check "URL: http://127.0.0.1:$port/index.html?sso" -w tabs3 goto "http://127.0.0.1:$port/later.html"
check "redirected (URL shows where it landed)" -w tabs3 goto "http://127.0.0.1:$port/x?to=http://localhost:$port/index.html%3Fbounced"
check "Page" -w tabs3 eval "location.href = '/index.html?evalnav'"
check '"?evalnav"' -w tabs3 eval 'location.search'
fails "up to 600000" -w tabs3 wait '#b' --timeout=700000
check "Page" -w tabs3 goto "$u"
check "Safari/" -w tabs3 eval navigator.userAgent
check '() => 1' -w tabs3 eval '() => () => 1'
check '42' -w tabs3 eval '40 + 2 // trailing comment'
fails "unknown command" -w tabs3 frobnicate
fails "did you mean --submit" -w tabs3 fill '#q' x --sumbit
check "Page" -w tabs3 eval "() => { q.value = ''; q.focus() }"
check "Page" -w tabs3 type --instant -- '--x "q"'
check '"--x \\"q\\""' -w tabs3 eval 'q.value'
check "Page" -w tabs3 eval "() => { q.value = '' }"
check "Page" -w tabs3 type -- '--y teh'
check '"--y teh"' -w tabs3 eval 'q.value'
fails "missing <target>" -w tabs3 click
# A port nobody listens on (port 1 is one WebKit refuses outright, and macOS 26's WebKit answers that with about:blank).
dead=$(/usr/bin/python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
fails "navigation failed.* at http://127.0.0.1:$dead/" -w tabs3 goto "http://127.0.0.1:$dead/"
fails "boom" -w tabs3 eval '() => { throw new Error("boom") }'
fails "is not a field" -w tabs3 fill '#b' x
fails "no workspace\|no session" -w nobody snapshot
"$agweb" -w tabs3 close >/dev/null 2>&1
}
lanes="$lanes tabs3"

lane_update() {
echo "== update only says what is out unless asked to install"
check "agweb $version is the latest" update --check
release 99.0.0
check "agweb 99.0.0 is out (you have $version): http://127.0.0.1:$port/" update --check
check "install it with: agweb update" update --check
fails "did you mean update" upgrade
check "Title: agweb test" -w cho open "$u"
check 'button "Press me"' -w cho snapshot
fails "no file chooser opened" -w cho upload e2 /etc/hosts
"$agweb" -w cho close >/dev/null 2>&1
}
lanes="$lanes update"

lane_cover() {
check "Title: agweb test" -w cover open "$u"
echo "== a click on a covered target fails and names the cover, as Playwright's does; --force clicks anyway"
check "Title: agweb test" -w cover goto "$u"
check "Page" -w cover eval "() => { document.body.insertAdjacentHTML('beforeend', '<div id=\"ov\"><div class=\"dark-filter\" style=\"position:fixed;inset:0;z-index:9\"></div><div role=\"dialog\" aria-modal=\"true\" aria-label=\"Cookie Settings\" style=\"position:fixed;bottom:0;right:0;width:40px;height:40px;z-index:10\">x</div></div>') }"
fails 'covered by <div.dark-filter> in #ov; dialog "Cookie Settings" is open' -w cover click '#b'
fails 'covered by <div.dark-filter>' -w cover click '#b' --timeout=0
check '^0$' -w cover --raw eval 'log.length'
check 'hover target is covered by <div.dark-filter>' -w cover hover '#b'
check "Page" -w cover click '#b' --force
check '^0$' -w cover --raw eval 'log.length'
# An overlay on its way out is waited for.
check "Page" -w cover eval "() => { setTimeout(() => ov.remove(), 400) }"
check "Page" -w cover click '#b'
check '^1$' -w cover --raw eval 'log.length'
# A sticky header over the target: scrolled out from under it.
check "Page" -w cover eval "() => { document.body.insertAdjacentHTML('beforeend', '<div id=\"hdr\" style=\"position:fixed;top:0;left:0;right:0;height:40px;z-index:9;background:#fff\"></div>'); scrollTo(0, b.getBoundingClientRect().top + scrollY - 10) }"
check "Page" -w cover click '#b'
check '^2$' -w cover --raw eval '() => { hdr.remove(); return log.length }'
# Not covers: a label's styled box over its checkbox, a slotted child over a shadow button.
check "Page" -w cover eval "() => { document.body.insertAdjacentHTML('afterbegin', '<label style=\"position:relative\"><input type=\"checkbox\" id=\"cb2\" style=\"opacity:0;position:absolute;left:0;margin:0\"><span style=\"display:inline-block;position:relative;width:20px;height:20px;background:#333\"></span> Agree</label><my-btn id=\"sb\"><span>Slotted</span></my-btn>'); const root = sb.attachShadow({ mode: 'open' }); root.innerHTML = '<button>Shadow <slot></slot></button>'; root.querySelector('button').onclick = () => sb.dataset.hit = 'yes' }"
check "Page" -w cover click '#cb2'
check '^true$' -w cover --raw eval 'cb2.checked'
check "Page" -w cover click 'role=button[name="Shadow"]'
check '^yes$' -w cover --raw eval 'sb.dataset.hit'
# check, uncheck and upload click styled controls over their native input, so a cover only warns there.
check "Page" -w cover eval "() => { document.body.insertAdjacentHTML('afterbegin', '<div style=\"position:relative\"><input type=\"checkbox\" id=\"cb3\" style=\"opacity:0;position:absolute;left:0;margin:0\"><span onclick=\"cb3.click()\" style=\"display:inline-block;position:relative;width:20px;height:20px;background:#333\"></span></div>') }"
check "click target was covered by <span" -w cover check '#cb3'
check '^true$' -w cover --raw eval 'cb3.checked'
# A click on the checkbox itself is no refusal either: its styled box takes it.
check "click target was covered by <span" -w cover click '#cb3'
check '^false$' -w cover --raw eval 'cb3.checked'
check "Title: agweb test" -w cover goto "$u"
# A backdrop in the top page over a button in a frame; a paced dblclick checks the point it aims at.
check "Page" -w cover eval "() => { log = []; const d = document.createElement('div'); d.id = 'veil'; d.style = 'position:fixed;inset:0;z-index:9'; document.body.append(d); fr.scrollIntoView({ block: 'center' }) }"
fails 'covered by <div#veil>' -w cover click 'role=button[name="inner"]'
AGWEB_INSTANT= fails 'covered by <div#veil>' -w cover dblclick '#b' --timeout=0
fails 'covered by <div#veil>' -w cover download '#dl' --timeout=0
check '^0$' -w cover --raw eval '() => { veil.remove(); return log.length }'
# A dialog the target is in is never blamed; a hidden one (aria-hidden on its wrapper) is not open.
check "Page" -w cover eval "() => { document.body.insertAdjacentHTML('afterbegin', '<div aria-hidden=\"true\"><div role=\"dialog\" aria-modal=\"true\" aria-label=\"Hidden one\">kept</div></div><div role=\"dialog\" aria-modal=\"true\" aria-labelledby=\"dt1\" id=\"dlg\"><h2 id=\"dt1\">Edit profile</h2><button id=\"save\">Save</button><div id=\"toast\" style=\"position:fixed;inset:0;z-index:9\"></div></div>'); scrollTo(0, 0) }"
fails 'covered by <div#toast>; dialog "Edit profile" is open' -w cover click '#b' --timeout=0
check "Page" -w cover eval "() => { toast.remove(); document.body.insertAdjacentHTML('beforeend', '<div id=\"toast2\" style=\"position:fixed;inset:0;z-index:9\"></div>') }"
fails 'covered by <div#toast2>, which would get the click' -w cover click '#save' --timeout=0
check "Title: agweb test" -w cover goto "$u"
"$agweb" -w cover close >/dev/null 2>&1
}
lanes="$lanes cover"

lane_frames() {
check "Title: agweb test" -w frm open "$u"
echo "== frames, accessible names and controls inside controls"
check 'combobox "Shipping speed" \[expanded\] \[value="Express"\]' -w frm snapshot
check 'option "Standard"' -w frm snapshot
check 'link "Developers"' -w frm snapshot
check '^    - columnheader "Fruit"' -w frm snapshot '#tb'
check '^    - cell "Apples"' -w frm snapshot '#tb'
check '^      - button "Buy"' -w frm snapshot '#tb'
check '^#tb tr:nth-child(2)$' -w frm --raw eval "(el) => el.matches('#tb tr:nth-child(2)') ? '#tb tr:nth-child(2)' : el.outerHTML" 'role=row[name="Apples"]'
check '  - textbox "Find"' -w frm snapshot
check "Page" -w frm fill 'role=textbox[name="Find"]' found
check '"found"' -w frm eval 'dq.value'
check "Title: frames" -w fs open "http://127.0.0.1:$port/frames.html"
check 'button "Side button"' -w fs snapshot
check 'button "Inner button"' -w fs snapshot
check 'text "Side text"' -w fs wait --text='Side text'
check "Page" -w fs click 'text=Side button'
check '"side"' -w fs eval 'window.clicked'
check "workspace fs closed" -w fs close
# Cross-origin frames (127.0.0.1 and localhost are different sites), one inside the other, below the fold: a card
# field that shows the number back in groups, as Stripe's does.
printf '<title>checkout</title><div style="height:1500px">spacer</div><iframe id="pay" title="Payment" style="width:420px;height:220px;border:4px solid" src="http://localhost:%s/xcard.html"></iframe>' "$port" >"$dir/xpay.html"
printf '<style>body{padding:10px}</style><input id="num" aria-label="Card number"><span id="shown"></span><iframe title="ZIP frame" style="margin-left:30px;width:300px;height:60px" src="http://127.0.0.1:%s/xzip.html"></iframe><script>num.oninput = () => shown.textContent = num.value.replace(/(\\d{4})(?=\\d)/g, "$1 ")</script>' "$port" >"$dir/xcard.html"
printf '<input id="zip" aria-label="ZIP"><button onclick="this.textContent = \x27zip \x27 + zip.value">Zip</button>' >"$dir/xzip.html"
check "Title: checkout" -w xo open "http://127.0.0.1:$port/xpay.html"
check '^  - textbox "Card number" \[ref=e2\]' -w xo snapshot
check '^    - textbox "ZIP" \[ref=e4\]' -w xo snapshot
check "Page" -w xo fill e2 --secret-cmd 'echo 4242424242424242'
lacks "4242" -w xo snapshot
check "^16 http://localhost:$port\$" -w xo --raw eval "el => el.value.length + ' ' + origin" e2
check "Page" -w xo click e4
check "Page" -w xo type 90210
check 'button "zip 90210"' -w xo click e5
check "Page" -w xo eval "() => { const d = document.createElement('div'); d.id = 'xveil'; d.style = 'position:fixed;inset:0'; document.body.append(d) }"
fails 'covered by <div#xveil>' -w xo click e5 --timeout=0
check "Page" -w xo eval "() => pay.remove()"
fails 'its frame reloaded or closed; take a new snapshot' -w xo click e5
check "workspace xo closed" -w xo close
# A frame taller than the window, whose own scrolling can't move the page; one with role=presentation in a table cell.
printf '<title>tall</title><iframe style="width:400px;height:2500px" src="http://localhost:%s/xtall.html"></iframe><table><tr><td>Card<iframe role="presentation" style="height:60px" src="http://localhost:%s/xzip.html"></iframe></td></tr></table>' "$port" "$port" >"$dir/xlong.html"
printf '<div style="height:2200px">x</div><button onclick="this.textContent = \x27low ok\x27">Low</button>' >"$dir/xtall.html"
check "Title: tall" -w xt open "http://127.0.0.1:$port/xlong.html"
check '^  - button "Low" \[ref=e6\]' -w xt snapshot
check '^      - textbox "ZIP" \[ref=e7\]' -w xt snapshot
check 'button "low ok"' -w xt click e6
check "Page" -w xt fill e7 123
check 'button "zip 123"' -w xt click e8
check "workspace xt closed" -w xt close
# An app shell, whose body scrolls and its window can't.
printf '<title>shell</title><style>html{height:100%%;overflow:hidden}body{height:100%%;overflow:auto;margin:0}</style><div style="height:1800px">x</div><iframe style="width:400px;height:900px" src="http://localhost:%s/xtall.html"></iframe>' "$port" >"$dir/xshell.html"
check "Title: shell" -w xs open "http://127.0.0.1:$port/xshell.html"
check '^  - button "Low" \[ref=e2\]' -w xs snapshot
check 'button "low ok"' -w xs click e2
check "workspace xs closed" -w xs close
"$agweb" -w frm close >/dev/null 2>&1
}
lanes="$lanes frames"

lane_clip() {
echo "== a page's copy lands in the workspace clipboard, never the person's"
# The person's clipboard is only read, never written: it must hold none of the strings these pages copy. (Its change
# count would also move when the person copies something meanwhile.)
printf '<title>xclip</title><button onclick="navigator.clipboard.writeText(`from the frame`)">frame copy</button>' >"$dir/xclip.html"
printf '<title>clip</title><button id=wt onclick="navigator.clipboard.writeText(`via writeText`)">wt</button><button id=ex onclick="document.addEventListener(`copy`, e => { e.clipboardData.setData(`text/plain`, `via setData`); e.preventDefault() }, { once: true }); document.execCommand(`copy`)">ex</button><button id=late onclick="setTimeout(() => navigator.clipboard.writeText(`late copy`), 1200)">late</button><button id=rd onclick="navigator.clipboard.readText().then(t => r.textContent = `read ` + t, e => r.textContent = e.name)">rd</button><button id=sel onclick="getSelection().selectAllChildren(para); document.execCommand(`copy`)">sel</button><p id=para>para text</p><input id=f value="field text"><div id=otp><input><input><input><input></div><p id=r></p><iframe src="http://localhost:%s/xclip.html"></iframe><script>otp.addEventListener(`paste`, e => { e.preventDefault(); [...otp.children].forEach((i, n) => i.value = e.clipboardData.getData(`text/plain`)[n] || ``) })</script>' "$port" >"$dir/clip.html"
# A timer's write long after any input fails, as in WebKit (one within ~5 s of a click succeeds there too).
check "Title: clip" -w cb open "http://127.0.0.1:$port/clip.html"
check 'copied "via writeText" to the workspace clipboard' -w cb click '#wt'
check 'copied "via setData"' -w cb click '#ex'
check '^via setData$' -w cb --raw clipboard
# WebKit before macOS 27 lets a click's copy run only a moment after it, so a page refuses the late one there itself.
if [ "$macos" -ge 27 ]; then
    check "Page" -w cb click '#late'
    for _ in 1 2 3 4 5 6 7 8 9 10; do [ "$("$agweb" -w cb --raw clipboard 2>/dev/null)" = "late copy" ] && break; sleep 0.5; done
    check 'copied "late copy"' -w cb snapshot
    check "Page" -w cb click '#rd'
    check '^read late copy$' -w cb --raw eval 'r.textContent'
else skip "a copy 1.2 s after a click (WebKit refuses it before macOS 27)"; fi
# A focused field doesn't take over a copy of what the page selected elsewhere.
check "Page" -w cb click '#f'
check 'copied "para text"' -w cb click '#sel'
check "Page" -w cb click '#f'
check "Page" -w cb press Meta+a
check 'copied "field text"' -w cb press Meta+c
check "holds 4 characters" -w cb clipboard-set 4821
check "Page" -w cb click '#otp input >> nth=0'
check "the page's paste handler took it" -w cb press Meta+v
check '^4821$' -w cb --raw eval "[...otp.children].map(i => i.value).join('')"
if [ "$macos" -ge 26 ]; then
    ref=$("$agweb" -w cb snapshot | sed -n 's/.*button "frame copy" \[ref=\(e[0-9]*\)\].*/\1/p')
    check 'copied "from the frame"' -w cb click "${ref:-e0}"
    check "from http://localhost:$port/xclip.html" -w cb clipboard
    # Another site never reads what the agent copied on this one; what clipboard-set gave, any page may.
    check '^NotAllowedError$' -w cb --raw eval "() => (r.textContent = '', rd.click(), new Promise(f => setTimeout(() => f(r.textContent), 300)))"
else skip "a copy from inside a frame and another site's read (not on macOS 15)"; fi
check "holds" -w cb clipboard-set given
check '^read given$' -w cb --raw eval "() => (r.textContent = '', rd.click(), new Promise(f => setTimeout(() => f(r.textContent), 300)))"
fails "clipboard-set <text>, then agweb press Meta+v" -w cb paste
check "workspace cb closed" -w cb close
}
lanes="$lanes clip"

lane_cbq() {
printf '<title>noclip</title><p id=r>none</p><script>setInterval(() => navigator.clipboard.writeText(`no gesture`).then(() => r.textContent = `leaked`, e => r.textContent = e.name), 100)</script>' >"$dir/noclip.html"
check "Title: noclip" -w cbq open "http://127.0.0.1:$port/noclip.html"
sleep 6
check '^NotAllowedError$' -w cbq --raw eval 'r.textContent'
check "the workspace clipboard is empty" -w cbq clipboard
# WebKit hands a key the page leaves alone back to the app as a new event; it is still the agent's, so the timer's
# writes after it stay off the person's clipboard (checked at the end).
check "Page" -w cbq eval "() => { document.body.append(Object.assign(document.createElement('input'), { id: 'k' })) }"
check "Page" -w cbq click '#k'
for key in End Escape Tab Meta+z; do check "Page" -w cbq press $key; done
# A timer's write may land in the workspace clipboard here or be refused: WebKit takes the page's user activation
# away after the script agweb runs after each key. Either way it must not reach the person's (checked at the end).
out=$("$agweb" -w cbq --raw clipboard 2>/dev/null)
case "$out" in "no gesture"|"") printf 'ok    a timer write after agent keys stays off the person'"'"'s clipboard\n' ;; *) fail "a timer write after agent keys: $out" ;; esac
check "workspace cbq closed" -w cbq close
}
lanes="$lanes cbq"

lane_pk() {
echo "== passkeys: agweb is the authenticator; the page checks what a site checks"
pk="http://127.0.0.1:$port/passkey.html"
pkout() { "$agweb" -w pk --raw eval "document.getElementById('out').textContent" 2>/dev/null; }
check "Title: passkeys" -w pk open "$pk" -p selftest-pk
ls "$AGWEB_ROOT/webkit" 2>/dev/null | grep -qix "$pk_store" || fail "the profile's WebKit data is not in the root"
check "no passkeys in profile selftest-pk" -w pk passkey list
check "passkey created for 127.0.0.1 (user tester)" -w pk click '#reg'
check "registered instanceof=true rk=true" -w pk --raw eval "document.getElementById('out').textContent"
check "signed in with a passkey for 127.0.0.1 (user tester)" -w pk click '#signin'
check "^verified user-1$" -w pk --raw eval "document.getElementById('out').textContent"
check "refused: this profile already has a passkey" -w pk click '#again'
check "InvalidStateError" -w pk --raw eval "document.getElementById('out').textContent"
check "refused: 127.0.0.1 can't use passkeys for example.com" -w pk click '#badrp'
check "Page" -w pk click '#abort'
case "$(pkout)" in AbortError*) printf 'ok    an aborted request\n' ;; *) fail "an aborted request: $(pkout)" ;; esac
check "Page" -w pk click '#srcdoc'
sleep 0.5
case "$(pkout)" in "srcdoc patched") printf 'ok    an inline frame gets the shim\n' ;; *) fail "an inline frame: $(pkout)" ;; esac
# The page's own timer, after the agent's 2 s grace and before the tab hides (3 s): refused.
check "Page" -w pk eval "() => { setTimeout(() => signin(), 2500) }"
sleep 3
pkv=$(pkout)
case "$pkv" in "NotAllowedError: passkeys answer only"*) printf 'ok    a page alone gets no passkey\n' ;; *) fail "a page's timer used a passkey: $pkv" ;; esac
printf '<title>xpk</title><pre id=out></pre><iframe src="http://localhost:%s/passkey.html#frame"></iframe><script>addEventListener("message", e => out.textContent = "frame: " + e.data)</script>' "$port" >"$dir/xpk.html"
check "Title: xpk" -w pk goto "http://127.0.0.1:$port/xpk.html"
check "Result" -w pk wait --text="frame:"
case "$(pkout)" in *"a frame from another site can't use"*) printf 'ok    a cross-site frame gets no passkey\n' ;; *) fail "a cross-site frame: $(pkout)" ;; esac
pkid=$("$agweb" -w pk passkey list | sed -n 's/^- \([^:]*\): 127.0.0.1.*/\1/p')
check "deleted the passkey for 127.0.0.1" -w pk passkey delete "$pkid"
fails "no passkey $pkid" -w pk passkey delete "$pkid"
check "Title: passkeys" -w pk goto "$pk"
check "refused: no agweb passkey for 127.0.0.1" -w pk click '#signin'
check "passkey created" -w pk click '#reg'
check "workspace pk closed" -w pk close
grep -q selftest-pk "$AGWEB_ROOT/passkeys.json" 2>/dev/null || fail "the profile's passkeys were not saved"
[ "$(stat -f %Lp "$AGWEB_ROOT/passkeys.json")" = 600 ] || fail "passkeys.json is not 0600"
check "Title: passkeys" -w pkf open "$pk"
check "passkey created" -w pkf click '#reg'
check "fresh workspace pkf, in memory" -w pkf passkey list
check "workspace pkf closed" -w pkf close
check "profile selftest-pk deleted" profile-delete selftest-pk
! grep -q selftest-pk "$AGWEB_ROOT/passkeys.json" || fail "a deleted profile's passkeys stayed"
}
lanes="$lanes pk"

lane_vis() {
echo "== an idle tab nobody watches is hidden; a command wakes it"
check "Title" -w vis open "$u"
check "Page" -w vis eval "() => { window.vis = []; addEventListener('visibilitychange', () => vis.push(document.visibilityState)) }"
sleep 4
check '"state":"hidden"' list --json
check '\["hidden","visible"\]' -w vis eval 'vis'
check '^30$' -w vis --raw eval "() => new Promise(r => { let n = 0; const f = () => ++n < 30 ? requestAnimationFrame(f) : r(n); requestAnimationFrame(f) })"
check "workspace vis closed" -w vis close
}
lanes="$lanes vis"

lane_unload() {
echo "== a tab unused past the limit is unloaded to free memory and reloads when used; a POST's result by its address; never the displayed tab or a workspace with unload off"
# Its own instance, unloading after 2 s, in a subshell: the checks' failures come back as its exit status.
(
    export AGWEB_ROOT="$dir/u" AGWEB_UNLOAD_SECONDS=2 AGWEB_AWAKE_SECONDS=1
    failures=0
    b="http://127.0.0.1:$port"
    # Started before the lanes (see there).
    grep -q "Unload one" "$dir/u.launch" || fail "the unloading instance did not start: $(cat "$dir/u.launch")"
    check "Unload one" -w idle open "$b/un1.html"
    check "Unload two" -w idle goto "$b/un2.html"
    check "Page" -w idle eval "() => { sessionStorage.setItem('tok', 'S1'); window.kept = 1 }"
    check "Unload two" -w kept open "$b/un2.html"
    check "unload off" -w kept unload off
    check "sound on: this workspace's tabs are heard" -w kept sound on
    check "Page" -w kept eval "() => { window.hid = 0; document.addEventListener('visibilitychange', () => { if (document.hidden) hid++ }) }"
    check "Order" -w order open "$b/order.html"
    check "Posted" -w order click '#go'
    sleep 5
    check "Unload two.*(unloaded)" -w idle tab-list
    lacks "(unloaded)" -w kept tab-list
    check '^0$' -w kept --raw eval hid
    check "(unloaded)" -w order tab-list
    check "without sending the form again" -w order eval 1
    lacks "(unloaded)" -w shown tab-list
    check "unloaded to free memory" -w idle --raw eval "JSON.stringify([sessionStorage.getItem('tok'), typeof window.kept])"
    printf '%s' "$out" | grep -q '\["S1","undefined"\]' || fail "an unloaded tab lost its sessionStorage, or kept its page's memory: $out"
    check "Unload one" -w idle history
    lacks "(unloaded)" -w idle tab-list
    check "did not send the form again" -w order go-back
    [ "$(wc -l <"$dir/posts.log")" -eq 1 ] || fail "the POST's result was sent again: $(cat "$dir/posts.log")"
    "$agweb" quit >/dev/null 2>&1
    exit "$failures"
)
failures=$((failures + $?))
}
lanes="$lanes unload"

lane_shared() {
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
# Copying what a page logs runs none of its code: a getter on an Error's stack is how pages spot an open developer
# console (BrowserScan's CDP check), and toJSON or a patched Function.prototype.apply would show agweb too. WebKit before
# macOS 27 calls toString itself, as in Safari, so that one is no tell there.
check "Page" -w beta eval "() => { window.fired = []; const e = new Error('trapped'); Object.defineProperty(e, 'stack', { get() { fired.push('stack') } }); const apply = Function.prototype.apply; Function.prototype.apply = function (...a) { fired.push('apply'); return apply.call(this, ...a) }; console.log(e, { n: 1, get g() { fired.push('getter') }, toJSON() { fired.push('toJSON') }, toString() { fired.push('toString') } }); Function.prototype.apply = apply }"
if [ "$macos" -ge 27 ]; then check '^\[\]$' -w beta --raw eval 'JSON.stringify(fired)'
else check '^\[\("toString"\)\{0,1\}\]$' -w beta --raw eval 'JSON.stringify(fired)'; fi
check 'log: Error: trapped {"n":1,"g":\[getter\],"toJSON":\[function toJSON\],"toString":\[function toString\]}' -w beta console --clear
check "Page" -w beta eval "() => console.log('before-reload')"
check "Page" -w beta reload
lacks "before-reload" -w beta console
check "^profile selftest-shared$" list
check "^  - beta (" list
check "^  - eph1 (" list
check "selftest-shared: beta, gamma" profile list
# The old names still work.
check "selftest-shared: beta, gamma" profile-list
fails "in use by beta, gamma" profile-delete selftest-shared
check "profile set <name> proxy" help profile-list
# Not `AGWEB_ROOT=... run`: sh keeps an assignment made before a function call.
out=$(AGWEB_ROOT="$dir/o" "$agweb" profile 2>&1) || fail "the instance on another root failed: $out"
printf '%s' "$out" | grep -q "no named profiles" || fail "an instance on another root sees this one's profiles: $out"
if [ "$test_domain" != "$domain" ]; then
    out=$(env -u AGWEB_ROOT "$agweb" list 2>&1) && fail "a test build ran without AGWEB_ROOT: $out"
    printf '%s' "$out" | grep -q "test build" || fail "a test build without AGWEB_ROOT said: $out"
fi
[ -S "$dir/o/agweb.sock" ] || fail "the instance on another root has no socket in its root"
AGWEB_ROOT="$dir/o" "$agweb" quit >/dev/null 2>&1
check "confirm() and prompt() will be accepted" -w beta dialog-accept
check "will be dismissed" -w beta dialog-dismiss

}
lanes="$lanes shared"

lane_edit() {
echo "== typing in a tab nobody shows: a rich editor keeps its caret across keys, inserted characters land at it"
check "Title: agweb test" -w edit open "$u"
check "Page" -w edit eval "() => { const d = document.createElement('div'); d.id = 'ed'; d.contentEditable = 'true'; d.textContent = 'start end'; document.body.prepend(d) }"
check "Page" -w edit click '#ed'
check "Page" -w edit eval "() => { const r = document.createRange(); r.setStart(ed.firstChild, 6); r.collapse(true); getSelection().removeAllRanges(); getSelection().addRange(r) }"
paced "Page" -w edit type 'mid '
check 'contenteditable\|generic' -w edit snapshot
paced "Page" -w edit type 'dlé '
check "Page" -w edit type --instant 'ü'
check '^start mid dlé üend$' -w edit --raw eval 'ed.textContent'
check "Page" -w edit fill '#q' 'one'
paced "Page" -w edit type 'é two'
check '^oneé two$' -w edit --raw eval 'q.value'
"$agweb" -w edit close >/dev/null 2>&1
}
lanes="$lanes edit"

lane_basic() {
echo "== HTTP Basic logins"
# In a fresh workspace: WebKit keeps an accepted login for its data store.
basic="$u?basic=alice:pw-basic-1"
check 'HTTP 401: http://127.0.0.1:[0-9]* asks for a Basic login (realm "agweb")' -w basic open "$basic"
check "refused the one for alice" -w basic goto "$basic" --basic-auth alice:wrong-pw
check "refused the one for alice" -w basic reload
[ "$(grep -c . "$dir/auth.log" 2>/dev/null)" = 1 ] && printf 'ok    a refused Basic login is sent once\n' || fail "a refused Basic login was sent $(grep -c . "$dir/auth.log" 2>/dev/null) times"
check "Title: agweb test" -w basic goto "$basic" --basic-auth alice --secret-cmd 'printf pw-basic-1'
check '^<hidden> <hidden>$' -w basic --raw eval "'pw-basic-1 ' + btoa('alice:pw-basic-1')"
fails "works with open <url> and goto <url>" -w basic reload --basic-auth alice:x
lacks "HTTP 401" -w basic goto "$u?bearer=1"
check "closed" -w basic close
}
lanes="$lanes basic"

lane_quiet() {
check "Title" -w quiet open "$u" -p selftest-quiet
check "Page" -w quiet eval "() => { document.cookie = 'quiet=1' }"
}
lanes="$lanes quiet"

lane_proxy() {
echo "== a named profile's proxy: its pages go through it, nothing goes direct when it fails, no password shows"
free_port() { /usr/bin/python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
sport=$(free_port) hport=$(free_port) dead=$(free_port)
/usr/bin/python3 "$scripts/proxy.py" --socks "$sport" --http "$hport" --log "$dir/proxy.log" --auth "px:$pw" --map proxied.agweb.test=127.0.0.1 2>"$dir/proxy.err" &
proxy=$!
echo "$proxy" >"$dir/proxy.pid"
for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q ready "$dir/proxy.log" 2>/dev/null && break; sleep 0.3; done
grep -q ready "$dir/proxy.log" 2>/dev/null || fail "proxy.py did not start: $(cat "$dir/proxy.err")"
check "profile selftest-px: proxy socks5://px@127.0.0.1:$sport, password saved" profile set selftest-px proxy "socks5://px@127.0.0.1:$sport" --secret-cmd "echo $pw"
check "Title: agweb test" -w px open -p selftest-px "$proxied"
grep -q "socks5 proxied.agweb.test:$port px" "$dir/proxy.log" || fail "the SOCKS5 proxy did not carry the page with its credentials: $(cat "$dir/proxy.log")"
check "Title: agweb test" -w pxd open "$u"
fails "navigation failed" -w pxd goto "$proxied"
check "Page" -w pxd goto "$u"
check "profile selftest-hx: proxy http://px@127.0.0.1:$hport, password saved" profile set selftest-hx proxy "http://px:$pw@127.0.0.1:$hport"
check "Title: agweb test" -w hx open -p selftest-hx "$proxied"
grep -q "http proxied.agweb.test:$port px" "$dir/proxy.log" || fail "the HTTP proxy did not carry the page with its credentials: $(cat "$dir/proxy.log")"
check "selftest-px (proxy socks5://px@127.0.0.1:$sport, password saved): px" profile list
lacks "$pw" profile list
[ "$(stat -f %Lp "$AGWEB_ROOT/profiles/proxies.json")" = 600 ] || fail "proxies.json is not 0600"
fails "a proxy password needs a username" profile set selftest-x proxy "socks5://127.0.0.1:$sport" --secret-cmd "echo $pw"
fails "has a password and --secret-cmd" profile set selftest-x proxy "socks5://px:$pw@127.0.0.1:$sport" --secret-cmd "echo $pw"
fails "the proxy needs a port" profile set selftest-x proxy "socks5://px:$pw@127.0.0.1"
fails "unknown key colour; keys: proxy" profile set selftest-x colour red
fails "a proxy username needs a password" profile set selftest-x proxy "socks5://px@127.0.0.1:$sport"
fails "no profile selftest-nope" profile set selftest-nope proxy off
# Mistyped, so the CLI can't send the password apart: it sends nothing.
fails "use: agweb profile set <name> proxy <url>" profile set selftest-x "socks5://px:$pw@127.0.0.1:$sport"
# Fails closed: a refused password and a proxy that is down fail the load and name the proxy (offline, the second
# would fail anyway).
check "password saved" profile set selftest-bad proxy "socks5://px:wrong-$pw@127.0.0.1:$sport"
fails "the proxy asked for a username and password, or refused the saved ones at .*(profile selftest-bad goes through proxy socks5://px@127.0.0.1:$sport)" -w bad open -p selftest-bad "$proxied"
check "profile selftest-down: proxy socks5://127.0.0.1:$dead$" profile set selftest-down proxy "socks5h://127.0.0.1:$dead"
fails "navigation failed: .*(profile selftest-down goes through proxy socks5://127.0.0.1:$dead)" -w down open -p selftest-down "http://example.com/"
# Loopback skips the proxy, as the help says.
check "Title: agweb test" -w down goto "$u"
# Changed after its first open in this run: WebKit would keep the old tunnels, so it waits for the next start.
check "applies when agweb next starts" profile set selftest-px proxy off
check "selftest-px (no proxy from agweb's next start; now going through socks5://px@127.0.0.1:$sport): px" profile list
fails "proxy changed after it was opened in this run" -w px2 open -p selftest-px "$u"
check "Title: agweb test" -w px goto "$proxied?again"
"$agweb" -w pxd close >/dev/null 2>&1
kill $proxy
}
lanes="$lanes proxy"

mkdir -p "$dir/lanes"
pids=
# At most AGWEB_SELFTEST_LANES lanes at once (default: all; on CI, the runner's cores: its 3 cores stretch every
# command, and checks timed against a page's timers fail): each of that many groups runs its lanes one after another.
max=${AGWEB_SELFTEST_LANES:-$([ -n "${AGWEB_CI:-}" ] && echo 1 || echo 1000)}
n=0
for name in $lanes; do eval "group_$((n % max))=\"\${group_$((n % max)):-} $name\""; n=$((n + 1)); done
g=0
while [ "$g" -lt "$max" ] && [ "$g" -lt "$n" ]; do
    eval "names=\$group_$g"
    (
        for name in $names; do
            ( failures=0; began=$(date +%s); "lane_$name"; echo "$failures" >"$dir/lanes/$name.fail"; echo "$(($(date +%s) - began))" >"$dir/lanes/$name.secs" ) >"$dir/lanes/$name.out" 2>&1
        done
    ) &
    pids="$pids $!"
    g=$((g + 1))
done
# Not a bare wait: the test server runs in the background too.
wait $pids
for name in $lanes; do
    echo "== lane $name: $(cat "$dir/lanes/$name.secs" 2>/dev/null || echo '?') s"
    cat "$dir/lanes/$name.out"
    failures=$((failures + $(cat "$dir/lanes/$name.fail" 2>/dev/null || echo 1)))
done

# No page wrote the person's clipboard, in any lane.
pbpaste | grep -q -e 'no gesture' -e 'via writeText' -e 'via setData' -e 'late copy' -e 'field text' -e 'from the frame' && fail "a page wrote the person's clipboard"
# Shown only now: the ptr lane's tab stayed the one on screen while the lanes ran (ask shows its tab, so it runs
# here too, beside the checks below).
check "Title" -w beta show
lane_asker() {
check "Title" -w asker open "$u?ask"
check "Page" -w asker eval "() => { setTimeout(() => { document.body.append('Logged in as tester') }, 2000) }"
"$agweb" -w asker ask "Log in please" --text='Logged in as tester' --timeout=10000 >"$dir/ask.out" 2>&1 &
asking=$!
sleep 0.4
check '"asking":"Log in please"' list --json
wait $asking || fail "ask did not return when its text appeared: $(cat "$dir/ask.out")"
grep -q 'text "Logged in as tester" (the person didn' "$dir/ask.out" || fail "ask's reply: $(cat "$dir/ask.out")"
check '"asking":null' list --json
fails "timed out after 0.5 s waiting for the person" -w asker ask "Nobody will click" --timeout=500
check "closed" -w asker close
}
( failures=0; lane_asker; echo "$failures" >"$dir/asker.fail" ) >"$dir/asker.out" 2>&1 & asking_lane=$!
echo "== workspaces run in parallel (two 2 s evals, waited for after the next section)"
start=$(now)
# Each records when it ended: the checks run meanwhile would count otherwise.
( "$agweb" -w alpha eval '() => new Promise(r => setTimeout(r, 2000))' >/dev/null && now >"$dir/a.end" ) & a=$!
( "$agweb" -w beta eval '() => new Promise(r => setTimeout(r, 2000))' >/dev/null && now >"$dir/b.end" ) & b=$!
echo "== a password field focused in the background leaves the Mac's secure input off (every event tap goes blind)"
printf '<title>pw</title><input id=pw type=password>' >"$dir/pw.html"
secure() { ioreg -l -w 0 | grep -c '"kCGSSessionSecureInputPID"='; }
secure_before=$(secure)
check "Title: pw" -w sec open "http://127.0.0.1:$port/pw.html"
check "Page" -w sec fill '#pw' secret
if [ "$macos" -lt 26 ]; then skip "secure input is left on (not released on macOS 15)"
elif [ "$secure_before" != 0 ]; then skip "secure input was already on (another app holds it)"
else sleep 1; [ "$(secure)" = 0 ] || fail "a password field focused in the background left secure input on"; fi
check "workspace sec closed" -w sec close
wait $a || fail "parallel eval in alpha failed"
wait $b || fail "parallel eval in beta failed"
[ -s "$dir/a.end" ] && [ -s "$dir/b.end" ] && { /usr/bin/python3 -c "import sys; sys.exit(0 if max($(cat "$dir/a.end"), $(cat "$dir/b.end")) - $start < 3.5 else 1)" || fail "two 2 s evals in different workspaces took over 3.5 s"; }
# ask puts its tab on screen, which would close the dashboard: done first.
wait $asking_lane
cat "$dir/asker.out"
failures=$((failures + $(cat "$dir/asker.fail" 2>/dev/null || echo 1)))
echo "== the dashboard shows every tab"
check "dashboard shown" dashboard --filename="$dir/dash.png"
[ "$(sips -g pixelWidth "$dir/dash.png" 2>/dev/null | awk '/pixelWidth/ {print $2}')" -gt 400 ] || fail "dashboard --filename wrote no picture"
check '"dashboard":true' list --json
check '"state":"hidden"' list --json
check "dashboard hidden" dashboard --hide
check '"dashboard":false' list --json


echo "== an unreadable proxy entry or file loads nothing, and nothing rewrites it"
# An unreadable entry, or file, loads nothing, loopback included; workspaces still open, and nothing rewrites the file.
cp "$AGWEB_ROOT/profiles/proxies.json" "$dir/proxies.json"
/usr/bin/python3 -c 'import json, sys; p = sys.argv[1]; d = json.load(open(p)); d["selftest-ur"] = {"kind": "gopher"}; json.dump(d, open(p, "w"))' "$AGWEB_ROOT/profiles/proxies.json"
fails "profile selftest-ur has an unreadable proxy in profiles/proxies.json" -w ur open -p selftest-ur "$u"
fails "profile selftest-ur has an unreadable proxy" -w ur eval 1
check "selftest-ur (proxy unreadable" profile list
check "workspace ur closed" -w ur close
echo '{' >"$AGWEB_ROOT/profiles/proxies.json"
fails "profiles/proxies.json can't be read" -w ur2 open -p selftest-ur2 "$u"
fails "profiles/proxies.json can't be read" profile set selftest-ur2 proxy off
[ "$(cat "$AGWEB_ROOT/profiles/proxies.json")" = "{" ] || fail "profile set rewrote an unreadable proxies.json"
check "workspace ur2 closed" -w ur2 close
cp "$dir/proxies.json" "$AGWEB_ROOT/profiles/proxies.json"
for name in selftest-bad selftest-down selftest-hx selftest-ur selftest-ur2; do
    "$agweb" -w "${name#selftest-}" close >/dev/null 2>&1
    check "profile $name deleted" profile delete "$name"
done
grep -q "selftest-bad\|selftest-hx" "$AGWEB_ROOT/profiles/proxies.json" && fail "profile delete left its proxy in proxies.json"
grep -rq -- "$pw" "$AGWEB_ROOT/logs" && fail "the command log holds a proxy password"

echo "== close and quit finish a recording; workspaces and tabs, a named profile, its session cookies and the window frame survive a relaunch"
check "recording" -w eph2 video-start "$dir/close.mp4"
check "### Video" -w eph2 close
LC_ALL=C grep -qa moov "$dir/close.mp4" || fail "close left the video without its index"
check "^  - eph1 (1 tab, used [0-9]" list
check '"lastUsed":"20' list --json
check "Page" -w beta eval "() => { document.cookie = 'kept=1; max-age=600'; document.cookie = 'sso=1' }"
# sessionStorage: a named profile's tab keeps it per origin, saved after commands and at quit; a fresh profile keeps none.
check "localhost" -w beta goto "http://localhost:$port/index.html?b2"
check "Page" -w beta eval "() => { sessionStorage.setItem('access_token', 'tok2') }"
check "index.html?beta" -w beta goto "$u?beta"
check "Page" -w beta eval "() => { sessionStorage.setItem('access_token', 'tok1'); setTimeout(() => sessionStorage.setItem('late', 'L'), 300) }"
check "Page" -w eph1 eval "() => { sessionStorage.setItem('fresh', 'F') }"
check "ad blocking off in workspace eph1" -w eph1 adblock off
sleep 0.5
check "dashboard shown" dashboard
# Unused for longer than Settings' limit (7 days of agweb running, by default): the workspace closes, and in a used one
# the old tab that isn't the agent's.
check "Page" -w aged open "$u?aged"
check "Page" -w kept open "$u?keep1"
check "keep2" -w kept tab-new "$u?keep2"
printf '<title>Saved title</title>' >"$dir/titled.html"; printf '<p>no title' >"$dir/untitled.html"
check "Saved title" -w titled open "http://localhost:$port/titled.html"
check "recording" -w beta video-start "$dir/quit.mp4"
check "quit.mp4" quit
LC_ALL=C grep -qa moov "$dir/quit.mp4" || fail "quit left the video without its index"
stopped
/usr/bin/python3 - "$AGWEB_ROOT/workspaces.json" <<'AGE'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
# Ages count agweb's running time, saved as `clock`; a use long before it is long unused.
old = data.get("clock", 0) - 30 * 86400
for w in data["workspaces"]:
    if w["name"] == "aged":
        w["usedClock"] = old
        for t in w["tabs"]: t["usedClock"] = old
    if w["name"] == "kept":
        for t in w["tabs"]:
            if "keep1" in t["url"]: t["usedClock"] = old
json.dump(data, open(path, "w"))
AGE
# goto as the first command of a run must still bring the profile's session cookies back, and a detour through
# another origin first (an SSO bounce) must not use up the first origin's sessionStorage.
check "index.html?first" -w beta goto "http://localhost:$port/index.html?first"
check '"tok2"' -w beta eval "sessionStorage.getItem('access_token')"
# WebKit keeps a deleted profile's folder while it holds the store (the pk lane deleted selftest-pk); this launch removes it.
ls "$AGWEB_ROOT/webkit" 2>/dev/null | grep -qix "$pk_store" && fail "a relaunch left the deleted selftest-pk's WebKit folder"
check "index.html?again" -w beta goto "$u?again"
check 'sso=1' -w beta eval 'document.cookie'
check '\["tok1","L"\]' -w beta eval "[sessionStorage.getItem('access_token'), sessionStorage.getItem('late')]"
# A reopened tab shows its saved title only until its page commits, a page without a title included.
lacks "Saved title" -w titled goto "http://localhost:$port/untitled.html"
check "workspace titled closed" -w titled close
# selftest-px's proxy, turned off in the last run, applies now: the page goes direct (the proxy is gone too, so only
# the missing proxy line tells them apart). A new query: the page itself is in WebKit's cache.
fails "navigation failed" -w px goto "$proxied?restarted"
printf '%s' "$out" | grep -q "goes through proxy" && fail "selftest-px still went through its proxy after a restart"
lacks "next start" profile list
check "workspace px closed" -w px close
check "profile selftest-px deleted" profile delete selftest-px
check '^null$' -w eph1 --raw eval "sessionStorage.getItem('fresh')"
check "ad blocking off in workspace eph1" -w eph1 adblock
check '^loaded$' -w eph1 --raw eval "() => fetch('/index.html?blockapi').then(() => 'loaded', () => 'blocked')"
check '^blocked$' -w beta --raw eval "() => fetch('/index.html?blockapi').then(() => 'loaded', () => 'blocked')"
check '"dashboard":true' list --json
check "dashboard hidden" dashboard --hide
check "^profile selftest-shared$" tree
lacks "- aged (" list
check "keep2" -w kept tab-list
lacks "keep1" -w kept tab-list
check "^fresh profile" tree
check "index.html?again" -w beta tab-list
check 'button "Press me"' -w beta snapshot
# Cleared (a logout) is saved too, so the next restart doesn't log back in.
check "Page" -w beta eval "() => { sessionStorage.clear() }"
check "bye" quit
stopped
# The second run never touched selftest-quiet (a lane set its session cookie): its quit must not save over it.
check 'quiet=1' -w quiet eval 'document.cookie'
check "workspace quiet closed" -w quiet close
check "profile selftest-quiet deleted" profile delete selftest-quiet
check 'button "Press me"' -w alpha snapshot
check '"dashboard":false' list --json
check "Title" -w delta open "$u" -p selftest-shared
check 'kept=1' -w delta eval "() => { const c = document.cookie; document.cookie = 'kept=; max-age=0'; return c }"
check 'sso=1' -w delta eval 'document.cookie'
check '^null$' -w beta --raw eval "sessionStorage.getItem('access_token')"
if [ "$test_domain" != "$domain" ] && defaults read "$test_domain" agwebMainFrame >/dev/null 2>&1; then fail "the test build saved its frame outside its root's settings"; fi
case "$(defaults read "$suite" agwebMainFrame)" in *"{900, "*) ;; *) false ;; esac || fail "the test window's saved frame was not restored"
# The person may move their own window meanwhile: only the test window's frame landing in their settings is a leak.
person_now=$(defaults read $domain agwebMainFrame 2>/dev/null)
[ "$person_now" = "$person_frame" ] || [ "$person_now" != "$(defaults read "$suite" agwebMainFrame)" ] || fail "the selftest saved its window frame over the person's"
check "workspace delta closed" close-all
check "profile selftest-shared deleted" profile delete selftest-shared
check "Title" -w zeta open "$u" -p selftest-shared
check '^""$' -w zeta eval 'document.cookie'
check "workspace zeta closed" -w zeta close
check "profile selftest-shared deleted" profile delete selftest-shared
check "profile selftest-alpha deleted" profile delete selftest-alpha
lacks "selftest" profile list
fails "no profile selftest-alpha" profile delete selftest-alpha

echo
if [ "$failures" -eq 0 ]; then echo "all checks passed"; else echo "$failures checks failed"; fi
exit "$failures"
