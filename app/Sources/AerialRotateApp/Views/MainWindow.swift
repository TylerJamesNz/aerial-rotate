import SwiftUI
import AppKit

/// The rich status window, opened from the menu-bar item or a notification
/// click. Holds all six features.
struct MainWindow: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            WallpaperWarningBanner()        // sticky top alert; renders nothing when not rotating
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    CurrentWallpaperCard()
                    if state.progress != nil { DownloadProgressView() }
                    Divider()
                    CacheListView()
                    Divider()
                    DiskUsageRow()
                    NextRotationView()
                    Divider()
                    SunMoonClock()
                }
                .padding(24)
            }
        }
        .frame(width: 460)
        .frame(minHeight: 520)
        .onAppear { state.refresh() }
        // Live auto-refresh while the window is open: catches OS-prefetch
        // accumulation and a re-raised (not reopened) window, which `.onAppear`
        // alone misses. The manual ⟳ button stays as the explicit fallback.
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            state.refresh()
        }
    }
}

// MARK: - 1. Current wallpaper + Reveal in Finder

private struct CurrentWallpaperCard: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Current wallpaper").font(.headline)
            HStack {
                Image(systemName: "photo.fill").foregroundStyle(.secondary)
                Text(state.currentName).font(.title3).lineLimit(2)
                ShortIDTag(id: state.snapshot.currentID ?? "", name: state.currentName)
                Spacer()
                Button {
                    if let url = WallpaperStore.currentMovURL() {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .disabled(WallpaperStore.currentMovURL() == nil)
            }
        }
    }
}

// MARK: - 2. Live download progress

private struct DownloadProgressView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if let p = state.progress {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Downloading \(p.name.isEmpty ? "aerial" : p.name)").font(.headline)
                    ShortIDTag(id: p.assetID ?? "", name: p.name)
                }
                ProgressView(value: Double(p.percent), total: 100)
                HStack {
                    Text("\(p.percent)%")
                    if let mb = p.megabytes { Text("· \(mb) MB").foregroundStyle(.secondary) }
                    Spacer()
                }
                .font(.caption)
            }
        }
    }
}

// MARK: - 3. Disk usage

private struct DiskUsageRow: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Disk usage").font(.headline)
            HStack(spacing: 24) {
                metric("Cache total", Format.bytes(state.snapshot.totalBytes))
                metric("Current file", Format.bytes(state.snapshot.currentBytes))
                metric("On disk", "\(state.snapshot.items.count) aerial\(state.snapshot.items.count == 1 ? "" : "s")")
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - 4. Next rotation countdown + on-demand refresh

/// The countdown to the next scheduled rotation, with the "Refresh now" button
/// on the same line (the daily schedule itself is shown by the picker and the
/// celestial dial below, so it isn't repeated here). Refresh runs the daily
/// rotation on demand by bumping the WatchPaths trigger (no password: the root
/// daemon does the privileged work). `triggered` covers the brief gap between
/// the touch and the daemon's first log line; once `state.progress` appears,
/// that drives the spinner until the run finishes. Disabled while any rotation
/// is already in flight so we never double-fire.
private struct NextRotationView: View {
    @EnvironmentObject private var state: AppState
    @State private var triggered = false
    @State private var error: String?

    private var busy: Bool { triggered || state.progress != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Next rotation").font(.headline)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let target = state.nextRotationDate(now: ctx.date)
                let remaining = max(0, target.timeIntervalSince(ctx.date))
                HStack {
                    Image(systemName: "clock").foregroundStyle(.secondary)
                    if state.rotationTimes.isEmpty {
                        Text("no rotations scheduled").foregroundStyle(.secondary)
                    } else {
                        Text(Format.countdown(remaining)).monospacedDigit()
                    }
                    Spacer()
                    Button(action: run) {
                        if busy {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Rotating…")
                            }
                        } else {
                            Label("Refresh now", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(busy)
                    .help("Fetches a fresh wallpaper now. No password needed.")
                }
                .font(.callout)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func run() {
        triggered = true
        error = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                DaemonScheduler.runNow()
            }.value
            if case .failure(let msg) = result {
                error = msg
                triggered = false
                return
            }
            // The touch returns instantly; wait (up to ~20s) for the daemon to
            // start emitting progress, then hand the spinner over to it. Clears
            // on timeout too, so a no-op run (e.g. stale-trigger skip) recovers.
            for _ in 0..<40 {
                if state.progress != nil { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            triggered = false
            state.refresh()
        }
    }
}

// MARK: - 6. Installed-aerial catalog

private struct CacheListView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Installed aerials").font(.headline)
                Spacer()
                Button { state.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
            }
            if state.snapshot.items.isEmpty {
                Text("No aerials on disk.").foregroundStyle(.secondary).font(.callout)
            }
            ForEach(state.snapshot.items) { item in
                HStack(spacing: 8) {
                    Image(systemName: item.isCurrent ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(item.isCurrent ? Color.accentColor : Color.secondary)
                    AerialThumbnail(id: item.id)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(item.name).lineLimit(1)
                            ShortIDTag(id: item.id, name: item.name)
                        }
                        if item.appearedWithoutDaemon {
                            Label("appeared (OS prefetch)", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    Text(Format.bytes(item.sizeBytes))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    if let url = WallpaperStore.movURL(for: item.id) {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.borderless)
                        .help("Reveal in Finder")
                    }
                }
                .padding(.vertical, 2)
                Divider()
            }
        }
    }
}

// MARK: - wallpaper-setting warning overlay

/// Shown when macOS is auto-downloading aerials, i.e. the wallpaper is still on a
/// shuffle/rotating aerial source. Guides the operator to pin a single aerial and
/// deep-links to the Wallpaper settings pane.
///
/// Detection is symptom-based for now (cache count): the Shuffle-dict signal
/// proved unreliable this session (downloads continued with the Shuffle dict
/// removed), and the count is the dependable tell. Refine with a plist-setting
/// read once the single-aerial UI signature is captured (see handoff amber-meridian).
private struct WallpaperWarningBanner: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if state.rotating {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Rotating aerials are on").font(.headline)
                    Spacer()
                }
                Text("macOS keeps downloading the whole catalog (\(state.snapshot.items.count) videos, \(Format.bytes(state.snapshot.totalBytes)) on disk) while the wallpaper is set to Shuffle. Pin a single aerial to stop it.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    settingChip(icon: "arrow.triangle.2.circlepath", label: "Shuffle", good: false)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    settingChip(icon: "photo.fill", label: "Single aerial", good: true)
                    Spacer()
                }
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Fix this, open Wallpaper Settings", systemImage: "gearshape")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12))
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Color.orange.opacity(0.4)), alignment: .bottom)
        }
    }

    /// Small before/after swatch: the bad (Shuffle, red ✗) and good (Single, green ✓) states.
    private func settingChip(icon: String, label: String, good: Bool) -> some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(good ? Color.green.opacity(0.18) : Color.secondary.opacity(0.12))
                    .frame(width: 52, height: 32)
                    .overlay(Image(systemName: icon).foregroundStyle(good ? Color.green : Color.secondary))
                Image(systemName: good ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(good ? Color.green : Color.red)
                    .background(Circle().fill(.background))
                    .offset(x: 5, y: -5)
            }
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - thumbnail

/// 16:9 preview for a cached aerial, loaded from the local idleassetsd snapshot
/// JPEG (no network). Decoded once per id and memoised so the 5s auto-refresh
/// doesn't re-read disk.
private struct AerialThumbnail: View {
    let id: String
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
                    .overlay(Image(systemName: "photo").foregroundStyle(.secondary).font(.caption2))
            }
        }
        .frame(width: 64, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: id) { image = ThumbnailCache.image(for: id) }
    }
}

/// Memoised loader for the local asset-preview JPEGs.
private enum ThumbnailCache {
    private static var mem: [String: NSImage] = [:]

    static func image(for id: String) -> NSImage? {
        if let hit = mem[id] { return hit }
        let path = Config.previewImagePath(for: id)
        guard FileManager.default.fileExists(atPath: path),
              let img = NSImage(contentsOfFile: path) else { return nil }
        mem[id] = img
        return img
    }
}

// MARK: - formatting

/// Dimmed, monospaced first-8 of the asset UUID, shown after a name so two
/// same-named aerials (Apple ships several "Yosemite" clips, each a distinct
/// asset id) can be told apart. Renders nothing when the name already falls back
/// to the id (no human label), so the UUID never prints twice.
private struct ShortIDTag: View {
    let id: String
    let name: String
    var body: some View {
        if !id.isEmpty && id != name {
            Text(Format.shortID(id))
                .font(.caption).monospaced().foregroundStyle(.secondary)
        }
    }
}

enum Format {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func shortID(_ id: String) -> String { String(id.prefix(8)).lowercased() }

    /// 12-hour "8:00 AM" for a single time. The app shows every time in AM/PM.
    static func time12(_ t: RotationTime) -> String {
        let am = t.hour < 12
        let h = t.hour % 12 == 0 ? 12 : t.hour % 12
        return String(format: "%d:%02d %@", h, t.minute, am ? "AM" : "PM")
    }

    /// Compact 12-hour "8:00a" for tight dial captions where AM/PM must fit a
    /// 9pt monospaced label.
    static func time12Compact(_ t: RotationTime) -> String {
        let am = t.hour < 12
        let h = t.hour % 12 == 0 ? 12 : t.hour % 12
        return String(format: "%d:%02d%@", h, t.minute, am ? "a" : "p")
    }

    /// Compact 12-hour hour-only "6a" / "12p" for the dial's hour graduations.
    static func hour12Compact(_ hour: Int) -> String {
        let am = hour < 12
        let h = hour % 12 == 0 ? 12 : hour % 12
        return "\(h)\(am ? "a" : "p")"
    }

    /// "8:00 AM, 12:00 PM, 6:30 PM" for the schedule label (sorted).
    static func timeList(_ times: [RotationTime]) -> String {
        times.sorted()
            .map { time12($0) }
            .joined(separator: ", ")
    }

    static func countdown(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return String(format: "%02dh %02dm %02ds", h, m, sec)
    }
}
