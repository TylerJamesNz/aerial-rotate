import Foundation

/// Filesystem locations the app reads. These mirror the daemon
/// (`aerial-rotate.sh`) exactly; the app is a read-only face over the same
/// files. All of these are world-readable, so no Full Disk Access or root is
/// needed for reads. The two writes (touching the sentinel for "Refresh now",
/// and rewriting the user agent plist to reschedule) are both user-owned, so
/// neither needs root, see `DaemonScheduler`.
enum Config {
    static let log = "/var/log/aerial-rotate.log"
    static let state = "/var/log/aerial-rotate.state"

    static let assetRoot = "/Library/Application Support/com.apple.idleassetsd/Customer"
    static var videoDir: String { assetRoot + "/4KSDR240FPS" }
    static var entriesJSON: String { assetRoot + "/entries.json" }

    /// Local preview JPEGs idleassetsd caches per asset, keyed by the same id as
    /// the .mov (sibling of Customer/). World-readable, ~50 KB, present for the
    /// whole catalog, so a thumbnail needs no network.
    static let snapshotsDir = "/Library/Application Support/com.apple.idleassetsd/snapshots"
    static func previewImagePath(for id: String) -> String {
        snapshotsDir + "/asset-preview-\(id).jpg"
    }

    static let daemonPlist = "/Library/LaunchDaemons/com.tyler.aerial-rotate.plist"
    static let daemonLabel = "com.tyler.aerial-rotate"
    static let daemonScript = "/usr/local/bin/aerial-rotate.sh"

    /// WatchPaths trigger the root daemon watches. Bumping its mtime (the
    /// "Refresh now" button, or the user agent at the scheduled time) fires a
    /// privileged rotation with no password. User-owned dir, so the app writes
    /// it without sudo. Must match `WatchPaths` in com.tyler.aerial-rotate.plist
    /// and `SENTINEL` in aerial-rotate.sh.
    static let sentinel = "/usr/local/var/aerial-rotate/trigger"

    /// User LaunchAgent that owns the daily schedule. The app rewrites this plist
    /// to reschedule (it's user-owned, so no password); the agent's only job is
    /// to touch the sentinel at the scheduled time. The rotation time is read
    /// from here now, not the root daemon plist.
    static let agentLabel = "com.tyler.aerial-rotate-agent"
    static var userAgentPlist: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/Library/LaunchAgents/com.tyler.aerial-rotate-agent.plist"
    }

    /// User-owned wallpaper store holding the currently pinned asset id.
    static var wallpaperStore: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/Library/Application Support/com.apple.wallpaper/Store/Index.plist"
    }

    /// The shuffle-favourites file the app WRITES and the daemon READS to narrow
    /// its shuffle pool (`{ "ids": [...] }`). The only file the app writes for
    /// the daemon to consume; empty/missing means "shuffle everything". The
    /// daemon resolves the same path off the target user's home (via dscl), so
    /// these two must stay in sync with `aerial-rotate.sh`.
    static var favouritesStore: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/Library/Application Support/aerial-rotate/shuffle-favourites.json"
    }

    /// App-owned cache for aerial thumbnails the OS's idleassetsd never
    /// generated under `snapshotsDir`. `ThumbnailCache` writes PNG bytes
    /// fetched from Apple's CDN here; world-readable, user-owned, lives next
    /// to `favouritesStore`. The dir is created lazily on first write.
    static var thumbnailCacheDir: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/Library/Application Support/aerial-rotate/thumbnails"
    }
    static func cachedThumbnailPath(for id: String) -> String {
        thumbnailCacheDir + "/\(id).png"
    }

    /// Parallel to the daemon's `/var/log/aerial-rotate.log` but app-side and
    /// user-owned, so an operator can `tail -F` thumbnail fetches without
    /// launching Console.app. Truncated when it grows past ~1 MB.
    static var thumbnailLog: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/Library/Application Support/aerial-rotate/thumbnails.log"
    }

    /// Per-line `UPDATE:` log from `Updater`. Same shape as `thumbnailLog`;
    /// `tail -F` here shows the silent pre-fetch happening between cold
    /// launch and the banner appearing.
    static var updateLog: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/Library/Application Support/aerial-rotate/updater.log"
    }

    /// Where the downloaded release .zip + (optional) daemon script land
    /// before install, and where the detached helper script is copied to so
    /// it survives the bundle swap that the helper itself performs.
    static var updateStagingDir: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/Library/Application Support/aerial-rotate/update-staging"
    }
    static var updateHelperScriptPath: String {
        updateStagingDir + "/install-update.sh"
    }
}
