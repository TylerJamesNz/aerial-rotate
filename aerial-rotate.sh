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
# TARGET_USER / USER_HOME / USER_UID / STORE / FAVOURITES are resolved at
# runtime in resolve_target_user() so the same install survives any operator
# (no install-time bake of a username). See `## 1. Adaptive device-state pickup`
# in the design plan for the resolution chain.
ASSET_ROOT="/Library/Application Support/com.apple.idleassetsd/Customer"
ENTRIES="$ASSET_ROOT/entries.json"
VIDEO_DIR="$ASSET_ROOT/4KSDR240FPS"
LOG="/var/log/aerial-rotate.log"
STATE="/var/log/aerial-rotate.state"           # end-of-run snapshot of the video dir

TARGET_USER=""
USER_HOME=""
USER_UID=""
STORE=""
FAVOURITES=""

SENTINEL="/usr/local/var/aerial-rotate/trigger"  # WatchPaths trigger: a fresh touch (user agent at the scheduled time, or the app's Refresh button) fires this daemon
SENTINEL_MAX_AGE=120                              # seconds; older = a launchd load-fire (boot/reload), not a real trigger -> skip

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
# die [code=<token>] <msg> — fatal abort with an optional code= prefix the app's
# LogTailer peels out of the NOTIFY message to drive a typed FatalBanner.
die() {
  local code=""
  if [[ "${1:-}" == code=* ]]; then code="$1"; shift; fi
  log "ABORT: $*"
  if [ -n "$code" ]; then notify "Aerial rotate failed" "$code $*"; else notify "Aerial rotate failed" "$*"; fi
  exit 1
}

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

# Structured preflight line. App's LogTailer matches "PREFLIGHT: <LEVEL> <check>".
# LEVEL is OK / WARN / FAIL; FAIL is paired with a die() that includes code=.
preflight_line() {
  local level="$1" check="$2"; shift 2
  log "PREFLIGHT: $level $check $*"
}

# Resolve the live GUI user every run instead of baking one at install time.
# Chain: stat /dev/console -> dscl NFSHomeDirectory -> id -u. If no GUI user
# (lockscreen, FileVault pre-boot, fast-user-switch limbo) defer cleanly with
# exit 0 — it is not an error, just nobody to render an aerial for.
resolve_target_user() {
  TARGET_USER=$(/usr/bin/stat -f '%Su' /dev/console 2>/dev/null)
  case "$TARGET_USER" in
    ""|root|loginwindow|_*)
      preflight_line FAIL user.no_gui_session "console_user=${TARGET_USER:-<empty>}"
      log "no GUI user logged in; deferring rotation (will retry on next trigger)"
      exit 0
      ;;
  esac
  preflight_line OK user.console "target_user=$TARGET_USER"

  USER_HOME=$(/usr/bin/dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory 2>/dev/null | awk '{$1=""; sub(/^ /,""); print}')
  if [ -z "$USER_HOME" ] || [ ! -d "$USER_HOME" ]; then
    preflight_line FAIL user.home_unresolved "target_user=$TARGET_USER home=${USER_HOME:-<empty>}"
    die "code=user.home_unresolved" "could not resolve home for $TARGET_USER"
  fi
  preflight_line OK user.home "target_user=$TARGET_USER home=$USER_HOME"

  USER_UID=$(/usr/bin/id -u "$TARGET_USER" 2>/dev/null)
  if [ -z "$USER_UID" ]; then
    preflight_line FAIL user.uid_unresolved "target_user=$TARGET_USER"
    die "code=user.uid_unresolved" "could not resolve uid for $TARGET_USER"
  fi
  preflight_line OK user.uid "target_user=$TARGET_USER uid=$USER_UID"

  STORE="$USER_HOME/Library/Application Support/com.apple.wallpaper/Store/Index.plist"
  FAVOURITES="$USER_HOME/Library/Application Support/aerial-rotate/shuffle-favourites.json"
  preflight_line OK store.path "store=$STORE"
}

# Single preflight block covering every assumption the rotation makes. First
# fatal failure calls die() with a code= tag the LogTailer maps to a typed
# FatalBanner; warnings (PREFLIGHT: WARN) never abort, they drive informational
# banners and let the run continue. All checks are read-only — a failed
# preflight cannot leave half-modified state, because unlock_cache (the first
# mutation) sits after preflight() returns.
preflight() {
  # macOS version, recorded for forensic correlation (never fatal).
  local macos_ver
  macos_ver=$(/usr/bin/sw_vers -productVersion 2>/dev/null || echo unknown)
  preflight_line OK macos "version=$macos_ver"

  # swiftDialog presence; the app's user-session Notifier is the real banner
  # channel so a missing dialog binary is informational, not fatal.
  if [ -x "$DIALOG" ]; then
    local dialog_ver
    dialog_ver=$("$DIALOG" --version 2>/dev/null | head -n 1)
    preflight_line OK dialog "version=${dialog_ver:-unknown}"
  else
    preflight_line WARN dialog.missing "path=$DIALOG"
  fi

  # Catalog: file must exist, parse, and contain at least one asset.
  if [ ! -f "$ENTRIES" ]; then
    preflight_line FAIL catalog.missing "path=$ENTRIES"
    die "code=catalog.missing" "catalog not found: $ENTRIES"
  fi
  local catalog_count
  catalog_count=$(python3 -c 'import json,sys
try:
    d=json.load(open(sys.argv[1]))
    print(len(d.get("assets",[])))
except Exception:
    print(-1)' "$ENTRIES" 2>/dev/null || echo -1)
  if [ "$catalog_count" -lt 0 ]; then
    preflight_line FAIL catalog.malformed "path=$ENTRIES"
    die "code=catalog.malformed" "catalog is not valid JSON: $ENTRIES"
  fi
  if [ "$catalog_count" -eq 0 ]; then
    preflight_line FAIL catalog.empty "path=$ENTRIES"
    die "code=catalog.empty" "catalog is empty (assets array has 0 entries)"
  fi
  preflight_line OK catalog "count=$catalog_count"

  # Video dir (the aerial cache).
  if [ ! -d "$VIDEO_DIR" ]; then
    preflight_line FAIL video_dir.missing "path=$VIDEO_DIR"
    die "code=video_dir.missing" "video dir not found: $VIDEO_DIR"
  fi
  preflight_line OK video_dir "path=$VIDEO_DIR"

  # Wallpaper store: file + size + mtime so a future debug session can correlate.
  if [ ! -f "$STORE" ]; then
    preflight_line FAIL store.missing "path=$STORE"
    die "code=store.missing" "wallpaper store not found: $STORE"
  fi
  local store_size store_mtime
  store_size=$(stat -f '%z' "$STORE" 2>/dev/null || echo 0)
  store_mtime=$(stat -f '%Sm' -t '%Y-%m-%dT%H:%M:%S' "$STORE" 2>/dev/null || echo unknown)
  preflight_line OK store.exists "size=$store_size mtime=$store_mtime"

  # Index.plist schema: the existing macOS 15 key-path probe. Apple changing
  # the structure (a macOS upgrade) lands here.
  if ! plutil -extract "${CFG_PATHS[0]}" raw "$STORE" >/dev/null 2>&1; then
    preflight_line FAIL store.schema_changed "probe=${CFG_PATHS[0]}"
    die "code=store.schema_changed" "Index.plist key path missing — macOS schema may have changed"
  fi
  preflight_line OK store.schema "probe=${CFG_PATHS[0]}"

  # Wallpaper Provider: must be aerials. The script will write the assetID
  # into Index.plist happily even if the operator has Landscape/Plants/Photos
  # selected, but the desktop won't repaint as an aerial because Provider is
  # something else, so the operator sees "rotation succeeded" in the log and
  # nothing change on screen. Abort BEFORE writing to give a clear banner.
  local provider
  provider=$(plutil -extract "AllSpacesAndDisplays.Linked.Content.Choices.0.Provider" raw "$STORE" 2>/dev/null)
  case "$provider" in
    com.apple.wallpaper.choice.aerials)
      preflight_line OK source "provider=$provider"
      ;;
    "")
      preflight_line FAIL source "provider=<unset>"
      die "code=source.unset" "wallpaper Provider key not set — open System Settings > Wallpaper and pick an Aerial once"
      ;;
    *)
      preflight_line FAIL source "provider=$provider"
      die "code=source.wrong" "wallpaper source is $provider; AerialRotate only rotates when set to Aerial"
      ;;
  esac

  # Shuffle dict at run START (read-only, informational). The existing
  # WallpaperWarningBanner already derives this from WallpaperStore.isRotating()
  # in the app; logging it here lets a future LogTailer extension cross-check.
  local shuffle_present=false
  for sp in "${SHUF_PATHS[@]}"; do
    if plutil -extract "$sp" raw "$STORE" >/dev/null 2>&1; then shuffle_present=true; break; fi
  done
  preflight_line OK shuffle "present=$shuffle_present"

  # Favourites (optional curated subset).
  if [ -f "$FAVOURITES" ]; then
    local fav_count
    fav_count=$(python3 -c 'import json,sys
try:
    print(len(json.load(open(sys.argv[1])).get("ids",[])))
except Exception:
    print(-1)' "$FAVOURITES" 2>/dev/null || echo -1)
    if [ "$fav_count" -lt 0 ]; then
      preflight_line WARN favourites.malformed "path=$FAVOURITES"
    else
      preflight_line OK favourites "count=$fav_count"
    fi
  else
    preflight_line OK favourites "count=0"
  fi
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

# ---- WatchPaths load-fire guard ---------------------------------------------
# launchd starts a WatchPaths job once at load (boot / install / daemon reload),
# not only when the path later changes. A real trigger always bumps the sentinel
# mtime to ~now; a load-fire sees yesterday's mtime (or no file at all). Skip
# unless the sentinel was freshly touched, so a reboot never rotates on its own.
# This also debounces an accidental double-click of the app's Refresh button.
# The script NEVER writes the sentinel, so this watch can't feed back on itself.
if [ ! -f "$SENTINEL" ]; then
  log "no trigger at $SENTINEL (load-fire before first touch); skipping."
  exit 0
fi
sentinel_age=$(( $(date +%s) - $(stat -f '%m' "$SENTINEL" 2>/dev/null || echo 0) ))
if [ "$sentinel_age" -gt "$SENTINEL_MAX_AGE" ]; then
  log "stale trigger (age ${sentinel_age}s > ${SENTINEL_MAX_AGE}s); spurious load-fire, skipping."
  exit 0
fi
log "fresh trigger (age ${sentinel_age}s); proceeding with rotation."

# ---- preflight --------------------------------------------------------------
# Root check fires before user resolution because dscl / id / stat all work fine
# as a non-root user and would silently produce a useless rotation that can't
# write Index.plist; better to fail clearly here.
if [ "$(id -u)" -ne 0 ]; then
  preflight_line FAIL root "uid=$(id -u)"
  die "code=root" "must run as root (video dir is root-owned)"
fi
preflight_line OK root

resolve_target_user
preflight

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
# Narrowed to the app's curated favourites when that file lists any ids;
# empty/missing favourites, or a favourites set that excludes the whole live
# pool, both fall back to the full pool (never pick from nothing).
if [ -f "$FAVOURITES" ]; then
  FAV_COUNT=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("ids",[])))' "$FAVOURITES" 2>/dev/null || echo 0)
  log "shuffle favourites: ${FAV_COUNT} curated (0 = whole pool)"
else
  log "shuffle favourites: none curated (whole pool)"
fi
PICK=$(python3 - "$ENTRIES" "$CURRENT_ID" "$FAVOURITES" <<'PY'
import json, sys, random
data = json.load(open(sys.argv[1]))
cur = sys.argv[2]
fav_path = sys.argv[3]
pool = [a for a in data.get("assets", [])
        if a.get("url-4K-SDR-240FPS") and a.get("includeInShuffle", True) and a.get("id") != cur]
# Intersect with the curated favourites if the app wrote a non-empty set.
# Empty file, missing file, malformed JSON, or an empty intersection all mean
# "shuffle everything" so the daemon never ends up with an empty pool.
favourites = set()
try:
    with open(fav_path) as f:
        favourites = set(json.load(f).get("ids", []))
except (IOError, OSError, ValueError):
    favourites = set()
if favourites:
    narrowed = [a for a in pool if a.get("id") in favourites]
    if narrowed:
        pool = narrowed
if not pool: sys.exit(0)
a = random.choice(pool)
print("%s\t%s\t%s" % (a["id"], a["url-4K-SDR-240FPS"], a.get("accessibilityLabel", "aerial")))
PY
)
[ -n "$PICK" ] || die "code=catalog.no_candidate" "no candidate aerial found in catalog"
NEW_ID=$(cut -f1 <<<"$PICK"); NEW_URL=$(cut -f2 <<<"$PICK"); NEW_NAME=$(cut -f3 <<<"$PICK")
log "selected: $NEW_NAME ($NEW_ID)"

# ---- download with % banners + verify ---------------------------------------
DEST="$VIDEO_DIR/$NEW_ID.mov"
TMP="$VIDEO_DIR/.$NEW_ID.download"

EXPECTED=$(curl -fsSLI "$NEW_URL" | awk 'tolower($1)=="content-length:"{print $2}' | tr -d '\r')
HEAD_EXIT=${PIPESTATUS[0]:-0}
log "EXEC: curl HEAD exit=$HEAD_EXIT content_length=${EXPECTED:-unknown}"
EXP_MB=$(( ${EXPECTED:-0} / 1024 / 1024 ))
notify "Downloading $NEW_NAME [$NEW_ID]" "0% of ${EXP_MB} MB"
log "DOWNLOAD: start url=$NEW_URL expected_bytes=${EXPECTED:-0}"
log "downloading $NEW_NAME (${EXP_MB} MB)"

DOWNLOAD_RETRIES=0
DOWNLOAD_START_TS=$(date +%s)

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
        notify "Downloading $NEW_NAME [$NEW_ID]" "${milestone}% ($(( cur / 1024 / 1024 )) MB)"
      fi
    fi
    sleep 1
  done
  wait "$pid"; local rc=$?
  log "EXEC: curl body exit=$rc"
  return $rc
}

verify_size() {
  local actual; actual=$(stat -f%z "$TMP" 2>/dev/null || echo 0)
  log "downloaded $actual bytes (server reported ${EXPECTED:-unknown})"
  [ -n "${EXPECTED:-}" ] && [ "$actual" != "$EXPECTED" ] && return 1
  return 0
}

if ! download_with_progress || ! verify_size; then
  DOWNLOAD_RETRIES=1
  log "download/verify failed, retrying once"
  notify "Retrying download" "$NEW_NAME"
  download_with_progress && verify_size || { rm -f "$TMP"; log "DOWNLOAD: end elapsed_s=$(( $(date +%s) - DOWNLOAD_START_TS )) retries=$DOWNLOAD_RETRIES actual_bytes=0 ok=false"; die "code=download.failed" "download failed twice — kept existing aerial"; }
fi
DOWNLOAD_ACTUAL=$(stat -f%z "$TMP" 2>/dev/null || echo 0)
log "DOWNLOAD: end elapsed_s=$(( $(date +%s) - DOWNLOAD_START_TS )) retries=$DOWNLOAD_RETRIES actual_bytes=$DOWNLOAD_ACTUAL ok=true"
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

# The assetID alone does NOT render: the live desktop only repaints when each
# Choice's Provider is 'com.apple.wallpaper.choice.aerials'. The daemon used to
# leave Provider='default' (assetID written, Provider untouched), which is why
# System Settings showed 'Unknown' + a black [?] and the old aerial kept playing.
# Confirmed byte-for-byte against GOLD-index-after-manual-select.txt.
for kp in "${CFG_PATHS[@]}"; do
  pp="${kp%.Configuration}.Provider"
  plutil -replace "$pp" -string "com.apple.wallpaper.choice.aerials" "$STORE" \
    || log "WARN: could not write $pp"
done

# Bump LastSet/LastUse to now so WallpaperAgent treats this as a fresh pick.
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
for lp in "AllSpacesAndDisplays.Linked" "SystemDefault.Linked"; do
  plutil -replace "$lp.LastSet" -date "$NOW_ISO" "$STORE" || log "WARN: could not write $lp.LastSet"
  plutil -replace "$lp.LastUse" -date "$NOW_ISO" "$STORE" || log "WARN: could not write $lp.LastUse"
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
launchctl asuser "$USER_UID" killall WallpaperAgent 2>/dev/null
log "EXEC: killall WallpaperAgent exit=$?"
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
