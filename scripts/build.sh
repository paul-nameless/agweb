#!/bin/sh
# Builds build/Agweb.app with the agweb CLI inside it, and links bin/agweb to that CLI.
set -eu
cd "$(dirname "$0")/.."
export CC=/usr/bin/clang
app=build/Agweb.app

# Overwriting a running signed binary gets the process killed (Code Signature Invalid) with all its sessions.
if pgrep -f "$PWD/$app/Contents/MacOS/agweb" >/dev/null; then
    echo "agweb is running from $app; stop it first: bin/agweb quit" >&2
    exit 1
fi

swift build -c release
bin=$(swift build -c release --show-bin-path)
# The app and the CLI share a name, so the CLI lives in Helpers.
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources" bin
cp -f Resources/Info.plist "$app/Contents/Info.plist"
cp -f Resources/AppIcon.icns Resources/defuddle.js Resources/defuddle-LICENSE "$app/Contents/Resources/"
cp -f "$bin/AgwebApp" "$app/Contents/MacOS/agweb"
cp -f "$bin/agweb" "$app/Contents/Helpers/agweb"
# macOS ties privacy grants (Downloads, Desktop, ...) to the signature. An ad-hoc one changes on every build,
# so each rebuild asks again; a development identity keeps one Allow. AGWEB_SIGN overrides, "-" is ad-hoc.
identity=${AGWEB_SIGN:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: .*\)"/\1/p' | head -1)}
codesign --force --sign "${identity:--}" "$app/Contents/Helpers/agweb"
codesign --force --sign "${identity:--}" "$app"
ln -sf "$PWD/$app/Contents/Helpers/agweb" bin/agweb
echo "built $app; CLI: $PWD/bin/agweb"
