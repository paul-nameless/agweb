#!/bin/sh
# Builds build/WKBrowser.app with the wkb CLI inside it, and links bin/wkb to that CLI.
set -eu
cd "$(dirname "$0")/.."
export CC=/usr/bin/clang
app=build/WKBrowser.app

# Overwriting a running signed binary gets the process killed (Code Signature Invalid) with all its sessions.
if pgrep -f "$PWD/$app/Contents/MacOS/WKBrowser" >/dev/null; then
    echo "WKBrowser is running from $app; stop it first: bin/wkb quit" >&2
    exit 1
fi

swift build -c release
bin=$(swift build -c release --show-bin-path)
mkdir -p "$app/Contents/MacOS" bin
cp -f Resources/Info.plist "$app/Contents/Info.plist"
cp -f "$bin/WKBrowser" "$bin/wkb" "$app/Contents/MacOS/"
codesign --force --sign - "$app/Contents/MacOS/wkb"
codesign --force --sign - "$app"
ln -sf "$PWD/$app/Contents/MacOS/wkb" bin/wkb
echo "built $app; CLI: $PWD/bin/wkb"
