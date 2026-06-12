#!/bin/bash
# Build the AerialRotate menu-bar app and assemble a signed .app bundle.
#
# Run AS THE LOGGED-IN USER (not via sudo) so .build/ and the ad-hoc signature
# are owned by the user, and so the app runs in the user GUI session where
# UNUserNotificationCenter actually works. install.sh invokes this via
# `sudo -u "$TARGET_USER"`.
#
# Toolchain: Command Line Tools only (no Xcode). SwiftPM builds the bare
# executable; the .app is assembled by hand around it.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/AerialRotate.app"
BIN_NAME="AerialRotate"
BUNDLE_ID="com.tyler.aerial-rotate.app"

echo "== swift build (release, arm64) =="
swift build -c release --arch arm64 --package-path "$HERE"
BIN="$HERE/.build/release/AerialRotateApp"
[ -x "$BIN" ] || { echo "ERROR: build product not found at $BIN" >&2; exit 1; }

echo "== assembling $APP =="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
install -m 755 "$BIN" "$APP/Contents/MacOS/$BIN_NAME"
install -m 644 "$HERE/Sources/AerialRotateApp/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "== ad-hoc codesign =="
# UserNotifications needs a stable signed identity, not an entitlement. Ad-hoc
# (--sign -) with a pinned --identifier gives a stable cdhash-bound identity the
# Notifications grant keys against. No --entitlements: there is no entitlement
# gate for local notifications, and App Sandbox / Hardened Runtime are only for
# notarization, which this self-signed local tool does not do.
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"

echo "== verify signature =="
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E 'Identifier|Signature' || true
echo "built $APP"
