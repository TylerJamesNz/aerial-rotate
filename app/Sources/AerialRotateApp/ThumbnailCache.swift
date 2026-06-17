import Foundation
import AppKit
import os

/// Unified-logging channel for thumbnail-cache events. Visible via Console.app
/// (filter on subsystem `com.tyler.aerial-rotate`, category `thumbnails`) and
/// the CLI: `log stream --predicate 'subsystem == "com.tyler.aerial-rotate"' --info --debug`.
private let thumbnailLogger = Logger(subsystem: "com.tyler.aerial-rotate", category: "thumbnails")

/// Three-tier resolver for aerial thumbnails: in-memory → idleassetsd's
/// preview JPEGs → app-owned disk cache → Apple's CDN. The local-only tiers
/// (1-3) are silent, the CDN tier (4) emits structured `THUMB:` lines to both
/// macOS unified logging and a user-owned tail log at `Config.thumbnailLog`,
/// because the operator needs to SEE network work happen in an app they have a
/// window open on (mirrors how the daemon's `/var/log/aerial-rotate.log`
/// surfaces rotation work).
///
/// macOS's `idleassetsd` populates the snapshots dir for ~98 of the 137
/// catalog assets, so ~30 shuffle-eligible rows have no local preview. Without
/// tier 4 they render as the grey-photo placeholder; with it they fill in
/// shortly after the rich window opens.
enum ThumbnailCache {
    /// Actor-isolated state so concurrent callers (per-row `.task` + the batch
    /// loader driven from `AppState.refresh()`) can share one network
    /// round-trip per id.
    private actor State {
        var mem: [String: NSImage] = [:]
        var inflight: [String: Task<NSImage?, Never>] = [:]
        var previewMeta: [String: (url: URL, name: String)] = [:]
        var metaLoaded = false

        func memHit(for id: String) -> NSImage? { mem[id] }
        func storeMem(_ id: String, _ image: NSImage) { mem[id] = image }
        func memKeys() -> Set<String> { Set(mem.keys) }

        /// Lazy entries.json parse. Mirrors `ShufflePool`'s reader (same path
        /// via `Config.entriesJSON`, same `accessibilityLabel`/`shotID`
        /// fallback for the name). Idempotent across all callers — the bool
        /// guard runs inside actor isolation, so two parallel fetches can't
        /// both load.
        func loadMetaIfNeeded() {
            guard !metaLoaded else { return }
            metaLoaded = true
            guard let data = FileManager.default.contents(atPath: Config.entriesJSON),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let assets = obj["assets"] as? [[String: Any]] else { return }
            for a in assets {
                guard let id = a["id"] as? String,
                      let urlStr = a["previewImage"] as? String,
                      let url = URL(string: urlStr) else { continue }
                let label = (a["accessibilityLabel"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let name = !label.isEmpty
                    ? label
                    : (a["shotID"] as? String) ?? String(id.prefix(8))
                previewMeta[id] = (url, name)
            }
        }

        func meta(for id: String) -> (url: URL, name: String)? { previewMeta[id] }

        /// Return the existing in-flight task for `id` if one is running, else
        /// run `make` to start a new one and register it. The lookup-or-start
        /// is atomic under actor isolation, so two callers for the same id
        /// converge on the same Task.
        func taskFor(id: String, _ make: () -> Task<NSImage?, Never>) -> Task<NSImage?, Never> {
            if let existing = inflight[id] { return existing }
            let t = make()
            inflight[id] = t
            return t
        }

        func clearInflight(_ id: String) { inflight[id] = nil }
    }

    private static let state = State()

    /// Three-tier resolver. Returns nil only when all four tiers fail
    /// (offline, missing `previewImage` URL, non-image response). The call
    /// site (`AerialThumbnail.task`) draws the grey placeholder on nil, so
    /// the failure mode is the same as today's "no idleassetsd snapshot".
    static func image(for id: String) async -> NSImage? {
        if let hit = await state.memHit(for: id) { return hit }
        if let img = readLocal(path: Config.previewImagePath(for: id)) {
            await state.storeMem(id, img)
            return img
        }
        if let img = readLocal(path: Config.cachedThumbnailPath(for: id)) {
            await state.storeMem(id, img)
            return img
        }
        return await fetchFromCDN(id: id)
    }

    /// Pool-vs-cache diff used by `AppState.refresh()` to drive the batch
    /// loader and the "thumbnails still arriving" banner. Cheap synchronous
    /// existence checks (~98 ids on a typical catalog), so safe to call from
    /// the refresh's `Task.detached`.
    static func missingIDs(in poolIDs: [String]) async -> [String] {
        let memKeys = await state.memKeys()
        return poolIDs.filter { id in
            if memKeys.contains(id) { return false }
            if FileManager.default.fileExists(atPath: Config.previewImagePath(for: id)) { return false }
            if FileManager.default.fileExists(atPath: Config.cachedThumbnailPath(for: id)) { return false }
            return true
        }
    }

    /// Surfaces the start of a refresh-driven batch into both log channels so
    /// `tail -F ~/Library/Application\ Support/aerial-rotate/thumbnails.log`
    /// shows what the banner is doing.
    static func logBatchStart(missing: Int, total: Int) {
        appendLog("THUMB: batch.start missing=\(missing) total=\(total)")
        thumbnailLogger.info("batch.start missing=\(missing, privacy: .public) total=\(total, privacy: .public)")
    }

    static func logBatchEnd(loaded: Int, failed: Int, elapsedSec: Double) {
        let secs = String(format: "%.1f", elapsedSec)
        appendLog("THUMB: batch.end   loaded=\(loaded) failed=\(failed) elapsed_s=\(secs)")
        thumbnailLogger.info("batch.end loaded=\(loaded, privacy: .public) failed=\(failed, privacy: .public) elapsed_s=\(secs, privacy: .public)")
    }

    // MARK: - CDN fetch

    private static func fetchFromCDN(id: String) async -> NSImage? {
        await state.loadMetaIfNeeded()
        let meta = await state.meta(for: id)
        let url = meta?.url
        let name = meta?.name ?? ""
        let task = await state.taskFor(id: id) {
            Task { await performFetch(id: id, name: name, url: url) }
        }
        let result = await task.value
        await state.clearInflight(id)
        return result
    }

    private static func performFetch(id: String, name: String, url: URL?) async -> NSImage? {
        guard let url else {
            appendLog("THUMB: end   id=\(id) name=\(name) ok=false error=no_previewImage_url")
            thumbnailLogger.warning("end id=\(id, privacy: .public) name=\(name, privacy: .public) ok=false error=no_previewImage_url")
            return nil
        }
        appendLog("THUMB: start id=\(id) name=\(name) url=\(url.absoluteString) tier=4")
        thumbnailLogger.info("start id=\(id, privacy: .public) name=\(name, privacy: .public) url=\(url.absoluteString, privacy: .public) tier=4")
        let start = Date()
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            let elapsedMS = Int(Date().timeIntervalSince(start) * 1000)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                appendLog("THUMB: end   id=\(id) name=\(name) bytes=\(data.count) elapsed_ms=\(elapsedMS) ok=false error=HTTP_\(http.statusCode)")
                thumbnailLogger.error("end id=\(id, privacy: .public) name=\(name, privacy: .public) ok=false error=HTTP_\(http.statusCode, privacy: .public)")
                return nil
            }
            guard let img = NSImage(data: data) else {
                appendLog("THUMB: end   id=\(id) name=\(name) bytes=\(data.count) elapsed_ms=\(elapsedMS) ok=false error=not_an_image")
                thumbnailLogger.error("end id=\(id, privacy: .public) name=\(name, privacy: .public) ok=false error=not_an_image")
                return nil
            }
            writeAtomic(data: data, to: Config.cachedThumbnailPath(for: id))
            await state.storeMem(id, img)
            appendLog("THUMB: end   id=\(id) name=\(name) bytes=\(data.count) elapsed_ms=\(elapsedMS) ok=true")
            thumbnailLogger.info("end id=\(id, privacy: .public) name=\(name, privacy: .public) bytes=\(data.count, privacy: .public) elapsed_ms=\(elapsedMS, privacy: .public) ok=true")
            return img
        } catch {
            let elapsedMS = Int(Date().timeIntervalSince(start) * 1000)
            let msg = sanitize(error.localizedDescription)
            appendLog("THUMB: end   id=\(id) name=\(name) elapsed_ms=\(elapsedMS) ok=false error=\(msg)")
            thumbnailLogger.error("end id=\(id, privacy: .public) name=\(name, privacy: .public) ok=false error=\(msg, privacy: .public)")
            return nil
        }
    }

    // MARK: - helpers

    private static func readLocal(path: String) -> NSImage? {
        guard FileManager.default.fileExists(atPath: path),
              let img = NSImage(contentsOfFile: path) else { return nil }
        return img
    }

    /// Temp-file + atomic rename so a crashed write can't leave a partial PNG
    /// in the cache dir, and the dir is created lazily here rather than at
    /// app launch (zero overhead until the first CDN miss).
    private static func writeAtomic(data: Data, to path: String) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let tmp = path + ".tmp"
        do {
            try data.write(to: URL(fileURLWithPath: tmp), options: .atomic)
            try? FileManager.default.removeItem(atPath: path)
            try FileManager.default.moveItem(atPath: tmp, toPath: path)
        } catch {
            try? FileManager.default.removeItem(atPath: tmp)
        }
    }

    private static func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }

    /// Serial queue so the tail-log append/rotate is consistent across the
    /// per-row `.task` and the batch loader; the network work runs concurrently
    /// off the queue, only the file-handle dance is serialised.
    private static let logQueue = DispatchQueue(label: "com.tyler.aerial-rotate.thumblog")

    /// Append `raw` to `Config.thumbnailLog`, truncating once the file passes
    /// ~1 MB. Matches the daemon's user-visible `/var/log/aerial-rotate.log`
    /// shape so `tail -F` on both gives a unified view of daemon + app work.
    private static func appendLog(_ raw: String) {
        let line = raw.hasSuffix("\n") ? raw : raw + "\n"
        logQueue.async {
            let path = Config.thumbnailLog
            let dir = (path as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let size = attrs[.size] as? Int, size > 1_000_000 {
                try? Data().write(to: URL(fileURLWithPath: path))
            }
            guard let data = line.data(using: .utf8) else { return }
            if !FileManager.default.fileExists(atPath: path) {
                try? data.write(to: URL(fileURLWithPath: path))
                return
            }
            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        }
    }
}
