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

/// Single source of truth the views observe. All mutation happens on the main
/// actor; file reads are done on a background task and the results assigned back.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var progress: DownloadProgress?      // nil = idle
    @Published var snapshot: CacheSnapshot = .empty
    @Published var currentName: String = "—"
    @Published var rotating: Bool = false           // wallpaper is on a shuffle/rotate aerial source
    @Published var rotationHour: Int = 12
    @Published var rotationMinute: Int = 0
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
            let time = CacheModel.rotationTime()
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
                if let t = time {
                    self.rotationHour = t.hour
                    self.rotationMinute = t.minute
                }
            }
        }
    }

    /// Next wall-clock occurrence of the scheduled rotation time.
    func nextRotationDate(now: Date = Date()) -> Date {
        var cal = Calendar.current
        cal.timeZone = .current
        var comps = DateComponents()
        comps.hour = rotationHour
        comps.minute = rotationMinute
        comps.second = 0
        // nextDate(after:) returns the next future match, rolling to tomorrow if today's time has passed.
        return cal.nextDate(after: now, matching: comps, matchingPolicy: .nextTime) ?? now
    }

    func recordEvent(_ summary: String) {
        lastEvent = summary
        lastEventAt = Date()
    }
}
