#!/usr/bin/env bash
# Builds UAI.app (universal: Apple Silicon + Intel) and zips it.
# Run on a Mac with Xcode 16+ command line tools:  ./scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${UAI_VERSION:-0.1.0}"
BUILD="${UAI_BUILD:-1}"
OUT="build"
APP="$OUT/UAI.app"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/UAI"

rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/UAI"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" packaging/Info.plist > "$APP/Contents/Info.plist"

swift scripts/make-icon.swift "$OUT/AppIcon.iconset"
iconutil -c icns "$OUT/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature so macOS will run it (not notarized).
codesign --force --deep --sign - "$APP"

rm -f "$OUT/UAI.zip"
ditto -c -k --keepParent "$APP" "$OUT/UAI.zip"
echo "Built $APP and $OUT/UAI.zip"
