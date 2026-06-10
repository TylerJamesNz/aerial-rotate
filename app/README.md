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
jumps to the current `.mov`. Setting a new rotation time pops a single macOS
admin-auth prompt (the one privileged action), then the countdown updates.

## How it works

- **Reads only, no daemon rewrite.** Everything the app shows comes from the
  same world-readable files the daemon writes: `/var/log/aerial-rotate.log`
  (progress + events), `/var/log/aerial-rotate.state` (the OS-prefetch diff),
  the asset dir under `com.apple.idleassetsd` (sizes + catalog), `entries.json`
  (human names), the user wallpaper `Index.plist` (current id), and the daemon
  LaunchDaemon plist (the schedule). No Full Disk Access, no root for reads.
- **Daemon -> app channel is the log.** `LogTailer` watches the log with a
  `DispatchSource` vnode source, parses `NOTIFY:` lines into the progress model,
  and posts banners. The app posting banners is the whole point: it runs in the
  user GUI session where `UNUserNotificationCenter` works, which the root daemon
  can't do (swiftDialog issue #373). This retires the daemon's swiftDialog
  `--mini` window once the app is proven (a later one-line daemon edit).
- **The one write** is rescheduling: `DaemonScheduler` rewrites the daemon
  plist's `StartCalendarInterval` and reloads it via an AppleScript
  `with administrator privileges` prompt. A privileged helper (SMAppService) is
  not viable self-signed under CLT-only, so one auth prompt per change is the
  trade-off.
- **Build is SwiftPM + hand-assembled bundle.** No Xcode is installed (CLT
  only), so `build.sh` runs `swift build`, assembles `AerialRotate.app` around
  the binary with a hand-written `Info.plist`, and ad-hoc codesigns it
  (`--sign -`). UserNotifications needs a stable signed identity, not an
  entitlement; the pinned bundle id `com.tyler.aerial-rotate.app` must stay
  constant or the notifications grant resets.

## See also

- `../aerial-rotate.sh` — the daemon; source of the log/state the app reads.
- `../com.tyler.aerial-rotate.plist` — the schedule the app reads and rewrites.
- `../install.sh` — builds the app as the user and installs it as a login item.
- `build.sh` — `swift build` + bundle assembly + ad-hoc codesign.
