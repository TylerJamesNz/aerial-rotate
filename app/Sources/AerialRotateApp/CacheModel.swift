import Foundation

/// One aerial .mov currently on disk in the cache.
struct AerialItem: Identifiable, Hashable {
    let id: String          // asset UUID (the .mov basename)
    let name: String        // human label from entries.json, or the id if unknown
    let sizeBytes: Int64
    let isCurrent: Bool
    /// On disk but absent from the daemon's last end-of-run snapshot, i.e. macOS
    /// prefetched it behind the daemon's back (the script's `comm -23` diagnostic).
    let appearedWithoutDaemon: Bool
}

/// Immutable snapshot of the cache, computed off the main thread.
struct CacheSnapshot {
    let totalBytes: Int64
    let currentID: String?
    let currentBytes: Int64
    let items: [AerialItem]

    static let empty = CacheSnapshot(totalBytes: 0, currentID: nil, currentBytes: 0, items: [])
}

/// Reads cache state from the same world-readable files the daemon writes:
/// the asset dir (sizes), entries.json (names), and aerial-rotate.state (the
/// auto-install diff). All reads, no writes.
enum CacheModel {

    /// Build a full snapshot. Safe to call off the main actor (pure file reads).
    static func snapshot(currentID: String?) -> CacheSnapshot {
        let names = loadNames()
        let priorIDs = stateIDs()
        let fm = FileManager.default

        var items: [AerialItem] = []
        var total: Int64 = 0
        var currentBytes: Int64 = 0

        let dir = URL(fileURLWithPath: Config.videoDir)
        let contents = (try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: [.skipsHiddenFiles])) ?? []

        for url in contents where url.pathExtension == "mov" {
            let id = url.deletingPathExtension().lastPathComponent
            let size = allocatedSize(of: url)
            total += size
            let isCurrent = (id == currentID)
            if isCurrent { currentBytes = size }
            items.append(AerialItem(
                id: id,
                name: names[id] ?? id,
                sizeBytes: size,
                isCurrent: isCurrent,
                appearedWithoutDaemon: !priorIDs.isEmpty && !priorIDs.contains(id)
            ))
        }

        // Current first, then flagged auto-installs, then by name.
        items.sort {
            if $0.isCurrent != $1.isCurrent { return $0.isCurrent }
            if $0.appearedWithoutDaemon != $1.appearedWithoutDaemon { return $0.appearedWithoutDaemon }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        return CacheSnapshot(totalBytes: total, currentID: currentID, currentBytes: currentBytes, items: items)
    }

    /// `(hour, minute)` the rotation is scheduled for, read from the user
    /// LaunchAgent plist (the agent owns the schedule and touches the trigger;
    /// the root daemon just watches the trigger, so it no longer holds the time).
    static func rotationTime() -> (hour: Int, minute: Int)? {
        guard let data = FileManager.default.contents(atPath: Config.userAgentPlist),
              let root = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let interval = root["StartCalendarInterval"] as? [String: Any]
        else { return nil }
        let hour = (interval["Hour"] as? Int) ?? 0
        let minute = (interval["Minute"] as? Int) ?? 0
        return (hour, minute)
    }

    // MARK: - helpers

    private static func allocatedSize(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let vals = try? url.resourceValues(forKeys: keys) else { return 0 }
        return Int64(vals.totalFileAllocatedSize ?? vals.fileAllocatedSize ?? 0)
    }

    /// `accessibilityLabel` keyed by asset `id` from entries.json.
    private static func loadNames() -> [String: String] {
        guard let data = FileManager.default.contents(atPath: Config.entriesJSON),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = obj["assets"] as? [[String: Any]]
        else { return [:] }
        var map: [String: String] = [:]
        for a in assets {
            if let id = a["id"] as? String {
                map[id] = (a["accessibilityLabel"] as? String) ?? id
            }
        }
        return map
    }

    /// Asset ids in the daemon's last end-of-run snapshot (first column of the
    /// `<id> <mtime>` state file). Empty set means "no baseline yet", in which
    /// case nothing is flagged as auto-installed.
    private static func stateIDs() -> Set<String> {
        guard let text = try? String(contentsOfFile: Config.state, encoding: .utf8) else { return [] }
        var ids = Set<String>()
        for line in text.split(separator: "\n") {
            if let first = line.split(separator: " ").first {
                ids.insert(String(first))
            }
        }
        return ids
    }
}
