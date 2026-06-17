import SwiftUI
import AppKit

/// The rich status window, opened from the menu-bar item or a notification
/// click. Holds all six features.
struct MainWindow: View {
    @EnvironmentObject private var state: AppState
    @State private var leftContentHeight: CGFloat = 0
    // Visible height of the screen the window is actually on, kept current by
    // WindowClamp. Seeded from main so the first layout has a sane cap.
    @State private var availableHeight: CGFloat = NSScreen.main?.visibleFrame.height ?? 900

    /// Cap on the left column so the window grows to fit its content but never
    /// past the screen it sits on. Keys off the window's own screen (via
    /// `availableHeight`), not NSScreen.main, which can be a different monitor.
    private var maxContentHeight: CGFloat { max(520, availableHeight - 60) }

    var body: some View {
        // Size the window to the left column's content (the part that grows when
        // Add time appends a row), capped at the screen; the right sidebar fills
        // that height and scrolls its own list. Top-aligned so the left and right
        // column headings start on the same line.
        let columnHeight = max(520, min(leftContentHeight, maxContentHeight))
        HStack(alignment: .top, spacing: 0) {
            // Left column: the original window, unchanged.
            VStack(spacing: 0) {
                WallpaperWarningBanner()    // sticky top alert; renders nothing when not rotating
                LocationDisabledBanner()    // shows only when Location Services is off; weather on IP fallback
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        CurrentWallpaperCard()
                        if state.progress != nil { DownloadProgressView() }
                        Divider()
                        CacheListView()
                        DiskUsageRow()
                        NextRotationView()
                        Divider()
                        SunMoonClock()
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 28)
                    .background(GeometryReader { g in
                        Color.clear
                            .onAppear { leftContentHeight = g.size.height }
                            .onChange(of: g.size.height) { _, h in leftContentHeight = h }
                    })
                }
            }
            .frame(width: 460)

            Divider()

            // Right column: curate which aerials the daemon shuffles in.
            ShufflePoolSidebar()
                .frame(width: 420)
        }
        // The window sizes to this; growing it as Add time appends rows, capped
        // at the screen so it never spills off the bottom. Past the cap the
        // columns scroll internally instead of the window growing further.
        .frame(height: columnHeight)
        .frame(minHeight: 520)
        // Track the window's real screen and slide it back up if growth would
        // push its bottom off the screen (it grows downward from a fixed top).
        .background(WindowClamp(availableHeight: $availableHeight, desiredHeight: columnHeight))
        .onAppear { state.refresh() }
        // Live auto-refresh while the window is open: catches OS-prefetch
        // accumulation and a re-raised (not reopened) window, which `.onAppear`
        // alone misses. The manual ⟳ button stays as the explicit fallback.
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            state.refresh()
        }
    }
}

// MARK: - window sizing

/// Bridges to the hosting NSWindow and drives its height directly. SwiftUI's
/// `.contentSize` window doesn't reliably re-size to a *changing* content ideal
/// mid-session, so when Add time appends a row we set the window's content height
/// to `desiredHeight` ourselves. It also publishes the window's real screen
/// height (for the caller's cap) and keeps the window fully on-screen, since
/// `setContentSize` grows it upward from a fixed bottom edge.
private struct WindowClamp: NSViewRepresentable {
    @Binding var availableHeight: CGFloat
    var desiredHeight: CGFloat

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { context.coordinator.attach(to: v.window) }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.attach(to: nsView.window)
            context.coordinator.apply(height: desiredHeight)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator($availableHeight) }

    final class Coordinator: NSObject {
        private let availableHeight: Binding<CGFloat>
        private weak var window: NSWindow?
        private var token: NSObjectProtocol?

        init(_ availableHeight: Binding<CGFloat>) { self.availableHeight = availableHeight }

        func attach(to window: NSWindow?) {
            guard let window, window !== self.window else { return }
            self.window = window
            if let token { NotificationCenter.default.removeObserver(token) }
            token = NotificationCenter.default.addObserver(
                forName: NSWindow.didMoveNotification, object: window, queue: .main
            ) { [weak self] _ in self?.publishScreenHeight() }
            publishScreenHeight()
        }

        /// Resize the window to fit the content height, then keep it on-screen.
        func apply(height: CGFloat) {
            guard let window, let content = window.contentView else { return }
            publishScreenHeight()
            if abs(content.frame.height - height) > 0.5 {
                window.setContentSize(NSSize(width: content.frame.width, height: height))
            }
            clampPosition()
        }

        private func publishScreenHeight() {
            let h = window?.screen?.visibleFrame.height
                ?? NSScreen.main?.visibleFrame.height ?? 900
            if abs(availableHeight.wrappedValue - h) > 0.5 { availableHeight.wrappedValue = h }
        }

        /// Nudge the window back inside the visible frame: growth pushes the top
        /// up, shrink/move can drop the bottom below the dock.
        private func clampPosition() {
            guard let window, let vis = window.screen?.visibleFrame else { return }
            var f = window.frame
            if f.maxY > vis.maxY { f.origin.y = vis.maxY - f.height }
            if f.minY < vis.minY { f.origin.y = vis.minY }
            if f.origin != window.frame.origin {
                window.setFrame(f, display: true, animate: false)
            }
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
            HStack(spacing: 12) {
                metric("Cache total", Format.bytes(state.snapshot.totalBytes))
                metric("Current file", Format.bytes(state.snapshot.currentBytes))
                metric("On disk", "\(state.snapshot.items.count) aerial\(state.snapshot.items.count == 1 ? "" : "s")")
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        // Each metric takes an equal share of the row so the three always span
        // the column evenly (flexbox-style), regardless of value width.
        .frame(maxWidth: .infinity, alignment: .leading)
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
                    .buttonStyle(HoverIconButtonStyle())
            }
            if state.snapshot.items.isEmpty {
                Text("No aerials on disk.").foregroundStyle(.secondary).font(.callout)
            }
            VStack(spacing: 0) {
                ForEach(Array(state.snapshot.items.enumerated()), id: \.element.id) { index, item in
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
                            .buttonStyle(HoverIconButtonStyle())
                            .help("Reveal in Finder")
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(index.isMultiple(of: 2) ? Color.primary.opacity(0.05) : Color.clear)
                }
                Divider()
            }
        }
    }
}

// MARK: - 7. Shuffle-pool favourites sidebar

/// Right-hand sidebar to curate which aerials the daemon shuffles in. Every
/// shuffle-eligible aerial (the whole entries.json catalog, not just what's on
/// disk) is a checkbox row with a preview thumbnail, plus a Select-all header.
/// Empty favourites = shuffle everything (the Select-all default); ticking a
/// subset narrows the pool. Each toggle writes `shuffle-favourites.json`, which
/// the daemon reads and intersects with its pool. Reuses `AerialThumbnail` and
/// `HoverIconButtonStyle` from the installed-catalog list.
private struct ShufflePoolSidebar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Shuffle pool").font(.headline)
            Text("Tick the aerials to shuffle in. With none ticked, every aerial shuffles.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button { state.selectAllFavourites() } label: {
                HStack(spacing: 8) {
                    Image(systemName: state.allFavourited ? "checkmark.square.fill" : "square")
                        .foregroundStyle(state.allFavourited ? Color.accentColor : Color.secondary)
                    Text("Select all (\(state.shufflePool.count))").font(.callout.weight(.medium))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider()

            if state.shufflePool.isEmpty {
                Text("Catalog not readable.").foregroundStyle(.secondary).font(.callout)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(state.shufflePool.enumerated()), id: \.element.id) { index, asset in
                            Button { state.toggleFavourite(asset.id) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: state.isFavourite(asset.id) ? "checkmark.square.fill" : "square")
                                        .foregroundStyle(state.isFavourite(asset.id) ? Color.accentColor : Color.secondary)
                                    AerialThumbnail(id: asset.id)
                                    HoverMarquee(text: asset.name)
                                    ShortIDTag(id: asset.id, name: asset.name)
                                }
                                .padding(.vertical, 5)
                                .padding(.horizontal, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(index.isMultiple(of: 2) ? Color.primary.opacity(0.05) : Color.clear)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.03))
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

/// Sticky top alert shown only when Location Services is denied/restricted (or off
/// globally), so the operator knows weather is running on the approximate IP
/// fallback and how to upgrade it. Renders nothing while authorized or undecided.
private struct LocationDisabledBanner: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if state.locationDenied {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "location.slash.fill").foregroundStyle(.orange)
                    Text("Location is off, weather is approximate").font(.headline)
                    Spacer()
                }
                Text("AerialRotate is using your approximate location from your IP address to fetch weather. Turn on Location Services for AerialRotate to get accurate local conditions on the sky dial.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Open Location Services settings", systemImage: "gearshape")
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

// MARK: - hover-scroll label

/// Single-line label that scrolls horizontally on hover when its text is wider
/// than the width it's given, so a clipped aerial name can be read in full
/// without a tooltip. Fills the available width like a flexible column; sits
/// still when the text already fits.
private struct HoverMarquee: View {
    let text: String
    var font: Font = .callout

    @State private var textSize: CGSize = .zero
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let overflow = max(0, textSize.width - geo.size.width)
            Text(text)
                .font(font)
                .lineLimit(1)
                .fixedSize()
                .background(
                    GeometryReader { t in
                        Color.clear
                            .onAppear { textSize = t.size }
                            .onChange(of: t.size) { _, new in textSize = new }
                    }
                )
                .offset(x: hovering ? -overflow : 0)
                .frame(width: geo.size.width, alignment: .leading)
                .clipped()
                .contentShape(Rectangle())
                .onHover { h in
                    guard overflow > 0 else { return }
                    withAnimation(h
                        ? .linear(duration: Double(overflow) / 35).delay(0.25)
                        : .easeOut(duration: 0.2)) {
                        hovering = h
                    }
                }
        }
        // GeometryReader is greedy; pin it to the leftover row width and the
        // text's own height so it never forces the row wider (which knocked the
        // checkbox + thumbnail out of line) or taller.
        .frame(maxWidth: .infinity)
        .frame(height: textSize.height == 0 ? 17 : textSize.height)
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

    /// 12-hour "8:00AM" for a single time. The app shows every time in AM/PM.
    static func time12(_ t: RotationTime) -> String {
        let am = t.hour < 12
        let h = t.hour % 12 == 0 ? 12 : t.hour % 12
        return String(format: "%d:%02d%@", h, t.minute, am ? "AM" : "PM")
    }

    /// Full 12-hour hour-only "6AM" / "12PM" for the dial's cardinal labels.
    static func hour12(_ hour: Int) -> String {
        let am = hour < 12
        let h = hour % 12 == 0 ? 12 : hour % 12
        return "\(h)\(am ? "AM" : "PM")"
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
