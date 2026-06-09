#!/bin/bash
# Installer for the aerial-rotate job. Run once with sudo from the repo root:
#   sudo ./install.sh
#
# Installs the script + LaunchDaemon, ensures terminal-notifier is present (for
# banner notifications), loads the daily timer, and runs one rotation now.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_USER="${SUDO_USER:-$(stat -f%Su /dev/console)}"
VIDEO_DIR="/Library/Application Support/com.apple.idleassetsd/Customer/4KSDR240FPS"

echo "== free space BEFORE =="
df -h /System/Volumes/Data | tail -1

echo "== ensuring terminal-notifier is installed (for banner notifications) =="
if ! sudo -u "$TARGET_USER" command -v terminal-notifier >/dev/null 2>&1 \
   && [ ! -x /opt/homebrew/bin/terminal-notifier ] && [ ! -x /usr/local/bin/terminal-notifier ]; then
  echo "  installing via Homebrew as $TARGET_USER ..."
  sudo -u "$TARGET_USER" brew install terminal-notifier || \
    echo "  WARN: could not install terminal-notifier — script will fall back to osascript banners"
else
  echo "  already installed"
fi

echo "== installing script + daemon =="
install -m 755 "$REPO_DIR/aerial-rotate.sh" /usr/local/bin/aerial-rotate.sh
install -m 644 -o root -g wheel "$REPO_DIR/com.tyler.aerial-rotate.plist" /Library/LaunchDaemons/com.tyler.aerial-rotate.plist

echo "== loading daemon (daily at 12:00) =="
launchctl bootout system /Library/LaunchDaemons/com.tyler.aerial-rotate.plist 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/com.tyler.aerial-rotate.plist

echo "== running one rotation now (watch for the banners) =="
/bin/bash /usr/local/bin/aerial-rotate.sh

echo "== aerial videos now on disk =="
ls -lh "$VIDEO_DIR"/*.mov 2>/dev/null

echo "== free space AFTER =="
df -h /System/Volumes/Data | tail -1
echo "== done. log at /var/log/aerial-rotate.log =="
