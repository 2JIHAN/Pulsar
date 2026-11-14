#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
# Build first so the version comes from this build, not the previous one.
/bin/bash build.sh
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' build/Pulsar.app/Contents/Info.plist 2>/dev/null || echo 0.1.0)
OUT=release/$VERSION
APP=$OUT/Pulsar.app
ZIP=$OUT/Pulsar-$VERSION-macOS-arm64.zip
rm -rf "$OUT"; mkdir -p "$OUT"
ditto build/Pulsar.app "$APP"
codesign --force --options runtime --timestamp --sign "Developer ID Application: Soong Hyeong Lee (9SADL7543X)" "$APP"
/bin/bash scripts/clear-quarantine.sh "$APP"
codesign --verify --deep --strict "$APP"
"$APP/Contents/MacOS/Pulsar" --self-test
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/submission.zip"
xcrun notarytool submit "$OUT/submission.zip" --keychain-profile ThunderControl-Notarization --wait --output-format json | tee "$OUT/notarization.json"
grep -q '"status":"Accepted"' "$OUT/notarization.json"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
rm "$OUT/submission.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP" | sed "s#$OUT/##" > "$ZIP.sha256"
cat "$ZIP.sha256"
