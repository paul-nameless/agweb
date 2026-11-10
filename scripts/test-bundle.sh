#!/bin/sh
# Builds a throwaway Agweb.app from the current source in /tmp/agtest, leaving build/Agweb.app (the running app) alone.
# Run the selftest on it with: AGWEB_CLI=$(scripts/test-bundle.sh) scripts/selftest.sh
set -eu
cd "$(dirname "$0")/.."
export CC=/usr/bin/clang
swift build -c release >/dev/null
bin=$(swift build -c release --show-bin-path)
app=/tmp/agtest/Agweb.app
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
cp -f Resources/Info.plist "$app/Contents/Info.plist"
cp -f Resources/AppIcon.icns Resources/defuddle.js Resources/defuddle-LICENSE "$app/Contents/Resources/"
cp -f "$bin/AgwebApp" "$app/Contents/MacOS/agweb"
cp -f "$bin/agweb" "$app/Contents/Helpers/agweb"
codesign --force --sign - "$app/Contents/Helpers/agweb" 2>/dev/null
codesign --force --sign - "$app" 2>/dev/null
echo "$app/Contents/Helpers/agweb"
