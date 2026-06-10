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
                    DiskUsageRow()
                    NextRotationView()
                    RotateNowButton()
                    Divider()
                    SunMoonClock()
                    Divider()
                    CacheListView()
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
                Text("Downloading \(p.name.isEmpty ? "aerial" : p.name)").font(.headline)
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

// MARK: - 4. Next rotation countdown

private struct NextRotationView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Next rotation").font(.headline)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let target = state.nextRotationDate(now: ctx.date)
                let remaining = max(0, target.timeIntervalSince(ctx.date))
                HStack {
                    Image(systemName: "clock").foregroundStyle(.secondary)
                    Text(Format.countdown(remaining)).monospacedDigit()
                    Text("· daily at \(String(format: "%02d:%02d", state.rotationHour, state.rotationMinute))")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
    }
}

// MARK: - 5. Manual "rotate now" (smoke test / on-demand swap)

/// Runs the daily rotation on demand, same script the LaunchDaemon runs. Asks
/// for an admin password (root is needed to write the OS-owned asset dir), then
/// the existing log-tailer progress bar shows the download live. Disabled while
/// any rotation is already in flight so we never double-run.
private struct RotateNowButton: View {
    @EnvironmentObject private var state: AppState
    @State private var running = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: run) {
                if running {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Rotating…")
                    }
                } else {
                    Label("Refresh wallpaper now", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .buttonStyle(.bordered)
            .disabled(running || state.progress != nil)

            Text("Runs the daily rotation now. Asks for your password.")
                .font(.caption).foregroundStyle(.secondary)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func run() {
        running = true
        error = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                DaemonScheduler.runNow()
            }.value
            if case .failure(let msg) = result { error = msg }
            state.refresh()
            running = false
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
                        Text(item.name).lineLimit(1)
                        if item.appearedWithoutDaemon {
                            Label("appeared (OS prefetch)", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    Text(Format.bytes(item.sizeBytes))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
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

enum Format {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func countdown(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return String(format: "%02dh %02dm %02ds", h, m, sec)
    }
}
