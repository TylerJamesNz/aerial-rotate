# Plan: macos27-aerial-paths

## Context

The daily aerial-wallpaper swapper stopped working after the macOS 27 upgrade. The
menu bar shows `catalog not found: /Library/Application Support/com.apple.idleassetsd/Customer/entries.json`,
and no rotation runs. macOS 27 moved the entire aerial asset model out of the old
shared system folder (owned by root, managed by a helper called `idleassetsd`) into
the logged-in user's own folder, and it is now owned by that user. The app's hardcoded
paths still point at the old location, which no longer exists, so every run aborts at
the catalog preflight.

Confirmed on the live machine (macOS 27.0, build 26A428):

- Old system root is gone. `/Library/Application Support/com.apple.idleassetsd/Customer/entries.json` does not exist; `idleassetsd` has no process, no launchd service, and no plist. One stale 587 MB `.mov` is orphaned in the old `4KSDR240FPS/` dir.
- New per-user layout, all owned by the user (`tylerb staff`), under `~/Library/Application Support/com.apple.wallpaper/aerials/`:
  - Catalog: `manifest/entries.json` (164 assets; 117 shuffle-eligible after the existing `url-4K-SDR-240FPS` + `includeInShuffle` filter, every one named).
  - Videos: `videos/` (flat; no `4KSDR240FPS` sub-dir anymore). Dir is user-writable; current `.mov` is `4207734D-…` at mode 600.
  - Thumbnails: `thumbnails/<ASSET-ID>.png`, one per asset, all 117 pool ids covered locally.
- The prefetcher is now `WallpaperAerialsExtension.appex`, running **as the user**, not the old non-root `_assetsd`.
- The wallpaper store is unchanged. `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist` still answers the probe `AllSpacesAndDisplays.Linked.Content.Choices.0.Configuration`, and Provider is still `com.apple.wallpaper.choice.aerials`. So the pin / unshuffle / provider-check logic in `aerial-rotate.sh` needs no change.

Traced behaviour the migration preserves (`aerial-rotate.sh`): `resolve_target_user()` (`aerial-rotate.sh:106`) resolves the GUI user and sets `STORE`; `preflight()` (`aerial-rotate.sh:140`) checks catalog, video dir, store, schema, provider; the Python picker filters the catalog and the download/pin/prune/relock run after. `STORE` is already resolved per-user off `$USER_HOME`; `ENTRIES`/`VIDEO_DIR` are not, which is the core of the fix.

**Decision — keep the two-job root split (minimal repoint), do not collapse.** Everything is now user-owned, so the root `LaunchDaemon` + `WatchPaths` trigger + user `LaunchAgent` split is no longer *required* (a plain user job could do the whole swap). The operator chose the smallest-diff path: repoint the paths and leave the architecture alone, over a larger rewrite that drops root. See Open questions for the ADR offer capturing why the root split survives.

Skipped `architecture` / `stack` principle-ADR bootstrap: this project has no `docs/adr/` and the migration repoints an existing design rather than establishing a new one; the one genuinely ADR-worthy call (keeping root) is offered below instead.

## Change

| File | Change |
|---|---|
| `aerial-rotate.sh` | Move `ASSET_ROOT`/`ENTRIES`/`VIDEO_DIR` off the static system path into `resolve_target_user()` so they resolve per-user: `ASSET_ROOT="$USER_HOME/Library/Application Support/com.apple.wallpaper/aerials"`, `ENTRIES="$ASSET_ROOT/manifest/entries.json"`, `VIDEO_DIR="$ASSET_ROOT/videos"`. Remove the top-level `ASSET_ROOT`/`ENTRIES`/`VIDEO_DIR` assignments (lines 31-33). |
| `aerial-rotate.sh` | Change the downloaded `.mov` ownership from `chown root:wheel "$DEST"` to `chown "$TARGET_USER:staff" "$DEST"` (matches the OS-written files in the now user-owned `videos/` dir). Keep `chmod 644`. |
| `aerial-rotate.sh` | Update the file-header comment block and the `idleassetsd`/`_assetsd` references (lines 9, 255, 469) to name macOS 27's per-user layout and the `WallpaperAerialsExtension` prefetcher. Comment-only. |
| `install.sh` | Repoint `VIDEO_DIR` (line 13) to the per-user `…/com.apple.wallpaper/aerials/videos`. Add a one-time best-effort cleanup of the orphaned old system dir (`/Library/Application Support/com.apple.idleassetsd/Customer/4KSDR240FPS/*.mov`) — it still has root at install time. |
| `app/Sources/AerialRotateApp/Config.swift` | Make `assetRoot` a computed per-user path (`$HOME/Library/Application Support/com.apple.wallpaper/aerials`), mirroring `wallpaperStore`. `videoDir` → `assetRoot + "/videos"`; `entriesJSON` → `assetRoot + "/manifest/entries.json"`. Repoint `snapshotsDir` → `assetRoot + "/thumbnails"` and `previewImagePath(for:)` → `snapshotsDir + "/\(id).png"` (was `asset-preview-<id>.jpg`). |
| `README.md` | Update the "The problem" path, the layout, and the macOS-version note to macOS 27 per-user. |
| `app/README.md` | Update the `## How it works` "Reads only" bullet (the `com.apple.idleassetsd` reference) to the new per-user catalog/video/thumbnail paths. |

Untouched by design: the pin/unshuffle/provider logic, the `Index.plist` key-path probe, the catalog filter, the two launchd plists, the trigger/refresh plumbing, and the app's CDN thumbnail fallback (kept as a now-rarely-hit tier behind the new local lookup).

## Verify (smoke)

- **Logic gate — manual rotation runs clean.**
  - Fire it: `touch /usr/local/var/aerial-rotate/trigger` (or run the script directly), then `tail /var/log/aerial-rotate.log`.
  - Preflight passes catalog / video_dir / store / schema / provider. No `code=catalog.missing`.
  - A new aerial is picked, downloaded, verified, pinned, and the dir pruned to one `.mov`.
- **Logic gate — the swap actually lands.**
  - The pinned `assetID` in `Index.plist` matches the downloaded `.mov` in `~/…/aerials/videos/`.
  - The desktop repaints to the new aerial.
- **Prefetch-lock observation (the open risk).**
  - After a run, watch `~/…/aerials/videos/` for a few minutes.
  - Check the next run's `APPEARED since last run` line: confirm `WallpaperAerialsExtension` did not slip new `.mov`s past the `chflags uchg` lock now the dir is user-owned (see Open questions).
- **Visual — app catalog grid.**
  - Rebuild (`./app/update.sh`) and open the window.
  - The grid fills thumbnails instantly from the local folder, no network fetch (`~/Library/Application Support/aerial-rotate/thumbnails.log` stays quiet).
  - Current wallpaper + disk usage read correctly.

## Open questions

- **Does the `chflags uchg` lock still block the prefetcher now the videos dir is user-owned?** The user immutable flag can be cleared by the dir's owner, and the macOS 27 prefetcher (`WallpaperAerialsExtension`) runs as that owner. The lock likely still holds in practice (the extension is unlikely to clear flags it did not set), but it is no longer structurally guaranteed the way it was when the dir was root-owned and the prefetcher ran as `_assetsd`. Resolve by observation in smoke step 3; if prefetch leaks, follow-up options are a tighter lock or leaning on the Shuffle-dict removal alone.
- **Offer: ADR `docs/adr/0001-keep-root-split-on-macos27.md`.** Records why the root `LaunchDaemon` + `WatchPaths` split survives macOS 27 even though nothing needs root anymore (minimal-diff / low-regression-risk over collapsing to a single user job). Meets the three-part test: mildly hard to reverse, genuinely surprising to a future reader, a real trade-off that was chosen. Operator to confirm before writing.

## What this feels like

As a user I will see the daily aerial start swapping again and the menu-bar app's catalog grid fill with thumbnails instantly, with nothing about the app's look or controls changing. The whole fix is invisible except that the error banner is gone and rotation resumes.
