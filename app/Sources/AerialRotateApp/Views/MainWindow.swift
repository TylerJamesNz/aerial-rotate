import SwiftUI
import AppKit

/// The rich status window, opened from the menu-bar item or a notification
/// click. Holds all six features.
struct MainWindow: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                CurrentWallpaperCard()
                if state.progress != nil { DownloadProgressView() }
                DiskUsageRow()
                NextRotationView()
                Divider()
                SunMoonClock()
                Divider()
                CacheListView()
            }
            .padding(24)
            .frame(width: 460, alignment: .leading)
        }
        .frame(minHeight: 520)
        .onAppear { state.refresh() }
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
