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
}
