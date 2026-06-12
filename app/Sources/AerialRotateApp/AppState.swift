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
            await MainActor.run {
                self.snapshot = snap
                self.rotating = rotating
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
}
