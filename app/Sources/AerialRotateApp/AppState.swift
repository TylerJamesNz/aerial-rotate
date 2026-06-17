import Foundation
import SwiftUI

/// Live download/rotation progress parsed from the daemon log. `nil` on AppState
/// means idle (no rotation in flight).
struct DownloadProgress: Equatable {
    var name: String
    var percent: Int
    var megabytes: Int?
    var assetID: String?
}

/// Why the daemon decided it can't rotate, surfaced as a typed banner in the
/// main window's banner stack. `nil` on AppState means healthy. The
/// LogTailer derives this from `PREFLIGHT: FAIL ...` lines and the existing
/// `NOTIFY: Aerial rotate failed - code=<x> ...` channel; `applied` clears it.
enum PreflightFailure: Equatable {
    case noGUIUser
    case catalogMissing(path: String)
    case catalogMalformed(path: String)
    case catalogEmpty(path: String)
    case wallpaperStoreMissing(path: String)
    case schemaShifted
    case wallpaperSourceWrong(provider: String)
    case wallpaperSourceUnset
    case downloadFailed
    case runtimeError(code: String, detail: String)

    /// Two-word menu-bar label for the dropdown line under `lastEvent`.
    var shortLabel: String {
        switch self {
        case .noGUIUser:                return "no active user session"
        case .catalogMissing:           return "aerial catalog missing"
        case .catalogMalformed:         return "aerial catalog malformed"
        case .catalogEmpty:             return "aerial catalog empty"
        case .wallpaperStoreMissing:    return "wallpaper store missing"
        case .schemaShifted:            return "wallpaper schema shifted"
        case .wallpaperSourceWrong:     return "wallpaper source isn't Aerial"
        case .wallpaperSourceUnset:     return "wallpaper source not set"
        case .downloadFailed:           return "download failed"
        case .runtimeError(let code, _): return "rotation failed (\(code))"
        }
    }
}

/// One scheduled daily rotation time. The list of these is the source of truth
/// for the schedule; each maps to a `{Hour, Minute}` dict in the agent plist's
/// `StartCalendarInterval` array. Identifiable so SwiftUI can diff editor rows
/// across an edit, Comparable so the set sorts chronologically.
struct RotationTime: Identifiable, Hashable, Comparable {
    let id = UUID()
    var hour: Int
    var minute: Int
    static func < (a: RotationTime, b: RotationTime) -> Bool {
        (a.hour, a.minute) < (b.hour, b.minute)
    }
}

/// Single source of truth the views observe. All mutation happens on the main
/// actor; file reads are done on a background task and the results assigned back.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var progress: DownloadProgress?      // nil = idle
    @Published var snapshot: CacheSnapshot = .empty
    @Published var currentName: String = "—"
    @Published var rotating: Bool = false           // wallpaper is on a shuffle/rotate aerial source
    @Published var rotationTimes: [RotationTime] = [RotationTime(hour: 12, minute: 0)]
    @Published var lastEvent: String = ""           // most recent NOTIFY summary, for the menu
    @Published var lastEventAt: Date?

    /// Latest local weather, polled by `WeatherStore`. `.unknown` until the first
    /// successful fetch; the dial draws a plain time-of-day sky in that case.
    @Published var weather: WeatherSnapshot = .unknown

    /// True when Location Services is denied/restricted for the app (or off
    /// globally), so weather is running on the approximate IP fallback. Drives
    /// `LocationDisabledBanner`. False while authorized or still undecided, so
    /// the banner never flashes before the operator answers the prompt.
    @Published var locationDenied: Bool = false

    /// Set when the daemon's most recent run hit a preflight failure (or a
    /// rotation-time failure with a code= tag). `nil` means healthy. Cleared
    /// when the LogTailer sees the next `NOTIFY: ✅ New wallpaper applied`.
    @Published var preflight: PreflightFailure?

    /// False when the daemon's last preflight noted `WARN dialog.missing`. The
    /// app's user-session Notifier is the real banner channel, so this is
    /// informational — surfaces a soft "install swiftDialog for daemon-side
    /// notifications" hint, not a blocker.
    @Published var dialogPresent: Bool = true

    /// The console user the daemon resolved on its last run, surfaced in the
    /// dropdown to help diagnose multi-user / no-GUI-user scenarios. nil until
    /// the LogTailer parses the first `PREFLIGHT: OK user.console ...` line.
    @Published var resolvedUser: String?

    /// The whole shuffle-eligible catalog (entries.json superset), shown in the
    /// favourites sidebar. Loaded off the main actor in `refresh()`.
    @Published var shufflePool: [ShuffleAsset] = []

    /// Curated shuffle favourites. EMPTY is the "all" sentinel: zero curated
    /// means the daemon shuffles the whole pool, and every sidebar row reads as
    /// ticked. A non-empty set narrows the pool to exactly those ids. Mirrored
    /// to `shuffle-favourites.json` on every toggle for the daemon to read.
    @Published var favourites: Set<String> = []

    /// The last curated (non-empty) selection, kept so the Select-all row can
    /// flip between "all" and the operator's remembered picks instead of losing
    /// them. UI-only, so it lives in UserDefaults, not the daemon's favourites
    /// file (the daemon only ever reads `favourites`). Survives relaunch.
    private static let rememberedKey = "shuffleRememberedFavourites"
    private var rememberedFavourites: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: AppState.rememberedKey) ?? [])

    private func saveRemembered() {
        UserDefaults.standard.set(Array(rememberedFavourites), forKey: AppState.rememberedKey)
    }

    /// Bumped to request the main window be opened/raised (from the menu or a
    /// notification click). `AerialRotateApp` observes this via `onChange`.
    @Published var openWindowRequests: Int = 0

    private init() {}

    func requestOpenWindow() { openWindowRequests &+= 1 }

    /// Re-read cache + current wallpaper + schedule off the main actor, then publish.
    func refresh() {
        Task.detached(priority: .utility) {
            let currentID = WallpaperStore.currentAssetID()
            let snap = CacheModel.snapshot(currentID: currentID)
            let times = CacheModel.rotationTimes()
            let rotating = WallpaperStore.isRotating()
            let pool = ShufflePool.load()
            let favs = FavouritesStore.load()
            await MainActor.run {
                self.snapshot = snap
                self.rotating = rotating
                // Reassign the pool / favourites only when they actually changed,
                // so the 5s refresh doesn't redraw the sidebar (and clobber an
                // in-flight toggle) on every tick. The file the UI just wrote is
                // the source of truth, so a re-read normally matches in-memory.
                if self.shufflePool != pool { self.shufflePool = pool }
                if self.favourites != favs { self.favourites = favs }
                if let id = currentID,
                   let item = snap.items.first(where: { $0.id == id }) {
                    self.currentName = item.name
                } else {
                    self.currentName = currentID ?? "—"
                }
                // Reassign only when the schedule actually differs from what's
                // in memory. The editor auto-applies off `rotationTimes` changes,
                // so a no-op reassign (new UUIDs, same times) on every 5s refresh
                // would thrash launchctl. Comparing by (hour, minute) keeps the
                // existing rows (stable ids) put when nothing changed on disk.
                // An empty read (parse failure) leaves the list alone; a genuinely
                // empty schedule is written through reschedule(), not read here.
                if !times.isEmpty {
                    let incoming = times
                        .map { RotationTime(hour: $0.hour, minute: $0.minute) }
                        .sorted()
                    let current = self.rotationTimes.sorted()
                    let unchanged = current.count == incoming.count &&
                        zip(current, incoming).allSatisfy { $0.hour == $1.hour && $0.minute == $1.minute }
                    if !unchanged { self.rotationTimes = incoming }
                }
            }
        }
    }

    /// Soonest future occurrence across all scheduled times. With an empty
    /// schedule there's nothing to count down to, so return `.distantFuture`
    /// (the countdown reads as "no rotations scheduled" upstream).
    func nextRotationDate(now: Date = Date()) -> Date {
        guard !rotationTimes.isEmpty else { return .distantFuture }
        var cal = Calendar.current
        cal.timeZone = .current
        // nextDate(after:) returns each time's next future match, rolling to
        // tomorrow if today's has passed; the soonest of those is the next fire.
        return rotationTimes.compactMap { t -> Date? in
            var comps = DateComponents()
            comps.hour = t.hour
            comps.minute = t.minute
            comps.second = 0
            return cal.nextDate(after: now, matching: comps, matchingPolicy: .nextTime)
        }.min() ?? .distantFuture
    }

    func recordEvent(_ summary: String) {
        lastEvent = summary
        lastEventAt = Date()
    }

    // MARK: - shuffle favourites

    /// Whether `id` is treated as a shuffle favourite right now. Empty favourites
    /// is the "all" sentinel, so every asset reads as ticked until curation starts.
    func isFavourite(_ id: String) -> Bool {
        favourites.isEmpty || favourites.contains(id)
    }

    /// Select-all is ticked exactly when nothing is curated (the all-default).
    var allFavourited: Bool { favourites.isEmpty }

    /// Toggle one asset's membership and persist. Un-ticking while on the "all"
    /// sentinel materialises the explicit "everything except this" set; re-ticking
    /// back to the full pool collapses to the empty sentinel (daemon treats a full
    /// set as "all" anyway). The empty sentinel is never an empty pool: it means all.
    func toggleFavourite(_ id: String) {
        var next: Set<String>
        if favourites.isEmpty {
            next = Set(shufflePool.map(\.id))
            next.remove(id)
        } else if favourites.contains(id) {
            next = favourites
            next.remove(id)
        } else {
            next = favourites
            next.insert(id)
        }
        if next.count == shufflePool.count { next = [] }   // full set == all
        favourites = next
        // Remember any non-empty curation so the Select-all row can flip back to
        // it. The empty "all" sentinel is never a remembered preference.
        if !next.isEmpty {
            rememberedFavourites = next
            saveRemembered()
        }
        FavouritesStore.save(next)
    }

    /// Select-all row, toggled. Flips between "all" (the empty sentinel) and the
    /// operator's remembered individual picks. From all, it restores the last
    /// remembered selection (or seeds with the first aerial if there's nothing
    /// remembered yet); from a curated subset, it remembers that subset and
    /// returns to all. Stale remembered ids (catalog changed) are dropped.
    func selectAllFavourites() {
        if allFavourited {
            let restored = rememberedFavourites.intersection(Set(shufflePool.map(\.id)))
            if !restored.isEmpty {
                favourites = restored
            } else if let first = shufflePool.first?.id {
                favourites = [first]
            } else {
                favourites = []
            }
        } else {
            rememberedFavourites = favourites
            saveRemembered()
            favourites = []
        }
        FavouritesStore.save(favourites)
    }
}
