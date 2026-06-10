#!/bin/bash
# Installer for the aerial-rotate job. Run once with sudo from the repo root:
#   sudo ./install.sh
#
# Installs the script + LaunchDaemon, ensures swiftDialog is present (for
# banner notifications), loads the daily timer, and runs one rotation now.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_USER="${SUDO_USER:-$(stat -f%Su /dev/console)}"
VIDEO_DIR="/Library/Application Support/com.apple.idleassetsd/Customer/4KSDR240FPS"

echo "== free space BEFORE =="
df -h /System/Volumes/Data | tail -1

echo "== ensuring swiftDialog is installed (for banner notifications) =="
# swiftDialog is notarized/signed and requires macOS 15+. Unlike terminal-notifier
# and osascript (both dead NSUserNotification API on macOS 15), it registers in
# Notifications settings and its /usr/local/bin/dialog launcher bridges a root
# daemon into the logged-in user's GUI session via launchctl asuser on its own.
if [ ! -x /usr/local/bin/dialog ]; then
  # The release assets are versioned (e.g. dialog-3.0.1-4955.pkg) with no stable
  # "dialog.pkg" alias, so latest/download/dialog.pkg 404s. Resolve the real pkg
  # asset URL from the GitHub releases API instead — survives version bumps.
  echo "  resolving latest swiftDialog pkg ..."
  DIALOG_PKG_URL=$(curl -fsSL https://api.github.com/repos/swiftDialog/swiftDialog/releases/latest \
    | python3 -c "import sys,json; print(next(a['browser_download_url'] for a in json.load(sys.stdin)['assets'] if a['name'].endswith('.pkg')))")
  [ -n "$DIALOG_PKG_URL" ] || { echo "  ERROR: could not resolve swiftDialog pkg URL" >&2; exit 1; }
  echo "  installing $DIALOG_PKG_URL ..."
  curl -fsSL -o /tmp/dialog.pkg "$DIALOG_PKG_URL"
  installer -pkg /tmp/dialog.pkg -target /   # runs as root (install.sh is sudo)
  rm -f /tmp/dialog.pkg
else
  echo "  already installed"
fi

echo "== installing script + daemon =="
install -m 755 "$REPO_DIR/aerial-rotate.sh" /usr/local/bin/aerial-rotate.sh
install -m 644 -o root -g wheel "$REPO_DIR/com.tyler.aerial-rotate.plist" /Library/LaunchDaemons/com.tyler.aerial-rotate.plist

echo "== loading daemon (daily at 12:00) =="
launchctl bootout system /Library/LaunchDaemons/com.tyler.aerial-rotate.plist 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/com.tyler.aerial-rotate.plist

echo "== building + installing the menu-bar app =="
# The app is the interactive face over the daemon's log/state. It must run in
# the user's GUI session (login item), never as a daemon, because that's the
# only context where UNUserNotificationCenter works (the root daemon can't get a
# notification grant, swiftDialog issue #373). Build AS THE USER so .build/ and
# the ad-hoc signature aren't root-owned; a build failure warns but does not
# abort the daemon install.
USER_UID=$(id -u "$TARGET_USER")
if sudo -u "$TARGET_USER" /bin/bash "$REPO_DIR/app/build.sh"; then
  rm -rf /Applications/AerialRotate.app
  cp -R "$REPO_DIR/app/AerialRotate.app" /Applications/
  # Register as a hidden login item (run in the user's GUI session).
  launchctl asuser "$USER_UID" sudo -u "$TARGET_USER" osascript -e \
    'tell application "System Events" to make login item at end with properties {path:"/Applications/AerialRotate.app", hidden:true}' \
    >/dev/null 2>&1 || echo "  WARN: could not register login item (add it manually in System Settings > General > Login Items)"
  # Launch it now so it can catch this install's rotation banners.
  launchctl asuser "$USER_UID" sudo -u "$TARGET_USER" open -a /Applications/AerialRotate.app || true
  echo "  installed /Applications/AerialRotate.app (first launch may prompt to Allow Notifications)"
else
  echo "  WARN: app build failed — daemon is installed, but the menu-bar app was not. See output above."
fi

echo "== running one rotation now (watch for the banners) =="
/bin/bash /usr/local/bin/aerial-rotate.sh

echo "== aerial videos now on disk =="
ls -lh "$VIDEO_DIR"/*.mov 2>/dev/null

echo "== free space AFTER =="
df -h /System/Volumes/Data | tail -1
echo "== done. log at /var/log/aerial-rotate.log =="
