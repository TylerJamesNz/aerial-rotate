import Foundation

/// One aerial eligible for the daemon's shuffle pool: present in entries.json
/// with a 4K URL and not excluded from shuffle. This is the WHOLE catalog
/// superset (~98), not just the .mov's currently installed on disk.
struct ShuffleAsset: Identifiable, Hashable {
    let id: String          // asset UUID
    let name: String        // human label from entries.json, or the id if unknown
}

/// Loads the full shuffle-eligible catalog from entries.json, mirroring the
/// daemon's pool filter in `aerial-rotate.sh` (`url-4K-SDR-240FPS` present and
/// `includeInShuffle != false`) so the app and the daemon agree on the universe
/// of shufflable aerials. Pure file read, safe off the main actor.
enum ShufflePool {
    static func load() -> [ShuffleAsset] {
        guard let data = FileManager.default.contents(atPath: Config.entriesJSON),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = obj["assets"] as? [[String: Any]]
        else { return [] }

        var pool: [ShuffleAsset] = []
        for a in assets {
            guard let id = a["id"] as? String,
                  a["url-4K-SDR-240FPS"] != nil,
                  (a["includeInShuffle"] as? Bool) ?? true
            else { continue }
            pool.append(ShuffleAsset(id: id, name: (a["accessibilityLabel"] as? String) ?? id))
        }
        pool.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return pool
    }
}
