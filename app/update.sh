#!/bin/bash
# Update (or first-install) the AerialRotate menu-bar app, no sudo required.
#
#   ./app/update.sh
#
# The menu-bar app has no privileged role, so it lives in the user-owned
# ~/Applications and updates are a plain userspace swap: build, quit the running
# instance, replace the bundle, ensure the login item points at the new copy,
# relaunch. The privileged parts (root daemon, user agent, swiftDialog) are
# installed once per Mac by install.sh and are NOT touched here.
#
# Recurring update flow on any Mac:  git pull && ./app/update.sh
#
# Runs as the logged-in user. install.sh invokes it via
# `launchctl asuser <uid> sudo -u <user> …` so the GUI-targeting steps (login
# item, open) work from its root context too; run directly it just uses the
# session you are already in.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/AerialRotate.app"
BIN_NAME="AerialRotate"

# Resolve the real home from the directory service, not $HOME, so this is robust
# when install.sh calls us via `sudo -u` (which may not reset $HOME).
TARGET_USER="$(id -un)"
USER_HOME="$(dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory | awk '{print $2}')"
APP_DEST="$USER_HOME/Applications/$BIN_NAME.app"

echo "== building the app =="
/bin/bash "$HERE/build.sh"

echo "== quitting any running instance =="
pkill -x "$BIN_NAME" 2>/dev/null && sleep 1 || echo "  none running"

echo "== installing to $APP_DEST =="
mkdir -p "$USER_HOME/Applications"
rm -rf "$APP_DEST"
cp -R "$SRC" "$USER_HOME/Applications/"

echo "== ensuring the login item points at ~/Applications =="
# Idempotent: drop any existing AerialRotate login item (which may still point at
# the legacy /Applications copy) and re-add the ~/Applications one, hidden.
osascript >/dev/null 2>&1 <<EOF || echo "  WARN: could not set login item (add it manually in System Settings > General > Login Items)"
tell application "System Events"
  if exists login item "$BIN_NAME" then delete login item "$BIN_NAME"
  make login item at end with properties {path:"$APP_DEST", hidden:true}
end tell
EOF

echo "== launching =="
open "$APP_DEST"

VER="$(defaults read "$APP_DEST/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo '?')"
BUILD="$(defaults read "$APP_DEST/Contents/Info" CFBundleVersion 2>/dev/null || echo '?')"
echo "== done. live: $APP_DEST  (v$VER build $BUILD) =="
