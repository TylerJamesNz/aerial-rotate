# app — AerialRotate menu-bar app

## What it is

A native SwiftUI agent app (`LSUIElement`, no Dock icon) that puts an
interactive face on the `aerial-rotate` daemon. It lives in the menu bar and
opens a window showing live rotation progress, the current wallpaper, disk
usage, a countdown to the next rotation, a sun/moon clock to set the daily run
time, and the full installed-aerial catalog. It also posts the app's own
Notification Center banners, clicking one opens the window.

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
- **Build is SwiftPM + hand-assembled bundle.** No Xcode is installed (CLT
  only), so `build.sh` runs `swift build`, assembles `AerialRotate.app` around
  the binary with a hand-written `Info.plist`, and ad-hoc codesigns it
  (`--sign -`). UserNotifications needs a stable signed identity, not an
  entitlement; the pinned bundle id `com.tyler.aerial-rotate.app` must stay
  constant or the notifications grant resets.

## See also

- `../aerial-rotate.sh` — the daemon; source of the log/state the app reads.
- `../com.tyler.aerial-rotate.plist` — root daemon, WatchPaths trigger -> rotate.
- `../com.tyler.aerial-rotate-agent.plist` — user agent; the schedule the app reads and rewrites.
- `../install.sh` — one-time per-Mac install: privileged daemon/agent/swiftDialog, then calls `update.sh` for the app.
- `build.sh` — `swift build` + bundle assembly + ad-hoc codesign.
- `update.sh` — no-sudo app update: build, quit, swap into `~/Applications`, fix the login item, relaunch. The recurring path is `git pull && ./app/update.sh`.
