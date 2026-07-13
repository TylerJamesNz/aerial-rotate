# app — AerialRotate menu-bar app

## What it is

A native SwiftUI agent app (`LSUIElement`, no Dock icon) that puts an
interactive face on the `aerial-rotate` daemon. It lives in the menu bar and
opens a window showing live rotation progress, the current wallpaper, disk
usage, a countdown to the next rotation, a sun/moon celestial dial for
scheduling one or more daily rotation times (shown in 12-hour AM/PM), the
full installed-aerial catalog, and a right-hand sidebar to curate which aerials
the daemon shuffles in. It also posts the app's own Notification Center banners,
clicking one opens the window.

## How operators feel it

A menu-bar icon is always there. Click it for a quick status and an Open button;
open the window for the full surface. When a rotation runs, a banner appears and
the window's progress bar tracks the download. The "Reveal in Finder" button
jumps to the current `.mov`. "Refresh wallpaper now" and setting a new rotation
time both act instantly with no password prompt, then the window updates.

## How it works

- **Reads only, no daemon rewrite.** Everything the app shows comes from the
  same world-readable files the daemon writes: `/var/log/aerial-rotate.log`
  (progress + events), `/var/log/aerial-rotate.state` (the OS-prefetch diff),
  the asset dir under `com.apple.idleassetsd` (sizes + catalog), `entries.json`
  (human names), the user wallpaper `Index.plist` (current id), and the user
  LaunchAgent plist (the schedule). No Full Disk Access, no root for reads.
- **One outbound network read: live weather for the dial.** `WeatherStore`
  polls every 20 minutes for approximate location (machine public IP via
  `ipapi.co`, so no CoreLocation prompt) then current conditions (Open-Meteo,
  free, no API key), and publishes a `WeatherSnapshot` onto `AppState.weather`
  that the sun/moon dial draws as clouds/rain/clear. This is the one read that
  leaves the machine; everything else stays on local world-readable files. Any
  failure (offline, rate-limited) silently keeps the last snapshot, and the
  cold/offline default is a plain time-of-day sky with no particles. The app
  isn't sandboxed, so the plain HTTPS calls need no entitlements.
- **Daemon -> app channel is the log.** `LogTailer` watches the log with a
  `DispatchSource` vnode source, parses `NOTIFY:` lines into the progress model,
  and posts banners. The app posting banners is the whole point: it runs in the
  user GUI session where `UNUserNotificationCenter` works, which the root daemon
  can't do (swiftDialog issue #373). This retires the daemon's swiftDialog
  `--mini` window once the app is proven (a later one-line daemon edit).
- **The two writes are both password-free** because they touch only user-owned
  files (`DaemonScheduler`). "Refresh now" bumps the mtime of the WatchPaths
  trigger (`/usr/local/var/aerial-rotate/trigger`); the root daemon watches it
  and does the privileged rotation. Reschedule rewrites the *user* LaunchAgent
  plist's `StartCalendarInterval` and reloads it in the GUI domain
  (`launchctl … gui/$UID`); the agent touches the trigger at the chosen time.
  Splitting timing (user agent) from privilege (root daemon) is what removed the
  old `with administrator privileges` prompt; a privileged helper (SMAppService)
  was never viable self-signed under CLT-only.
- **The shuffle-pool sidebar is the one app-write the daemon then reads.** The
  favourites sidebar lists the whole shuffle-eligible catalog (`ShufflePool`
  mirrors the daemon's `entries.json` filter) as checkbox rows. Ticking a subset
  writes `~/Library/Application Support/aerial-rotate/shuffle-favourites.json`
  (`{ "ids": [...] }`, `FavouritesStore`), and the daemon's Python picker reads
  it and shuffles only from the intersection. **Empty = all:** zero curated
  favourites (the Select-all default, and the never-an-empty-pool floor) leaves
  the daemon shuffling the whole catalog. This crosses the "reads only" stance
  above: the app now also writes a file the daemon consumes, user-owned so still
  password-free, and the daemon resolves the same path off the target user's
  home (via `dscl`) rather than `$HOME` so it works under the root launchd
  context.
- **Build is SwiftPM + hand-assembled bundle.** No Xcode is installed (CLT
  only), so `build.sh` runs `swift build`, assembles `AerialRotate.app` around
  the binary with a hand-written `Info.plist`, and ad-hoc codesigns it
  (`--sign -`). UserNotifications needs a stable signed identity, not an
  entitlement; the pinned bundle id `com.aerialrotate.app` must stay
  constant or the notifications grant resets.

## See also

- `../aerial-rotate.sh` — the daemon; source of the log/state the app reads.
- `../com.aerialrotate.plist` — root daemon, WatchPaths trigger -> rotate.
- `../com.aerialrotate.agent.plist` — user agent; the schedule the app reads and rewrites.
- `../install.sh` — one-time per-Mac install: privileged daemon/agent/swiftDialog, then calls `update.sh` for the app.
- `build.sh` — `swift build` + bundle assembly + ad-hoc codesign.
- `update.sh` — no-sudo app update: build, quit, swap into `~/Applications`, fix the login item, relaunch. The recurring path is `git pull && ./app/update.sh`.
