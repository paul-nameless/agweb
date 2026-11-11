#!/bin/sh
# Builds build/Agweb.app with the agweb CLI inside it, and links bin/agweb to that CLI.
# --test [DIR] builds a throwaway copy in DIR (default /tmp/agtest) with the bundle id <id>.test instead, leaving the
# running app alone, and prints its CLI's path. Pair it with AGWEB_ROOT; DIR can be the root itself:
#   AGWEB_CLI=$(scripts/build.sh --test) scripts/selftest.sh
#   export AGWEB_ROOT=/tmp/agw-fix; A=$(scripts/build.sh --test $AGWEB_ROOT); $A open https://example.com
set -eu
cd "$(dirname "$0")/.."
export CC=/usr/bin/clang
app=build/Agweb.app
test=false
if [ "${1:-}" = --test ]; then app=${2:-/tmp/agtest}/Agweb.app test=true; fi
case $app in /*) ;; *) app=$PWD/$app ;; esac

# Overwriting a running signed binary gets the process killed (Code Signature Invalid) with all its sessions.
if pgrep -f "$app/Contents/MacOS/agweb" >/dev/null; then
    echo "agweb is running from $app; stop it first (agweb quit, with its AGWEB_ROOT)" >&2
    exit 1
fi

# The command log (Sources/AgwebCore/CommandLog.swift) is for local builds only; a release build leaves the flag out.
swift build -c release -Xswiftc -DAGWEB_COMMAND_LOG >&2
bin=$(swift build -c release -Xswiftc -DAGWEB_COMMAND_LOG --show-bin-path)
# The app and the CLI share a name, so the CLI lives in Helpers.
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources/skill" bin
cp -f Resources/Info.plist "$app/Contents/Info.plist"
$test && plutil -replace CFBundleIdentifier -string "$(plutil -extract CFBundleIdentifier raw Resources/Info.plist).test" "$app/Contents/Info.plist"
cp -f Resources/AppIcon.icns Resources/defuddle.js Resources/defuddle-LICENSE "$app/Contents/Resources/"
cp -f skill/SKILL.md "$app/Contents/Resources/skill/"
cp -f "$bin/AgwebApp" "$app/Contents/MacOS/agweb"
cp -f "$bin/agweb" "$app/Contents/Helpers/agweb"
# macOS ties privacy grants (Downloads, Desktop, ...) to the signature. An ad-hoc one changes on every build,
# so each rebuild asks again; a development identity keeps one Allow. AGWEB_SIGN overrides, "-" is ad-hoc.
identity=${AGWEB_SIGN:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: .*\)"/\1/p' | head -1)}
$test && identity=-
codesign --force --sign "${identity:--}" "$app/Contents/Helpers/agweb"
codesign --force --sign "${identity:--}" "$app"
if $test; then echo "$app/Contents/Helpers/agweb"; exit; fi
ln -sf "$app/Contents/Helpers/agweb" bin/agweb
echo "built $app; CLI: $PWD/bin/agweb"
