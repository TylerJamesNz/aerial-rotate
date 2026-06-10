#!/bin/bash
#
# aerial-rotate.sh — keep macOS aerial wallpaper cache small, swap it for a fresh
# random one each run. Runs daily at midday from a root LaunchDaemon, but is safe
# to run manually with sudo.
#
# Each run:
#   1. unlocks the video dir (chflags nouchg) — it sits user-immutable between
#      runs so the prefetcher (idleassetsd, runs as _assetsd) can't add aerials
#   2. snapshots the dir and reports which .mov's APPEARED since last run
#      (diagnostic: proves whether the lock held)
#   3. picks a random aerial from the catalog (excludes the current one)
#   4. downloads just that one .mov, posting % banners as it goes, verifies size
#   5. pins the wallpaper to it (edits Index.plist), removes the Shuffle dict,
#      then reloads WallpaperAgent
#   6. cleans every other .mov (anything the OS snuck in while unlocked), then
#      relocks the dir (chflags uchg) so it stays a single-file cache
#
# Removing the Shuffle dict alone did NOT stop the prefetcher (it kept pulling
# aerials with the dict gone); the chflags lock is the real enforcement. Aborts
# WITHOUT deleting the old video on download/verify failure, and an EXIT trap
# relocks the dir on every exit path so a failed run never leaves it writable.

set -uo pipefail

# ---- config -----------------------------------------------------------------
TARGET_USER="tylerb"
ASSET_ROOT="/Library/Application Support/com.apple.idleassetsd/Customer"
ENTRIES="$ASSET_ROOT/entries.json"
VIDEO_DIR="$ASSET_ROOT/4KSDR240FPS"
LOG="/var/log/aerial-rotate.log"
STATE="/var/log/aerial-rotate.state"           # end-of-run snapshot of the video dir

USER_HOME=$(/usr/bin/dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
USER_UID=$(/usr/bin/id -u "$TARGET_USER" 2>/dev/null)
STORE="$USER_HOME/Library/Application Support/com.apple.wallpaper/Store/Index.plist"

DIALOG="/usr/local/bin/dialog"  # swiftDialog: registers on macOS 15 + bridges root->user session itself

CFG_PATHS=(
  "AllSpacesAndDisplays.Linked.Content.Choices.0.Configuration"
  "SystemDefault.Linked.Content.Choices.0.Configuration"
)
SHUF_PATHS=(
  "AllSpacesAndDisplays.Linked.Content.Shuffle"
  "SystemDefault.Linked.Content.Shuffle"
)

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }
die() { log "ABORT: $*"; notify "Aerial rotate failed" "$*"; exit 1; }

# Record a notification event. The daemon only LOGS it now; the menu-bar app
# (app/) owns the user-facing surface, watching this log and posting Notification
# Center banners + a smooth in-window progress bar from the user GUI session
# (the one context where UNUserNotificationCenter works, which a root daemon
# can't reach, swiftDialog issue #373). The earlier swiftDialog --mini window is
# retired: it spawned a fresh auto-dismissing window per milestone, which
# flickered. Keep the NOTIFY: log line exactly as-is, it is the app's data feed.
notify() {
  local title="$1" msg="$2"
  log "NOTIFY: $title - $msg"
  # swiftDialog window retired: the menu-bar app (app/) now owns notifications.
  # It posts Notification Center banners from the user GUI session and shows a
  # smooth in-window progress bar. The NOTIFY: log line above is the app's data
  # channel (LogTailer parses it), so it stays. This kills the per-milestone
  # window flicker (each swiftDialog call was a new auto-dismissing window).
}

# emit "<id> <mtime-epoch>" per .mov in the video dir, sorted by id
snapshot_dir() {
  local f id m
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    id=$(basename "$f" .mov)
    m=$(stat -f '%m' "$f" 2>/dev/null || echo 0)
    printf '%s %s\n' "$id" "$m"
  done < <(find "$VIDEO_DIR" -maxdepth 1 -name '*.mov') | sort
}

# ---- cache lock (chflags) ---------------------------------------------------
# idleassetsd runs as _assetsd, not root, so a root-set user-immutable flag on
# the video dir blocks it from adding new .mov's — the durable fix the Shuffle
# removal didn't deliver. Both helpers are idempotent and never fatal.
lock_cache()   { chflags uchg   "$VIDEO_DIR" 2>/dev/null && log "locked cache dir (uchg)"     || log "WARN: could not lock $VIDEO_DIR"; }
unlock_cache() { chflags nouchg "$VIDEO_DIR" 2>/dev/null && log "unlocked cache dir (nouchg)" || log "WARN: could not unlock $VIDEO_DIR"; }

# ---- preflight --------------------------------------------------------------
[ "$(id -u)" -eq 0 ]      || die "must run as root (video dir is root-owned)"
[ -f "$ENTRIES" ]         || die "catalog not found: $ENTRIES"
[ -d "$VIDEO_DIR" ]       || die "video dir not found: $VIDEO_DIR"
[ -f "$STORE" ]           || die "wallpaper store not found: $STORE"
[ -n "$USER_UID" ]        || die "could not resolve uid for $TARGET_USER"
plutil -extract "${CFG_PATHS[0]}" raw "$STORE" >/dev/null 2>&1 \
  || die "Index.plist key path missing — macOS schema may have changed"

CURRENT_ID=$(plutil -extract "${CFG_PATHS[0]}" raw "$STORE" 2>/dev/null \
  | base64 --decode 2>/dev/null \
  | plutil -extract assetID raw - 2>/dev/null)
log "current assetID: ${CURRENT_ID:-<none>}"

# ---- unlock for the run; relock on ANY exit --------------------------------
trap lock_cache EXIT
unlock_cache
notify "Rotating aerial" "unlocked cache, selecting a new aerial"

# ---- diagnostic: what appeared since last run -------------------------------
CURRENT_SNAP=$(snapshot_dir)
SNAP_COUNT=$(printf '%s\n' "$CURRENT_SNAP" | grep -c .)
log "video dir holds $SNAP_COUNT .mov(s) at start of run"
printf '%s\n' "$CURRENT_SNAP" | while read -r id m; do
  [ -n "$id" ] || continue
  log "  on disk: $id (mtime $(date -r "${m:-0}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null))"
done
if [ -f "$STATE" ]; then
  NEW_SINCE=$(comm -23 \
    <(printf '%s\n' "$CURRENT_SNAP" | awk 'NF{print $1}') \
    <(awk 'NF{print $1}' "$STATE" | sort))
  if [ -n "$NEW_SINCE" ]; then
    NEW_COUNT=$(printf '%s\n' "$NEW_SINCE" | grep -c .)
    log "APPEARED since last run (possible OS prefetch): $(printf '%s' "$NEW_SINCE" | tr '\n' ' ')"
    notify "Prefetch check" "$NEW_COUNT new aerial(s) appeared since last run"
  else
    log "no new .mov appeared since last run — prefetch appears stopped"
  fi
else
  log "no prior state file — first diagnostic run, establishing baseline"
fi

# ---- pick a new aerial (id, url, human name) --------------------------------
PICK=$(python3 - "$ENTRIES" "$CURRENT_ID" <<'PY'
import json, sys, random
data = json.load(open(sys.argv[1]))
cur = sys.argv[2]
pool = [a for a in data.get("assets", [])
        if a.get("url-4K-SDR-240FPS") and a.get("includeInShuffle", True) and a.get("id") != cur]
if not pool: sys.exit(0)
a = random.choice(pool)
print("%s\t%s\t%s" % (a["id"], a["url-4K-SDR-240FPS"], a.get("accessibilityLabel", "aerial")))
PY
)
[ -n "$PICK" ] || die "no candidate aerial found in catalog"
NEW_ID=$(cut -f1 <<<"$PICK"); NEW_URL=$(cut -f2 <<<"$PICK"); NEW_NAME=$(cut -f3 <<<"$PICK")
log "selected: $NEW_NAME ($NEW_ID)"

# ---- download with % banners + verify ---------------------------------------
DEST="$VIDEO_DIR/$NEW_ID.mov"
TMP="$VIDEO_DIR/.$NEW_ID.download"

EXPECTED=$(curl -fsSLI "$NEW_URL" | awk 'tolower($1)=="content-length:"{print $2}' | tr -d '\r')
EXP_MB=$(( ${EXPECTED:-0} / 1024 / 1024 ))
notify "Downloading $NEW_NAME" "0% of ${EXP_MB} MB"
log "downloading $NEW_NAME (${EXP_MB} MB)"

download_with_progress() {
  rm -f "$TMP"
  curl -fL --connect-timeout 30 --retry 2 -o "$TMP" "$NEW_URL" &
  local pid=$! milestone=0 cur pct
  local step=2          # report every ~2% so the bar climbs, not in 20% jumps
  while kill -0 "$pid" 2>/dev/null; do
    if [ -n "${EXPECTED:-}" ] && [ "$EXPECTED" -gt 0 ] && [ -f "$TMP" ]; then
      cur=$(stat -f%z "$TMP" 2>/dev/null || echo 0)
      pct=$(( cur * 100 / EXPECTED ))
      if [ "$pct" -ge $((milestone + step)) ] && [ "$milestone" -lt 98 ]; then
        milestone=$(( (pct / step) * step ))
        notify "Downloading $NEW_NAME" "${milestone}% ($(( cur / 1024 / 1024 )) MB)"
      fi
    fi
    sleep 1
  done
  wait "$pid"; return $?
}

verify_size() {
  local actual; actual=$(stat -f%z "$TMP" 2>/dev/null || echo 0)
  log "downloaded $actual bytes (server reported ${EXPECTED:-unknown})"
  [ -n "${EXPECTED:-}" ] && [ "$actual" != "$EXPECTED" ] && return 1
  return 0
}

if ! download_with_progress || ! verify_size; then
  log "download/verify failed, retrying once"
  notify "Retrying download" "$NEW_NAME"
  download_with_progress && verify_size || { rm -f "$TMP"; die "download failed twice — kept existing aerial"; }
fi
notify "Downloaded — applying" "$NEW_NAME (100%)"
mv -f "$TMP" "$DEST"; chown root:wheel "$DEST"; chmod 644 "$DEST"
log "saved $DEST"

# ---- pin the wallpaper to the new id + kill the Shuffle --------------------
B64=$(printf '<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>assetID</key><string>%s</string></dict></plist>' "$NEW_ID" \
  | plutil -convert binary1 -o - - | base64)
for kp in "${CFG_PATHS[@]}"; do
  plutil -replace "$kp" -data "$B64" "$STORE" || log "WARN: could not write $kp"
done

# Remove the Shuffle dict so macOS stops cycling/prefetching new aerials.
# This is the actual fix for the OS re-downloading videos behind our back:
# pinning the assetID stops the displayed shuffle, but the Shuffle dict
# (Type => afterDuration) is what keeps the prefetcher pulling new aerials.
for sp in "${SHUF_PATHS[@]}"; do
  if plutil -extract "$sp" raw "$STORE" >/dev/null 2>&1; then
    plutil -remove "$sp" "$STORE" && log "removed Shuffle: $sp" || log "WARN: could not remove $sp"
  else
    log "Shuffle already absent: $sp"
  fi
done

chown "$TARGET_USER:staff" "$STORE"
if plutil -p "$STORE" | grep -qi '"Shuffle"'; then
  log "WARN: a Shuffle dict still present after removal — prefetch may continue"
else
  log "verified: no Shuffle dict remains in Index.plist"
fi
launchctl asuser "$USER_UID" killall WallpaperAgent 2>/dev/null || true
log "pinned wallpaper to $NEW_NAME"

# ---- clean anything the OS snuck in, then relock ---------------------------
# The dir was writable this run, so idleassetsd may have slipped extra aerials
# in. Delete every .mov except the one we just pinned; the EXIT trap relocks.
snuck=0; freed=0
while IFS= read -r f; do
  [ "$f" = "$DEST" ] && continue
  sz=$(stat -f%z "$f" 2>/dev/null || echo 0)
  rm -f "$f" && { snuck=$((snuck + 1)); freed=$((freed + sz)); }
done < <(find "$VIDEO_DIR" -maxdepth 1 -name '*.mov')
freed_mb=$((freed / 1024 / 1024))
if [ "$snuck" -gt 0 ]; then
  log "cleanup: removed $snuck stray .mov(s) the OS added, freed ${freed_mb} MB"
else
  log "cleanup: no strays — only the pinned aerial on disk"
fi

lock_cache
notify "✅ New wallpaper applied" "$NEW_NAME — cleaned ${snuck} stray, freed ${freed_mb} MB, cache locked"

# ---- write end-of-run snapshot for next run's diagnostic --------------------
snapshot_dir > "$STATE"
log "state snapshot written ($(grep -c . "$STATE" 2>/dev/null) .mov on disk)"
