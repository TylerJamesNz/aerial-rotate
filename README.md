# aerial-rotate

Keeps the macOS aerial (Sonoma/Sequoia screensaver + dynamic wallpaper) video cache small by holding just one or two aerials on disk and swapping in a fresh random one each day, instead of letting macOS hoard every aerial you have ever previewed.

On the machine this was built for, the aerial cache had grown to **6.4 GB**. After the first run it was down to a single ~500 MB video.

## The problem

macOS stores aerial videos under:

```
/Library/Application Support/com.apple.idleassetsd/Customer/4KSDR240FPS/
```

Each 4K aerial is 350-750 MB. If you leave the wallpaper on "Shuffle all aerials", macOS keeps downloading and retaining more of them, and never cleans up. The cache silently climbs into the multiple-GB range.

## The solution

A `bash` script that does the privileged rotation, fired once a day. Each run:

1. **Snapshots the video dir** and logs which `.mov`s appeared since the last run (diagnostic: shows whether macOS prefetched any aerials on its own).
2. **Picks a random aerial** from the catalog (`entries.json`, ~98 eligible after filtering), excluding the current one.
3. **Downloads just that one `.mov`** from Apple's public `sylvan.apple.com` CDN (no auth), posting progress **banner notifications** at 0/20/40/60/80%, and verifies the byte count against the server's `Content-Length`.
4. **Pins the wallpaper** to the new asset by writing a tiny `{"assetID": "<uuid>"}` binary plist into the wallpaper store (`Index.plist`), then reloads `WallpaperAgent`.
5. **Removes the `Shuffle` dict** from the wallpaper store (see "The Shuffle bug" below) so macOS stops cycling and prefetching new aerials behind your back.
6. **Prunes every other `.mov`** so you are left with one aerial on disk. Pruning happens **last**, only after the new video is downloaded, verified, and applied, so you are never left with zero. (During the confirmation phase this is gated to every other run via a small counter, so accumulation stays observable.)

If the download or verify fails, the script **aborts without deleting** the existing video.

### How a run is triggered (two launchd jobs, no password)

The rotation needs root (the asset dir is root-owned), but the app must trigger it without prompting for a password every time. Timing is split from privilege across two launchd jobs and one shared trigger file:

```
User LaunchAgent (com.tyler.aerial-rotate-agent)   # user-owned, holds the daily schedule
    | /usr/bin/touch /usr/local/var/aerial-rotate/trigger   (no sudo)
    v
Root LaunchDaemon (com.tyler.aerial-rotate)        # WatchPaths on the trigger -> runs the script as root
    ^
    | touch trigger (app "Refresh now") / rewrite agent plist (app reschedule)
   AerialRotate.app                                 # user GUI session, no password
```

- The **root daemon** no longer carries a schedule. It has a `WatchPaths` on `/usr/local/var/aerial-rotate/trigger`; any change to that file's mtime starts the privileged rotation.
- The **user agent** owns the daily time (`StartCalendarInterval`). When it fires it does one thing: `touch` the trigger. Because the agent plist is user-owned, the app reschedules by rewriting it, no password.
- The **app's "Refresh now"** just touches the trigger directly. The trigger dir is user-owned (created by `install.sh`), so neither path needs root.

`WatchPaths` starts a job once at *load* too (boot, install, daemon reload), not only on later changes. So the script skips unless the trigger was freshly touched (mtime within 120s); a stale mtime means a load-fire and the run is a no-op. This also debounces a double-click of Refresh. The script never writes the trigger, so the watch can't feed back on itself.

### The Shuffle bug (the core fix)

Pinning the `assetID` stops the *displayed* shuffle, but it does **not** stop macOS from prefetching. The wallpaper store keeps a `Shuffle` dict:

```
...Linked.Content.Shuffle = { Type => afterDuration, Duration => [...] }
```

at both `AllSpacesAndDisplays.Linked.Content.Shuffle` and `SystemDefault.Linked.Content.Shuffle`. As long as that dict is present, macOS keeps cycling and **re-downloading** new aerials on its own. We observed the dir prune down to one video and then macOS pull two more within five minutes, with no job of ours running.

The fix is to `plutil -remove` the `Shuffle` dict from both paths after pinning, then verify it is gone. That is what actually stops the prefetch.

## swiftDialog (notifications)

The script posts banner notifications as it works. Both obvious approaches are **dead on macOS 15**: `osascript -e 'display notification ...'` and `terminal-notifier` (last released 2017) use Apple's old `NSUserNotification` API, which on macOS 15 silently no-ops. It never displays a banner and never registers in **System Settings > Notifications**, so there is nothing to permission-grant. osascript additionally posts under a non-permitted host-app identity, which gets dropped.

So the notification path uses [**swiftDialog**](https://github.com/swiftDialog/swiftDialog) instead, the Mac-admin community standard for notifications from scripts and daemons. It is notarized/signed, **requires macOS 15+** (built for Sequoia), and registers correctly in Notifications settings so it can be permission-granted. Its `/usr/local/bin/dialog` launcher detects root context and bridges into the logged-in user's GUI session via `launchctl asuser` on its own, so the daemon (which runs as root) can call it directly:

```
/usr/local/bin/dialog --notification --title "🌄 Aerial" --subtitle "<event>" --message "<detail>"
```

`notify()` always writes a `NOTIFY:` line to the log first, then fires the banner if `dialog` is present, so a run is always traceable in the log even if the banner is missing.

`install.sh` installs swiftDialog for you via its official notarized `.pkg` (no Homebrew dependency). The first banner may require a one-time **Allow Notifications for Dialog** toggle in **System Settings > Notifications**; "Dialog" will be in the list once it has fired once.

## Layout

```
aerial-rotate.sh                     # the rotation script (installed to /usr/local/bin/)
com.tyler.aerial-rotate.plist        # root LaunchDaemon: WatchPaths trigger -> rotate (installed to /Library/LaunchDaemons/)
com.tyler.aerial-rotate-agent.plist  # user LaunchAgent: daily schedule -> touch trigger (installed to ~/Library/LaunchAgents/)
install.sh                           # one-shot installer (sudo)
app/                                 # SwiftUI menu-bar status app (see app/README.md)
```

## Menu-bar app

`app/` is a native SwiftUI menu-bar app (`AerialRotate.app`) that puts an interactive face on the daemon: live rotation progress, the current wallpaper with Reveal-in-Finder, disk usage, a countdown to the next rotation, a sun/moon clock to set the daily time, and the full installed-aerial catalog flagging anything macOS prefetched. It reads the daemon's own log/state (no daemon rewrite) and posts its own Notification Center banners from the user GUI session, where the root daemon can't. `install.sh` builds and installs it as a login item. See [app/README.md](app/README.md).

## Install

```
sudo ./install.sh
```

This installs the script and daemon, ensures swiftDialog is present, loads the daily timer, and runs one rotation immediately so you can watch the banners.

## Operate

```
# watch the log
tail -f /var/log/aerial-rotate.log

# run a rotation by hand (no sudo: fires the daemon via the WatchPaths trigger)
touch /usr/local/var/aerial-rotate/trigger

# see the two jobs
sudo launchctl print system/com.tyler.aerial-rotate          # root daemon (watches the trigger)
launchctl print "gui/$(id -u)/com.tyler.aerial-rotate-agent" # user agent (daily schedule)

# stop / remove the daemon + agent
sudo launchctl bootout system /Library/LaunchDaemons/com.tyler.aerial-rotate.plist
launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/com.tyler.aerial-rotate-agent.plist
```

State files:

```
/var/log/aerial-rotate.log            # run log
/var/log/aerial-rotate.state          # last run's dir snapshot (drives the prefetch diagnostic)
/var/log/aerial-rotate.prune-counter  # runs since last prune
```

## Notes / gotchas

- The video dir is `root`-owned, so the rotation itself runs as root from a **LaunchDaemon**. A user **LaunchAgent** owns the schedule and fires the daemon by touching a WatchPaths trigger (see "How a run is triggered"), which is what keeps the app's Refresh and reschedule buttons password-free. `Index.plist` is user-owned; the script chowns it back to the user after editing.
- Catalog asset fields used: `id`, `url-4K-SDR-240FPS`, `accessibilityLabel` (human name), `includeInShuffle`.
- Built and tested on macOS 15 (Sequoia), Apple Silicon. The `Index.plist` key paths are macOS-version-specific; the script aborts with a clear message if Apple changes the schema.
- `PRUNE_EVERY` in the script controls how often the dir is pruned to one video. Set it to `1` once you have confirmed the Shuffle-kill stops the prefetch.
