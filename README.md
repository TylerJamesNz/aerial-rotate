# aerial-rotate

Keeps the macOS aerial video cache (Sonoma/Sequoia screensaver + dynamic wallpaper) small by holding just one aerial on disk and swapping in a fresh random one each day, instead of letting macOS hoard every aerial you have ever previewed.

On the machine this was built for, the cache had grown to **6.4 GB**. After the first run it was down to a single ~500 MB video.

## The problem

macOS stores 4K aerials (350-750 MB each) under `/Library/Application Support/com.apple.idleassetsd/Customer/4KSDR240FPS/`. On "Shuffle all aerials" it keeps downloading and retaining more, never cleaning up, so the cache silently climbs into the multi-GB range.

## The solution

A privileged `bash` script (`aerial-rotate.sh`) fired once a day. Each run:

1. Picks a random aerial from the catalog (`entries.json`, ~98 eligible), excluding the current one.
2. Downloads just that one `.mov` from Apple's public `sylvan.apple.com` CDN, posting progress banners, and verifies it against the server's `Content-Length`.
3. Pins the wallpaper to the new asset (writes `{"assetID": "<uuid>"}` into the wallpaper store's `Index.plist`, reloads `WallpaperAgent`).
4. Removes the `Shuffle` dict from the wallpaper store (see below) so macOS stops prefetching.
5. Prunes every other `.mov`, **last** and only after the new one is verified and applied, so you are never left with zero.

If the download or verify fails, the script aborts without deleting anything.

### The Shuffle bug (the core fix)

Pinning the `assetID` stops the *displayed* shuffle but not the prefetch. The wallpaper store keeps a `Shuffle` dict at `AllSpacesAndDisplays.Linked.Content.Shuffle` and `SystemDefault.Linked.Content.Shuffle`; while it is present, macOS keeps re-downloading aerials on its own (observed: pruned to one video, macOS pulled two more within five minutes). The fix is to `plutil -remove` that dict from both paths after pinning, then verify it is gone.

### How a run is triggered (two launchd jobs, no password)

Rotation needs root (the asset dir is root-owned) but must fire without a password prompt. Timing is split from privilege across two jobs and one shared trigger file:

```
User LaunchAgent (com.aerialrotate.aerial-rotate-agent)  # holds the daily schedule, touches the trigger
Root LaunchDaemon (com.aerialrotate.aerial-rotate)       # WatchPaths on the trigger -> runs the script as root
```

The agent (and the app's "Refresh now") just `touch /usr/local/var/aerial-rotate/trigger`; the trigger dir is user-owned, so no path needs sudo. The daemon skips unless the trigger's mtime is fresh (within 120s), so load-fires (boot, install, reload) and double-clicks are no-ops.

### Notifications (swiftDialog)

The old notification APIs (`osascript display notification`, `terminal-notifier`) silently no-op on macOS 15, so the script uses [swiftDialog](https://github.com/swiftDialog/swiftDialog), the Mac-admin standard, which registers in Notifications settings and bridges root -> the logged-in GUI session on its own. `install.sh` installs it via its notarized `.pkg`. The first banner may need a one-time **Allow Notifications for Dialog** toggle. Every notification also writes a `NOTIFY:` line to the log, so runs stay traceable even if a banner is missing.

## Menu-bar app

`app/` is a native SwiftUI menu-bar app (`AerialRotate.app`) over the daemon: live rotation progress, current wallpaper with Reveal-in-Finder, disk usage, a countdown, a sun/moon dial for scheduling daily rotation times, and the full aerial catalog flagging anything macOS prefetched. It reads the daemon's log/state (no rewrite) and posts its own banners from the GUI session. See [app/README.md](app/README.md).

## Install

```
sudo ./install.sh
```

Installs the script, daemon, user agent, swiftDialog, and the menu-bar app (a login item in `~/Applications`), loads the daily timer, and runs one rotation immediately.

## Updating

The app polls GitHub Releases at launch and every 6 hours. When a new version is ready it downloads in the background and shows an **Update X.YY ready** banner; click **Install and relaunch**. If the release bumps the daemon script, macOS prompts once for your password.

To install on a fresh Mac from a release instead of source: grab the latest `.zip` from the [Releases page](https://github.com/TylerJamesNz/aerial-rotate/releases/latest), drag `AerialRotate.app` into `~/Applications`, then approve it once under **System Settings -> Privacy & Security** (it is ad-hoc signed). This gets the app only; run `sudo ./install.sh` from a clone to install the daemon.

For hacking on the app locally: `./app/update.sh` rebuilds from source, swaps the bundle, and relaunches, no sudo.

## Layout

```
aerial-rotate.sh                          # the rotation script (-> /usr/local/bin/)
com.aerialrotate.aerial-rotate.plist       # root LaunchDaemon (-> /Library/LaunchDaemons/)
com.aerialrotate.aerial-rotate-agent.plist # user LaunchAgent  (-> ~/Library/LaunchAgents/)
install.sh                                 # one-shot installer (sudo)
app/                                       # SwiftUI menu-bar app (see app/README.md)
```

## Operate

```
tail -f /var/log/aerial-rotate.log                              # watch the log
touch /usr/local/var/aerial-rotate/trigger                      # run a rotation by hand (no sudo)

sudo launchctl print system/com.aerialrotate.aerial-rotate      # inspect the root daemon
launchctl print "gui/$(id -u)/com.aerialrotate.aerial-rotate-agent"  # inspect the user agent

sudo launchctl bootout system /Library/LaunchDaemons/com.aerialrotate.aerial-rotate.plist
launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/com.aerialrotate.aerial-rotate-agent.plist
```

State lives in `/var/log/aerial-rotate.{log,state,prune-counter}`.

## Notes / gotchas

- The video dir is root-owned, so rotation runs as root from a LaunchDaemon; a user LaunchAgent owns the schedule and fires it via the WatchPaths trigger, which keeps the app's Refresh and reschedule password-free. `Index.plist` is user-owned; the script chowns it back after editing.
- Catalog fields used: `id`, `url-4K-SDR-240FPS`, `accessibilityLabel`, `includeInShuffle`.
- Built and tested on macOS 15 (Sequoia), Apple Silicon. `Index.plist` key paths are version-specific; the script aborts with a clear message if Apple changes the schema.
- `PRUNE_EVERY` in the script controls how often the dir is pruned to one video.
