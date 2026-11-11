#!/bin/sh
# Builds a release: build/release/Agweb.app (no command log), signed with the Developer ID, notarized and stapled,
# and build/release/Agweb.dmg, notarized and stapled too. Then commits the version and tags it locally; pushing
# and the GitHub release are left to the person:
#   scripts/release.sh 0.1.0
#   git push origin master v0.1.0 && gh release create v0.1.0 build/release/Agweb.dmg --title v0.1.0 --notes-file NOTES
# Needs a clean tree on master and the notarytool profile "agweb" (xcrun notarytool store-credentials agweb).
set -eu
cd "$(dirname "$0")/.."
export CC=/usr/bin/clang
version=${1:?usage: scripts/release.sh <version, e.g. 0.1.0>}
profile=${AGWEB_NOTARY_PROFILE:-agweb}
out=build/release
app=$out/Agweb.app
dmg=$out/Agweb.dmg

[ "$(git rev-parse --abbrev-ref HEAD)" = master ] || { echo "not on master" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "the tree has changes; commit or stash them" >&2; exit 1; }
git rev-parse -q --verify "refs/tags/v$version" >/dev/null && { echo "v$version is tagged already" >&2; exit 1; }
identity=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)
[ -n "$identity" ] || { echo "no Developer ID Application identity in the keychain" >&2; exit 1; }
xcrun notarytool history --keychain-profile "$profile" >/dev/null || { echo "no notarytool profile $profile" >&2; exit 1; }

build=$(( $(plutil -extract CFBundleVersion raw Resources/Info.plist) + 1 ))
plutil -replace CFBundleShortVersionString -string "$version" Resources/Info.plist
plutil -replace CFBundleVersion -string "$build" Resources/Info.plist
# Put the plist back if anything below fails, so a failed run leaves the tree clean.
trap 'git checkout -- Resources/Info.plist' EXIT

echo "building $version ($build)" >&2
swift build -c release >&2
bin=$(swift build -c release --show-bin-path)
[ -e "$out" ] && trash "$out"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources/skill"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/defuddle.js Resources/defuddle-LICENSE "$app/Contents/Resources/"
cp skill/SKILL.md "$app/Contents/Resources/skill/"
cp "$bin/AgwebApp" "$app/Contents/MacOS/agweb"
cp "$bin/agweb" "$app/Contents/Helpers/agweb"

# Notarization needs the hardened runtime and a secure timestamp on every executable, inside out.
codesign --force --options runtime --timestamp --sign "$identity" "$app/Contents/Helpers/agweb"
codesign --force --options runtime --timestamp --sign "$identity" "$app"
codesign --verify --strict --deep "$app"

echo "notarizing the app" >&2
ditto -c -k --keepParent "$app" "$out/Agweb.zip"
xcrun notarytool submit "$out/Agweb.zip" --keychain-profile "$profile" --wait
xcrun stapler staple "$app"
trash "$out/Agweb.zip"

echo "making the dmg" >&2
stage=$out/dmg
mkdir -p "$stage"
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"
hdiutil create -volname Agweb -srcfolder "$stage" -format UDZO -ov "$dmg" >&2
trash "$stage"
codesign --force --timestamp --sign "$identity" "$dmg"
xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait
xcrun stapler staple "$dmg"
spctl --assess --type open --context context:primary-signature -v "$dmg"
spctl --assess --type execute -v "$app"

trap - EXIT
git commit -qm "Version $version" Resources/Info.plist
git tag "v$version"
echo "$dmg: v$version tagged locally; nothing pushed" >&2
