#!/usr/bin/env bash
# Builds UAI.app (universal: Apple Silicon + Intel) and zips it.
# Run on a Mac with Xcode 16+ command line tools:  ./scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${UAI_VERSION:-0.1.0}"
BUILD="${UAI_BUILD:-1}"
SPARKLE_PUBKEY="${SPARKLE_PUBKEY:-}"
OUT="build"
APP="$OUT/UAI.app"

swift build -c release --arch arm64 --arch x86_64
BINDIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BINDIR/UAI" "$APP/Contents/MacOS/UAI"
# Bundled resources (e.g. the Grok Bot icon) live in UAI_UAI.bundle; Bundle.module
# finds it next to the executable and in Contents/Resources. Copy it or the app crashes.
for bundle in "$BINDIR"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/" && cp -R "$bundle" "$APP/Contents/MacOS/"
done

# Info.plist: stamp version + the Sparkle EdDSA public key (empty until signing
# is set up). '|' delimiter because a base64 key can contain '/'.
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" \
    -e "s|__SPARKLE_PUBKEY__|$SPARKLE_PUBKEY|" \
    packaging/Info.plist > "$APP/Contents/Info.plist"

# Embed Sparkle.framework (the self-updater) from the SwiftPM artifacts. ditto
# preserves the framework's symlinks and its bundled helper apps / XPC services.
SPARKLE_FW="$(find .build -type d -path '*Sparkle.xcframework/macos-*/Sparkle.framework' ! -path '*maccatalyst*' | head -1 || true)"
if [ -n "$SPARKLE_FW" ]; then
  ditto "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"
  # The executable loads Sparkle via @rpath; point that at the Frameworks dir.
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/UAI" 2>/dev/null || true
else
  echo "WARNING: Sparkle.framework not found in .build — building without the updater embedded." >&2
fi

swift scripts/make-icon.swift "$OUT/AppIcon.iconset"
iconutil -c icns "$OUT/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

# Code-signing identity. Sparkle only installs an update whose signature matches
# the installed app's certificate. Ad-hoc signatures differ on every build and
# are rejected, so when a persistent self-signed cert is provided
# (MAC_CSC_P12_BASE64 + MAC_CSC_PASSWORD), import it and sign with it — then
# auto-updates install. Without it, fall back to ad-hoc (runs, but no auto-update).
SIGN_ID="-"
if [ -n "${MAC_CSC_P12_BASE64:-}" ] && [ -n "${MAC_CSC_PASSWORD:-}" ]; then
  KEYCHAIN="$OUT/uai-build.keychain"
  KPASS="$(openssl rand -base64 18)"
  echo "$MAC_CSC_P12_BASE64" | base64 --decode > "$OUT/codesign.p12"
  security create-keychain -p "$KPASS" "$KEYCHAIN"
  security set-keychain-settings "$KEYCHAIN"
  security unlock-keychain -p "$KPASS" "$KEYCHAIN"
  security import "$OUT/codesign.p12" -k "$KEYCHAIN" -P "$MAC_CSC_PASSWORD" -T /usr/bin/codesign
  security set-key-partition-list -S apple-tool:,apple: -s -k "$KPASS" "$KEYCHAIN" >/dev/null 2>&1 || true
  # Put our keychain first in the search list so codesign finds the identity.
  security list-keychains -d user -s "$KEYCHAIN" login.keychain-db
  SIGN_ID="UAI Self-Signed"   # the CN baked into the cert by mac-codesign-keygen
  rm -f "$OUT/codesign.p12"
  echo "Signing with self-signed identity: $SIGN_ID"
else
  echo "No MAC_CSC_* secret set — ad-hoc signing (auto-update won't install until a cert is configured)." >&2
fi

# Sign Sparkle's nested helpers inside-out first, then the whole app.
FW="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$FW" ]; then
  for nested in \
    "$FW/Versions/B/XPCServices/Downloader.xpc" \
    "$FW/Versions/B/XPCServices/Installer.xpc" \
    "$FW/Versions/B/Updater.app" \
    "$FW/Versions/B/Autoupdate" \
    "$FW/Versions/B/Sparkle"; do
    [ -e "$nested" ] && codesign --force -s "$SIGN_ID" "$nested" || true
  done
  codesign --force -s "$SIGN_ID" "$FW" || true
fi
codesign --force --deep --sign "$SIGN_ID" "$APP"
codesign --verify --deep --strict "$APP" && echo "codesign verify OK" || echo "codesign verify reported issues" >&2

rm -f "$OUT/UAI.zip"
ditto -c -k --keepParent "$APP" "$OUT/UAI.zip"
echo "Built $APP and $OUT/UAI.zip"
