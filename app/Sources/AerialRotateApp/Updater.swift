import Foundation
import AppKit
import os

/// Unified-logging channel for the self-updater. Visible in Console.app (filter
/// on subsystem `com.aerialrotate.aerial-rotate`, category `updater`) and the CLI:
/// `log stream --predicate 'subsystem == "com.aerialrotate.aerial-rotate"' --info`.
private let updateLogger = Logger(subsystem: "com.aerialrotate.aerial-rotate", category: "updater")

/// The release the operator can install right now: version we pulled from the
/// GitHub API, the assets to fetch, and the human notes to optionally surface.
struct AvailableUpdate: Equatable, Sendable {
    var version: String          // "1.44"
    var tag: String              // "v1.44"
    var appAssetURL: URL         // browser_download_url for AerialRotate-vX.zip
    var daemonAssetURL: URL?     // browser_download_url for aerial-rotate.sh, if shipped this release
    var notes: String            // release body
}

/// Lifecycle of one check + download + install round-trip. The view layer
/// reads this off `AppState.updateState` to decide whether to draw the
/// install-and-relaunch banner. Download progress is non-zero only mid-fetch;
/// the locked UX keeps it silent (no progress bar in the banner) so a
/// `tail -F` on the updater log is the way to watch it live.
enum UpdateState: Equatable, Sendable {
    case idle
    case checking
    case available(AvailableUpdate)
    case downloading(version: String, loadedBytes: Int64, totalBytes: Int64)
    case ready(version: String, appZipPath: String, daemonPath: String?)
    case failed(reason: String)
}

/// Actor that owns the "is an update available, and what state is it in"
/// flow. Modelled on `ThumbnailCache` (actor-isolated state, dual `os.Logger`
/// + tail-log writer, atomic disk writes). One `check()` per launch + every
/// six hours of foreground runtime hits the public GitHub Releases API,
/// silently pre-fetches the .zip on a newer tag, parks in `.ready`, and waits
/// for the banner button to call `installAndRelaunch()`.
actor Updater {
    static let shared = Updater()

    /// Single source of truth for what state the UI sees. Mirrored onto
    /// `AppState.updateState` via `MainActor.run` so SwiftUI redraws the
    /// banner stack when the lifecycle advances.
    private var state: UpdateState = .idle

    /// `.ephemeral` so cookies / disk cache from earlier fetches can't
    /// pollute the next API call, mirroring `WeatherStore.session`.
    private let session = URLSession(configuration: .ephemeral)

    private static let lastCheckKey = "lastUpdateCheck"
    private static let throttle: TimeInterval = 6 * 60 * 60
    private static let repo = "TylerJamesNz/aerial-rotate"

    private init() {}

    // MARK: - public surface

    /// Once per launch + every six hours: hit the GitHub Releases API, compare
    /// versions, silently pre-fetch the .zip if newer, transition through
    /// `.available` → `.downloading` → `.ready`. The `.ready` state is sticky
    /// so a downloaded-but-not-clicked update stays surfaced across refreshes;
    /// a `.failed` or `.idle` outcome resets so the next throttle-passed call
    /// can retry.
    func check() async {
        switch state {
        case .checking, .downloading, .ready, .available:
            return
        case .idle, .failed:
            break
        }

        if let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date,
           Date().timeIntervalSince(last) < Self.throttle {
            return
        }

        await setState(.checking)

        let currentVersion = Self.currentVersion()

        guard let release = await fetchLatestRelease() else {
            await setState(.idle)
            return
        }

        UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)

        let newer = Self.isNewer(latest: release.version, current: currentVersion)
        log("UPDATE: check tag=\(release.tag) running=\(currentVersion) newer=\(newer)")

        guard newer, let appAssetURL = release.appAssetURL else {
            await setState(.idle)
            return
        }

        let available = AvailableUpdate(
            version: release.version,
            tag: release.tag,
            appAssetURL: appAssetURL,
            daemonAssetURL: release.daemonAssetURL,
            notes: release.notes
        )
        await setState(.available(available))
        await download(available)
    }

    /// Only valid from `.ready`. If the release shipped a fresh daemon script,
    /// prompts once for admin via osascript BEFORE quitting (so the prompt
    /// isn't a surprise after the app vanishes). Then spawns the detached
    /// helper script and quits, letting the helper swap the bundle and
    /// relaunch.
    func installAndRelaunch() async {
        guard case .ready(let version, let appZipPath, let daemonPath) = state else { return }
        let includesDaemon = daemonPath != nil
        log("UPDATE: install.start  version=\(version) includes_daemon=\(includesDaemon)")

        // Daemon hand-off BEFORE quitting so the admin prompt is visible while
        // the app is still on screen. A cancel here logs and falls through to
        // app-only install, leaving the daemon on its previous bytes.
        var daemonInstalled = false
        if let daemonPath {
            daemonInstalled = await installDaemon(from: daemonPath)
        }

        guard let helperBundleURL = Bundle.main.url(forResource: "install-update", withExtension: "sh") else {
            log("UPDATE: install.end    version=\(version) ok=false error=helper_missing_in_bundle")
            await setState(.failed(reason: "helper_missing_in_bundle"))
            return
        }

        // Copy the helper out of the bundle BEFORE quitting; it has to survive
        // the bundle swap that the helper itself performs.
        let helperStaging = Config.updateHelperScriptPath
        do {
            ensureStagingDir()
            try? FileManager.default.removeItem(atPath: helperStaging)
            try FileManager.default.copyItem(at: helperBundleURL, to: URL(fileURLWithPath: helperStaging))
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)],
                                                  ofItemAtPath: helperStaging)
        } catch {
            let msg = sanitize(error.localizedDescription)
            log("UPDATE: install.end    version=\(version) ok=false error=\(msg)")
            await setState(.failed(reason: msg))
            return
        }

        let bundlePath = Bundle.main.bundlePath
        let parentPID = String(ProcessInfo.processInfo.processIdentifier)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [helperStaging, appZipPath, bundlePath, parentPID]
        process.qualityOfService = .background
        process.standardInput = nil
        process.standardOutput = nil
        process.standardError = nil

        do {
            try process.run()
        } catch {
            let msg = sanitize(error.localizedDescription)
            log("UPDATE: install.end    version=\(version) ok=false error=\(msg)")
            await setState(.failed(reason: msg))
            return
        }

        log("UPDATE: install.end    version=\(version) ok=true daemon_installed=\(daemonInstalled)")

        await MainActor.run {
            NSApp.terminate(nil)
        }
    }

    // MARK: - state transitions

    private func setState(_ newState: UpdateState) async {
        state = newState
        await MainActor.run { AppState.shared.updateState = newState }
    }

    // MARK: - download

    private func download(_ available: AvailableUpdate) async {
        await setState(.downloading(version: available.version, loadedBytes: 0, totalBytes: 0))
        log("UPDATE: download.start version=\(available.version)")
        let start = Date()
        do {
            let (appZipTmp, _) = try await session.download(from: available.appAssetURL)
            ensureStagingDir()
            let appZipPath = Config.updateStagingDir + "/AerialRotate-\(available.tag).zip"
            try moveAtomic(from: appZipTmp, toPath: appZipPath)

            var daemonPath: String? = nil
            if let daemonURL = available.daemonAssetURL {
                let (daemonTmp, _) = try await session.download(from: daemonURL)
                let dst = Config.updateStagingDir + "/aerial-rotate-\(available.tag).sh"
                try moveAtomic(from: daemonTmp, toPath: dst)
                daemonPath = dst
            }

            let elapsed = Date().timeIntervalSince(start)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: appZipPath))?[.size] as? Int ?? 0
            log("UPDATE: download.end   version=\(available.version) bytes=\(bytes) elapsed_s=\(String(format: "%.1f", elapsed)) ok=true")

            await setState(.ready(version: available.version, appZipPath: appZipPath, daemonPath: daemonPath))
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            let msg = sanitize(error.localizedDescription)
            log("UPDATE: download.end   version=\(available.version) elapsed_s=\(String(format: "%.1f", elapsed)) ok=false error=\(msg)")
            await setState(.idle)
        }
    }

    // MARK: - daemon admin install

    /// Best-effort daemon overwrite via osascript admin privileges. Same shape
    /// as install.sh's sudo cp + chmod. Returns false on cancel or error, and
    /// the caller proceeds with an app-only install (the daemon stays on its
    /// previous bytes, picked up on next manual install or ship).
    private func installDaemon(from sourcePath: String) async -> Bool {
        let target = Config.daemonScript
        if filesByteEqual(sourcePath, target) {
            log("UPDATE: daemon.install skipped reason=identical_bytes")
            return true
        }
        let escapedSrc = sourcePath.replacingOccurrences(of: "'", with: "'\\''")
        let escapedTgt = target.replacingOccurrences(of: "'", with: "'\\''")
        let script = """
        do shell script "cp '\(escapedSrc)' '\(escapedTgt)' && chmod 755 '\(escapedTgt)'" with administrator privileges
        """
        let outcome: (ok: Bool, err: String?) = await MainActor.run {
            var error: NSDictionary?
            let appleScript = NSAppleScript(source: script)
            _ = appleScript?.executeAndReturnError(&error)
            if let err = error {
                return (false, "\(err)")
            }
            return (true, nil)
        }
        if !outcome.ok {
            log("UPDATE: daemon.install ok=false error=\(sanitize(outcome.err ?? "unknown"))")
            return false
        }
        log("UPDATE: daemon.install ok=true target=\(target)")
        return true
    }

    // MARK: - GitHub Releases API

    private struct ReleaseInfo {
        let version: String
        let tag: String
        let appAssetURL: URL?
        let daemonAssetURL: URL?
        let notes: String
    }

    private func fetchLatestRelease() async -> ReleaseInfo? {
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("aerial-rotate", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                log("UPDATE: api.error reason=no_http_response")
                return nil
            }
            guard http.statusCode == 200 else {
                log("UPDATE: api.error status=\(http.statusCode)")
                return nil
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String else {
                log("UPDATE: api.error reason=parse_failed")
                return nil
            }
            // Reject anything that isn't `v<digits>(.<digits>)*`. Conservative
            // by design: unparseable tags become "no update available", not a
            // false-positive prompt.
            guard tag.hasPrefix("v") else {
                log("UPDATE: api.error reason=tag_missing_v_prefix tag=\(tag)")
                return nil
            }
            let version = String(tag.dropFirst())
            guard Self.parseVersion(version) != nil else {
                log("UPDATE: api.error reason=tag_malformed tag=\(tag)")
                return nil
            }
            let notes = obj["body"] as? String ?? ""

            var appAsset: URL?
            var daemonAsset: URL?
            if let assets = obj["assets"] as? [[String: Any]] {
                for asset in assets {
                    guard let name = asset["name"] as? String,
                          let urlStr = asset["browser_download_url"] as? String,
                          let assetURL = URL(string: urlStr) else { continue }
                    if name.hasSuffix(".zip") && name.contains("AerialRotate") {
                        appAsset = assetURL
                    } else if name == "aerial-rotate.sh" {
                        daemonAsset = assetURL
                    }
                }
            }
            return ReleaseInfo(version: version, tag: tag,
                               appAssetURL: appAsset, daemonAssetURL: daemonAsset,
                               notes: notes)
        } catch {
            log("UPDATE: api.error reason=fetch_failed error=\(sanitize(error.localizedDescription))")
            return nil
        }
    }

    // MARK: - version comparison

    private static func parseVersion(_ s: String) -> [Int]? {
        let parts = s.split(separator: ".")
        guard !parts.isEmpty else { return nil }
        var out: [Int] = []
        for p in parts {
            guard let n = Int(p), n >= 0 else { return nil }
            out.append(n)
        }
        return out
    }

    private static func isNewer(latest: String, current: String) -> Bool {
        guard let l = parseVersion(latest), let c = parseVersion(current) else { return false }
        let n = max(l.count, c.count)
        for i in 0..<n {
            let li = i < l.count ? l[i] : 0
            let ci = i < c.count ? c[i] : 0
            if li > ci { return true }
            if li < ci { return false }
        }
        return false
    }

    private static func currentVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
    }

    // MARK: - filesystem helpers

    private func ensureStagingDir() {
        try? FileManager.default.createDirectory(atPath: Config.updateStagingDir,
                                                 withIntermediateDirectories: true)
    }

    private func moveAtomic(from src: URL, toPath dst: String) throws {
        let dstURL = URL(fileURLWithPath: dst)
        try? FileManager.default.removeItem(at: dstURL)
        try FileManager.default.moveItem(at: src, to: dstURL)
    }

    private func filesByteEqual(_ a: String, _ b: String) -> Bool {
        guard FileManager.default.fileExists(atPath: a),
              FileManager.default.fileExists(atPath: b),
              let aData = try? Data(contentsOf: URL(fileURLWithPath: a)),
              let bData = try? Data(contentsOf: URL(fileURLWithPath: b))
        else { return false }
        return aData == bData
    }

    // MARK: - logging

    private func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }

    /// Dual-channel log: os.Logger so it's visible in Console.app, and a
    /// user-owned tail file so `tail -F ~/Library/Application\ Support/aerial-rotate/updater.log`
    /// gives the same live view the thumbnail loader already provides.
    private func log(_ raw: String) {
        Self.appendLog(raw)
        updateLogger.info("\(raw, privacy: .public)")
    }

    private static let logQueue = DispatchQueue(label: "com.aerialrotate.aerial-rotate.updatelog")

    private static func appendLog(_ raw: String) {
        let line = raw.hasSuffix("\n") ? raw : raw + "\n"
        logQueue.async {
            let path = Config.updateLog
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
