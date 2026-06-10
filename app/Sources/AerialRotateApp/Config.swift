import Foundation

/// Filesystem locations the app reads. These mirror the daemon
/// (`aerial-rotate.sh`) exactly; the app is a read-only face over the same
/// files. All of these are world-readable, so no Full Disk Access or root is
/// needed for reads. The one write (rescheduling the daemon plist) goes through
/// `DaemonScheduler` with an admin-auth prompt.
enum Config {
    static let log = "/var/log/aerial-rotate.log"
    static let state = "/var/log/aerial-rotate.state"

    static let assetRoot = "/Library/Application Support/com.apple.idleassetsd/Customer"
    static var videoDir: String { assetRoot + "/4KSDR240FPS" }
    static var entriesJSON: String { assetRoot + "/entries.json" }

    static let daemonPlist = "/Library/LaunchDaemons/com.tyler.aerial-rotate.plist"
    static let daemonLabel = "com.tyler.aerial-rotate"

    /// User-owned wallpaper store holding the currently pinned asset id.
    static var wallpaperStore: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/Library/Application Support/com.apple.wallpaper/Store/Index.plist"
    }
}
