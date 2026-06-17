import Foundation

/// Reads and writes the shuffle-favourites file the daemon consumes:
/// `~/Library/Application Support/aerial-rotate/shuffle-favourites.json`,
/// shape `{ "ids": ["<uuid>", ...] }`. This is the app's first WRITE to a file
/// the daemon then reads (everything else the app touches it only reads); the
/// daemon's Python picker intersects its pool with these ids. An empty array or
/// a missing file means "no curation" -> shuffle the whole pool.
enum FavouritesStore {

    /// The curated favourite ids, or an empty set if nothing is curated yet
    /// (missing file, empty array, or unreadable). Empty is the "all" sentinel.
    static func load() -> Set<String> {
        guard let data = FileManager.default.contents(atPath: Config.favouritesStore),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ids = obj["ids"] as? [String]
        else { return [] }
        return Set(ids)
    }

    /// Persist the curated set atomically, creating the dir on first write. The
    /// daemon runs as root so it can always read this, but the dir is created
    /// world-traversable so a non-root reader could reach it too.
    static func save(_ ids: Set<String>) {
        let path = Config.favouritesStore
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let obj = ["ids": ids.sorted()]
        guard let data = try? JSONSerialization.data(withJSONObject: obj,
                                                     options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
