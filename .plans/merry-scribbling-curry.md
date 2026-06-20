# aerial-rotate: self-update from GitHub Releases + public repo

## Context

You want to share the app with your brother and keep shipping updates to him without making him `git pull && ./app/update.sh`. The repo is currently private. Once it goes public, the app polls GitHub Releases on a timer, silently pre-fetches new versions, and surfaces a banner with a single **Install and relaunch** button in the same banner stack where preflight failures and the thumbnail-loading info banner already live. The deploy pipeline is automated: bump `CFBundleShortVersionString`, ship via the rolling PR, and a GitHub Actions workflow tags + builds + uploads the zipped bundle. The daemon (`aerial-rotate.sh`) updates piggy-back on the same release, prompting once for sudo when its bytes change.

**Decisions locked in this grill:**
- **Signing:** ad-hoc (status quo). Brother does the Privacy & Security trip once on first install; self-installed updates are silent.
- **Banner UX:** silent pre-fetch + install button (no Download button, no progress bar).
- **Polling:** once at launch + every 6h while running.
- **Release flow:** `deploy.yml` reads Info.plist, tags + builds + releases on push to main if the tag doesn't exist yet.
- **Scope extras:** README install section, release-notes template, daemon updates piggy-backed, repo public flip + 60-second secrets sweep.

## Recommended approach

### 1. Repo public flip + secrets sweep

Before the first release, scan history for accidental secrets and flip the repo public.

- `git log -p --all | grep -iE '(api[_-]?key|secret|password|token|BEGIN [A-Z]+ KEY)'` then eyeball results.
- Spot-check `.gitignore` covers `.env`, `*.pem`, `*.key`. (Already does, per the existing tree — no `.env` files in repo.)
- `gh repo edit TylerJamesNz/aerial-rotate --visibility public --accept-visibility-change-consequences`
- README update (next section) is a precondition: the public landing surface needs the install instructions before anyone hits it.

### 2. `Updater.swift` (new file)

`app/Sources/AerialRotateApp/Updater.swift`. Single source of truth for "is there an update, what state is it in".

Schema:

```swift
struct AvailableUpdate: Equatable {
    var version: String          // "1.44"
    var tag: String              // "v1.44"
    var appAssetURL: URL         // browser_download_url for the .app.zip
    var daemonAssetURL: URL?     // browser_download_url for aerial-rotate.sh, if shipped this release
    var notes: String            // release body, surfaced in a "What's new" disclosure on the banner
}

enum UpdateState: Equatable {
    case idle
    case checking
    case available(AvailableUpdate)
    case downloading(version: String, loadedBytes: Int64, totalBytes: Int64)
    case ready(version: String, appZipPath: String, daemonPath: String?)
    case failed(reason: String)
}
```

Public surface on `Updater` (an actor):

- `static let shared = Updater()` mirroring `WeatherStore` / `LocationProvider`.
- `func check() async` — hits `GET https://api.github.com/repos/TylerJamesNz/aerial-rotate/releases/latest`, parses, compares vs `Bundle.main.infoDictionary["CFBundleShortVersionString"]`. On newer: transitions through `available` → `downloading` → `ready` automatically (silent pre-fetch, per the locked UX). Publishes state changes to `AppState.shared.updateState` on the main actor.
- `func installAndRelaunch() async` — only valid from `.ready`. Spawns the detached helper (see §4), then `NSApp.terminate(nil)`.

Throttling: a UserDefaults `lastUpdateCheck: Date` (mirrors the `shuffleRememberedFavourites` pattern at `AppState.swift:133-139`). `check()` returns early if `now - lastUpdateCheck < 6h` AND state is `.idle`. The `.ready` state is sticky so an installed-but-not-clicked update stays surfaced.

Version compare: split on `.`, compare components as `Int`. Reject malformed tags (no `v` prefix, non-numeric). Conservative: any unparseable tag is treated as "no update available", logged via `os.Logger`.

Polite to GitHub: unauthenticated API limit is 60/h/IP. 1 check per launch + every 6h = ~5/day, well clear.

Logging: structured `UPDATE:` lines in the spirit of `THUMB:` and `PREFLIGHT:`. Writes to both `os.Logger(subsystem: "com.tyler.aerial-rotate", category: "updater")` and a user-owned tail log at `~/Library/Application Support/aerial-rotate/updater.log`. Reuse the `appendLog` queue pattern from `ThumbnailCache.swift:209-228`.

Lines emitted:

```
UPDATE: check tag=<latest> running=<running> newer=true|false
UPDATE: download.start version=1.44 bytes_expected=<n>
UPDATE: download.end   version=1.44 bytes=<n> elapsed_s=<n> ok=true|false [error=...]
UPDATE: install.start  version=1.44 includes_daemon=true|false
UPDATE: install.end    version=1.44 ok=true|false [error=...]
```

### 3. Banner case 6 in `PreflightBannerStack`

`MainWindow.swift`. Add one new banner case below the existing `ThumbnailsLoadingInfoBanner`:

```swift
if case .ready(let version, _, _) = state.updateState {
    UpdateReadyBanner(version: version)
}
```

`UpdateReadyBanner` reuses `BannerCard` (`MainWindow.swift:629-661`) with:
- tint: `.blue` (consistent with the other info banner)
- icon: `arrow.down.circle.fill`
- title: `"Update \(version) ready"`
- message: `"You're on \(currentVersion). Click to install and relaunch — should take a couple seconds."`
- CTA: new `BannerCTA` case `.installUpdate` whose action calls `Task { await Updater.shared.installAndRelaunch() }`.

The download progress (`UpdateState.downloading`) does NOT surface a banner — silent pre-fetch per the locked UX. If you ever want to see it, the `tail -F ~/Library/Application Support/aerial-rotate/updater.log` line shape gives the same observability the thumbnail loader already provides.

### 4. Detached install helper

An app can't atomically replace its own running bundle, so we hand off to a tiny shell script that waits for the parent to exit, swaps the bundle, and relaunches.

Bundle a script at `app/Sources/AerialRotateApp/Resources/install-update.sh`:

```bash
#!/bin/bash
# args: <zip-path> <target-bundle-path> <parent-pid> [<daemon-script-path>]
set -e
ZIP="$1"; TARGET="$2"; PARENT="$3"; DAEMON="${4:-}"

while kill -0 "$PARENT" 2>/dev/null; do sleep 0.1; done

TMP=$(mktemp -d)
unzip -q "$ZIP" -d "$TMP"

# Strip quarantine on the staged bundle so a future macOS that adds the xattr
# to URLSession downloads still launches clean.
xattr -dr com.apple.quarantine "$TMP/AerialRotate.app" 2>/dev/null || true

rm -rf "$TARGET"
mv "$TMP/AerialRotate.app" "$TARGET"

# Daemon update is optional and skipped here — it needs sudo. The parent app
# already prompted with osascript before quitting if a daemon update was queued.

open "$TARGET"
rm -f "$ZIP"
rmdir "$TMP" 2>/dev/null || true
```

`build.sh` copies this into the bundle's `Resources/` (already does for `Info.plist`; one more `install` call). The Swift side resolves it at runtime via `Bundle.main.url(forResource: "install-update", withExtension: "sh")`, copies it to `~/Library/Application Support/aerial-rotate/install-update.sh` (so it survives the bundle swap), `chmod +x`, then `Process.launch` it with `terminationHandler = nil` and `qualityOfService = .background` so the parent can exit cleanly without orphaning it.

Daemon piece: if `AvailableUpdate.daemonAssetURL != nil` AND the downloaded daemon bytes differ from `/usr/local/bin/aerial-rotate.sh`, the install path runs an osascript prompt BEFORE calling NSApp.terminate:

```swift
let script = """
do shell script "cp '\(daemonPath)' /usr/local/bin/aerial-rotate.sh && chmod 755 /usr/local/bin/aerial-rotate.sh" with administrator privileges
"""
```

If user cancels the auth dialog, log it and proceed with app-only update — daemon stays on the old script, picked up on next manual `sudo cp` or next ship. The banner copy in this case carries an extra line: `"This update includes a daemon change. You'll be asked for your password during install."` so the prompt isn't a surprise.

### 5. `deploy.yml` workflow

`.github/workflows/deploy.yml`. Triggers on `push: branches: [main]`.

Steps:

1. Checkout with `fetch-depth: 0` and `fetch-tags: true`.
2. Read `CFBundleShortVersionString` from `app/Sources/AerialRotateApp/Resources/Info.plist` via `plutil -extract`.
3. Check if `v$VERSION` tag exists. If yes, exit clean (no-op release — main push wasn't a version bump).
4. Run `cd app && ./build.sh` on `macos-latest`. The runner has Xcode/Swift; ad-hoc codesign just works.
5. Zip the bundle: `cd app && zip -ry AerialRotate-v$VERSION.zip AerialRotate.app`.
6. Generate release notes from the most recent merge commit body + a stable footer (the release-notes template, §6).
7. `gh release create v$VERSION app/AerialRotate-v$VERSION.zip aerial-rotate.sh --title "v$VERSION" --notes-file /tmp/notes.md`. The daemon script ships as a separate asset, distinguishable by suffix.
8. Git tag is created implicitly by `gh release create`.

Permissions: `permissions: contents: write` for the workflow's `GITHUB_TOKEN` so `gh release create` can write tags + releases.

Concurrency: `concurrency: { group: deploy, cancel-in-progress: false }` so two near-simultaneous main pushes don't race.

### 6. Release notes template

`.github/release-template.md`. The deploy.yml workflow concatenates the merge-commit body + this footer:

```markdown
---

## Installing v{VERSION} on a new Mac

1. Download **AerialRotate-v{VERSION}.zip** below. Safari auto-unzips.
2. Drag **AerialRotate.app** into `~/Applications`.
3. Double-click. macOS will block it the first time only.
4. Open **System Settings → Privacy & Security**, scroll to the Security section, click **Open Anyway** next to "AerialRotate".
5. Re-launch. Click **Open** on the final confirmation.

After this trip, every update installs silently from the in-app banner.

Full install instructions: https://github.com/TylerJamesNz/aerial-rotate#installing-on-a-new-mac
```

`{VERSION}` substituted by the workflow.

### 7. README install section

`README.md`. Add at the top, before everything else:

```markdown
# aerial-rotate

[one-line description: rotates Apple's aerial wallpapers on a schedule, menu-bar app + LaunchDaemon]

## Installing on a new Mac

1. Grab the latest **AerialRotate.app.zip** from the [Releases page](https://github.com/TylerJamesNz/aerial-rotate/releases/latest).
2. Drag **AerialRotate.app** into your Applications folder.
3. Double-click to launch. macOS will block it once because the app is ad-hoc signed.
4. Open **System Settings → Privacy & Security → Security** and click **Open Anyway** next to "AerialRotate". You may need to enter your login password.
5. Re-launch the app. Click **Open** on the confirmation dialog.

That's the one-time dance. Every future update installs silently from the in-app banner.

[Optional screenshot of the Privacy & Security panel — placeholder for now]

## Updating

After install, the app polls GitHub Releases once at launch and every 6 hours. When a new version is available it downloads in the background and surfaces a banner reading "Update X.YY ready". Click **Install and relaunch** to swap in the new bundle.
```

The rest of the README (existing dev / install.sh / daemon stuff) follows.

## Files to modify or create

- `app/Sources/AerialRotateApp/Updater.swift` (new) — main module, ~250 LOC modelled on `ThumbnailCache.swift` (actor-isolated state, structured logging, atomic disk writes).
- `app/Sources/AerialRotateApp/AppState.swift` — add `@Published var updateState: UpdateState = .idle`; in `refresh()` after the thumbnail batch kick-off, call `Task { await Updater.shared.check() }` (which internally throttles via the 6h gate).
- `app/Sources/AerialRotateApp/Config.swift` — add `updateLog`, `updateStagingDir`, `updateHelperScriptPath`, `daemonInstallPath` (the last so the daemon-diff check has one place to look).
- `app/Sources/AerialRotateApp/Views/MainWindow.swift` — add `UpdateReadyBanner` (new private struct) and a sixth case in `PreflightBannerStack.body`. Add `BannerCTA.installUpdate` to the existing enum so the button hooks through the same `BannerCard` plumbing.
- `app/Sources/AerialRotateApp/Resources/install-update.sh` (new) — the detached helper script described in §4.
- `app/build.sh` — one extra `install -m 755 install-update.sh Resources/install-update.sh` (or however build.sh already handles Resources copying).
- `.github/workflows/deploy.yml` (new) — the release workflow described in §5.
- `.github/release-template.md` (new) — the footer template described in §6.
- `README.md` — prepend the install section described in §7.

No changes to `aerial-rotate.sh` (the daemon script). Its updates ride the same release; the app downloads and prompts.

## Reused patterns

- **Actor + structured logging + tail file**: `ThumbnailCache.swift` is the reference. `Updater` follows the same shape (private actor for state, dual `os.Logger` + tail-log writer, `appendLog` queue, atomic temp+rename writes).
- **UserDefaults persistence**: `AppState.swift:133-139` for the `lastUpdateCheck: Date` key.
- **URLSession**: `URLSession.shared` for the API call, `URLSession(configuration: .ephemeral)` for the asset download (so cookies / cache don't pollute), mirroring `WeatherStore.swift:55`.
- **Banner card**: `BannerCard` at `MainWindow.swift:629-661`. New `UpdateReadyBanner` is a thin wrapper.
- **System Settings deep-link**: `MainWindow.swift:680-685` shows the `x-apple.systempreferences:` pattern; not needed for first install (app isn't running) but available if a future update is ever Gatekeeper-blocked.
- **`refresh()` piggy-back**: the same hook the thumbnail loader uses at `AppState.swift:171` (`refreshMissingThumbnails(pool:)`) is where the updater's `check()` slots in.

## Verification

End-to-end, in order:

1. **Secrets sweep, public flip.** `git log -p --all | grep -iE '(api[_-]?key|secret|password|token|BEGIN [A-Z]+ KEY)' | less`; confirm clean. `gh repo edit --visibility public --accept-visibility-change-consequences`.

2. **Cut v1.44 release end-to-end.**
   - Bump Info.plist: `CFBundleShortVersionString` 1.43 → 1.44, `CFBundleVersion` 45 → 46.
   - Commit on a feature branch, ship through the rolling PR.
   - On main push, watch `gh run watch` for the deploy.yml run. Confirm: tag `v1.44` is created, release `v1.44` exists with `AerialRotate-v1.44.zip` and `aerial-rotate.sh` as assets, release notes include the merge commit body + the install footer.

3. **Self-update smoke (your Mac, still on 1.43).**
   - `tail -F ~/Library/Application Support/aerial-rotate/updater.log` in another terminal.
   - Launch the running 1.43 app (it's already installed at `~/Applications/AerialRotate.app`).
   - Within seconds: `UPDATE: check tag=v1.44 running=1.43 newer=true`, then `download.start`, then `download.end ok=true`, then state transitions to `.ready` and the blue banner appears.
   - Click **Install and relaunch**. App quits, helper script swaps the bundle, app relaunches as 1.44. Menu-bar dropdown shows "v1.44 (46)".

4. **Daemon-update smoke.** Ship a v1.45 that only changes `aerial-rotate.sh` (no app code). Expected: 1.44 sees v1.45 available, downloads both assets, on Install click an osascript admin prompt fires for sudo, daemon script overwritten, app relaunches at 1.45. `tail -F /var/log/aerial-rotate.log` shows the daemon's next preflight using the new script.

5. **Throttle smoke.** Within 6 hours of a successful check, force-launch the app. `UPDATE:` log shows no fresh API hit — the lastUpdateCheck gate held.

6. **First-install smoke (brother's Mac, or a fresh VM).** Open the public Releases page in Safari, download the zip, drag to ~/Applications, double-click, do the Privacy & Security trip per the README. App launches.

7. **Offline check.** Wi-Fi off, launch. `UPDATE: check ... error=...` logged, banner doesn't appear, app behaves normally otherwise.

## Open threads / Resume target

**Resume target:** Implement the updater per the approved plan, starting with the secrets sweep + repo public flip (gates everything downstream).

### Implement the self-updater per the approved plan
**Status:** next
**Problem:** Brother needs the app + an update channel; currently no public surface and no auto-update.
**Current state:** Plan approved, persisted at `/Users/tylerjames/.claude/plans/merry-scribbling-curry.md`. Implementation hasn't started. Branch base: `dev` (last ship landed v1.43's underlying commits at `main`).
**Pending:** Build per §§1-7, then run the six verification smokes. Operator decides commit shape (one omnibus or split per file).
