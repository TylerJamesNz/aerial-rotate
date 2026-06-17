import Foundation

/// Reads the currently pinned aerial asset id from the user's wallpaper store.
///
/// Mirrors the daemon's bash:
///   plutil -extract <keyPath>.Configuration raw Index.plist \
///     | base64 --decode | plutil -extract assetID raw -
///
/// The value at `...Configuration` is an embedded binary-plist blob (NSData);
/// decoding it yields a dict with an `assetID` string. Tries the
/// AllSpacesAndDisplays key path first, falls back to SystemDefault, matching
/// the script's CFG_PATHS order.
enum WallpaperStore {
    private static let keyPaths: [[String]] = [
        ["AllSpacesAndDisplays", "Linked", "Content", "Choices"],
        ["SystemDefault", "Linked", "Content", "Choices"],
    ]

    static func currentAssetID() -> String? {
        guard let data = FileManager.default.contents(atPath: Config.wallpaperStore),
              let root = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { return nil }

        for path in keyPaths {
            guard let choices = value(at: path, in: root) as? [Any],
                  let first = choices.first as? [String: Any],
                  let configBlob = first["Configuration"] as? Data
            else { continue }

            if let inner = (try? PropertyListSerialization.propertyList(from: configBlob, format: nil)) as? [String: Any],
               let assetID = inner["assetID"] as? String {
                return assetID
            }
        }
        return nil
    }

    /// True when the wallpaper is set to a rotating/shuffle aerial source, which is
    /// what makes macOS prefetch the whole catalog. Two independent tells in the
    /// store, either is sufficient:
    ///   - `...Content.Shuffle` is a dict (`Type`/`Duration`) vs the string "$null".
    ///   - the choice's `assetID` is a "shuffle-*-aerials" sentinel, not a real UUID.
    /// Defaults to false (don't warn) when the store can't be read.
    static func isRotating() -> Bool {
        guard let data = FileManager.default.contents(atPath: Config.wallpaperStore),
              let root = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { return false }

        let contentPaths: [[String]] = [
            ["AllSpacesAndDisplays", "Linked", "Content"],
            ["SystemDefault", "Linked", "Content"],
        ]
        for path in contentPaths {
            guard let content = value(at: path, in: root) as? [String: Any] else { continue }
            if content["Shuffle"] is [String: Any] { return true }
            if let choices = content["Choices"] as? [Any],
               let first = choices.first as? [String: Any],
               let blob = first["Configuration"] as? Data,
               let inner = (try? PropertyListSerialization.propertyList(from: blob, format: nil)) as? [String: Any],
               let assetID = inner["assetID"] as? String,
               assetID.hasPrefix("shuffle-") { return true }
        }
        return false
    }

    /// Absolute path to a cached aerial's .mov by asset id, if it exists on disk.
    static func movURL(for id: String) -> URL? {
        guard !id.isEmpty else { return nil }
        let url = URL(fileURLWithPath: Config.videoDir).appendingPathComponent("\(id).mov")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Absolute path to the current wallpaper .mov, if it can be resolved and exists on disk.
    static func currentMovURL() -> URL? {
        guard let id = currentAssetID() else { return nil }
        return movURL(for: id)
    }

    private static func value(at path: [String], in root: [String: Any]) -> Any? {
        var node: Any? = root
        for key in path {
            guard let dict = node as? [String: Any] else { return nil }
            node = dict[key]
        }
        return node
    }
}
