#!/bin/bash
# Installer for the aerial-rotate job. Run once with sudo from the repo root:
#   sudo ./install.sh
#
# Installs the script + LaunchDaemon, ensures swiftDialog is present (for
# banner notifications), loads the daily timer, and runs one rotation now.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_USER="${SUDO_USER:-$(stat -f%Su /dev/console)}"
USER_UID=$(id -u "$TARGET_USER")
USER_HOME=$(dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory | awk '{print $2}')
VIDEO_DIR="/Library/Application Support/com.apple.idleassetsd/Customer/4KSDR240FPS"
SENTINEL="/usr/local/var/aerial-rotate/trigger"   # WatchPaths trigger shared by the user agent + the app
AGENT_PLIST="$USER_HOME/Library/LaunchAgents/com.aerialrotate.aerial-rotate-agent.plist"

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
install -m 644 -o root -g wheel "$REPO_DIR/com.aerialrotate.aerial-rotate.plist" /Library/LaunchDaemons/com.aerialrotate.aerial-rotate.plist

echo "== creating the WatchPaths trigger dir (user-owned, no sudo to touch) =="
# The daemon watches $SENTINEL; the user agent and the app touch it. The dir is
# user-owned so neither needs root to fire a rotation.
install -d -o "$TARGET_USER" -g staff /usr/local/var/aerial-rotate

echo "== loading the root daemon (fires on a trigger touch via WatchPaths) =="
launchctl bootout system /Library/LaunchDaemons/com.aerialrotate.aerial-rotate.plist 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/com.aerialrotate.aerial-rotate.plist

echo "== installing + loading the user agent (owns the daily schedule) =="
# The agent runs as the user at the scheduled time and only touches the trigger;
# the daemon does the privileged rotation. Splitting timing (user-owned plist)
# from privilege (root daemon) is what lets the app reschedule without a password.
install -d -o "$TARGET_USER" -g staff "$USER_HOME/Library/LaunchAgents"
install -m 644 -o "$TARGET_USER" -g staff "$REPO_DIR/com.aerialrotate.aerial-rotate-agent.plist" "$AGENT_PLIST"
launchctl asuser "$USER_UID" launchctl bootout "gui/$USER_UID" "$AGENT_PLIST" 2>/dev/null || true
launchctl asuser "$USER_UID" launchctl bootstrap "gui/$USER_UID" "$AGENT_PLIST"

echo "== building + installing the menu-bar app =="
# The app is the interactive face over the daemon's log/state. It must run in
# the user's GUI session (login item), never as a daemon, because that's the
# only context where UNUserNotificationCenter works (the root daemon can't get a
# notification grant, swiftDialog issue #373). It has no privileged role, so it
# lives in the user-owned ~/Applications and is built + swapped by app/update.sh
# (no sudo). After this one-time install, app updates are just
# `git pull && ./app/update.sh` with no password.

# One-time legacy migration: drop the old root-owned /Applications copy + its
# login item so machines that predate the ~/Applications move transition cleanly.
# (update.sh, being unprivileged, can't remove a root-owned bundle; install.sh can.)
rm -rf /Applications/AerialRotate.app
launchctl asuser "$USER_UID" sudo -u "$TARGET_USER" osascript -e \
  'tell application "System Events" to if exists login item "AerialRotate" then delete login item "AerialRotate"' \
  >/dev/null 2>&1 || true

# Build + install via update.sh. Wrap in `launchctl asuser` so its GUI-targeting
# steps (login item, open) work from this root context; a build failure warns but
# does not abort the daemon install.
if launchctl asuser "$USER_UID" sudo -u "$TARGET_USER" /bin/bash "$REPO_DIR/app/update.sh"; then
  echo "  installed ~/Applications/AerialRotate.app (first launch may prompt to Allow Notifications)"
else
  echo "  WARN: app build/install failed — daemon is installed, but the menu-bar app was not. See output above."
fi

echo "== kicking one rotation now via the trigger (the real WatchPaths path) =="
# Touch as the user (fresh mtime) so the daemon fires through WatchPaths exactly
# as it will in normal use. This also exercises the load-fire guard's happy path.
sudo -u "$TARGET_USER" /usr/bin/touch "$SENTINEL"
echo "  waiting for the daemon to finish (up to 5 min); watch for the banners ..."
for _ in $(seq 1 150); do
  # Grep the recent tail, not just the last line: the run ends with an EXIT-trap
  # "locked cache dir" line AFTER the "applied" NOTIFY, so tail -n 1 would miss it.
  tail -n 12 /var/log/aerial-rotate.log 2>/dev/null | grep -qiE "applied|ABORT|failed" && break
  sleep 2
done

echo "== aerial videos now on disk =="
ls -lh "$VIDEO_DIR"/*.mov 2>/dev/null

echo "== free space AFTER =="
df -h /System/Volumes/Data | tail -1
echo "== done. log at /var/log/aerial-rotate.log =="
