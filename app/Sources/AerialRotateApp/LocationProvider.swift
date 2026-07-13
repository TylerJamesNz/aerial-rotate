import Foundation
import CoreLocation
import AppKit
import os

/// Precise device location for weather, via CoreLocation. Smoke (plan step 1a,
/// peppy-questing-wolf, v1.41 b43) confirmed this works on the ad-hoc-signed,
/// unsandboxed LSUIElement app: the grant persists against the pinned-identifier
/// identity (same mechanism that makes UserNotifications work) and a precise fix
/// arrives in ~3s. So this is the primary source; `WeatherStore` falls back to
/// IP geolocation only when no precise fix is available.
///
/// Correctness guards (CoreLocation's classic silent failures, designed out):
/// the CLLocationManager is created on the main thread, a strong reference is held
/// (AppDelegate owns this), `requestLocation()` runs only once authorization
/// resolves to authorized, the global `locationServicesEnabled()` check runs off
/// the main thread, and each one-shot fix is bounded by a timeout so a Mac that
/// never returns a fix degrades to the IP fallback instead of hanging the refresh.
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let log = Logger(subsystem: "com.aerialrotate.aerial-rotate.app", category: "location")
    private let manager: CLLocationManager

    /// Continuations awaiting the next one-shot fix, fulfilled by the delegate
    /// callbacks (or by the timeout). Touched only on the main actor.
    private var pending: [CheckedContinuation<CLLocationCoordinate2D?, Never>] = []
    /// Last good precise fix, reused if a later request times out or fails.
    private var lastFix: CLLocationCoordinate2D?

    override init() {
        manager = CLLocationManager()          // must be created on the main thread
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// Bring the accessory app forward so the system authorization alert surfaces
    /// in front (an LSUIElement app is not frontmost, so without this the prompt
    /// can appear behind everything and read as "no prompt fired"), then request.
    func start() {
        log.info("start, status=\(self.statusString(self.manager.authorizationStatus), privacy: .public)")
        DispatchQueue.global(qos: .utility).async {
            let on = CLLocationManager.locationServicesEnabled()   // can block; keep off main
            self.log.info("global locationServicesEnabled=\(on, privacy: .public)")
        }
        NSApp.activate(ignoringOtherApps: true)
        manager.requestWhenInUseAuthorization()
        publishDenied(for: manager.authorizationStatus)
    }

    /// One precise fix, bounded by `timeout`. Returns the freshest fix, or the last
    /// good one, or nil (caller then uses the IP fallback). Never hangs the refresh.
    @MainActor
    func currentCoordinate(timeout: TimeInterval = 5) async -> CLLocationCoordinate2D? {
        let status = manager.authorizationStatus
        guard status == .authorized || status == .authorizedAlways else {
            return lastFix   // not authorized: nil unless we have a cached precise fix
        }
        manager.requestLocation()
        let fix = await withCheckedContinuation { (c: CheckedContinuation<CLLocationCoordinate2D?, Never>) in
            pending.append(c)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.resume(with: self.lastFix)   // timeout: hand back whatever we have
            }
        }
        return fix ?? lastFix
    }

    @MainActor
    private func resume(with coord: CLLocationCoordinate2D?) {
        guard !pending.isEmpty else { return }
        let waiters = pending
        pending.removeAll()
        for c in waiters { c.resume(returning: coord) }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        log.info("authorization changed -> \(self.statusString(status), privacy: .public)")
        publishDenied(for: status)
        if status == .authorized || status == .authorizedAlways {
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        let coord = loc.coordinate
        log.info("got fix lat=\(coord.latitude, privacy: .public) lon=\(coord.longitude, privacy: .public)")
        Task { @MainActor in
            self.lastFix = coord
            self.resume(with: coord)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        log.error("location failed: \(error.localizedDescription, privacy: .public)")
        Task { @MainActor in self.resume(with: self.lastFix) }
    }

    // MARK: - helpers

    /// Banner shows only on a hard denial (or the global switch off), never on
    /// `notDetermined` (still waiting on the operator) or while authorized.
    private func publishDenied(for status: CLAuthorizationStatus) {
        let denied = (status == .denied || status == .restricted)
        Task { @MainActor in AppState.shared.locationDenied = denied }
    }

    private func statusString(_ s: CLAuthorizationStatus) -> String {
        switch s {
        case .notDetermined:    return "notDetermined"
        case .restricted:       return "restricted"
        case .denied:           return "denied"
        case .authorizedAlways: return "authorizedAlways"
        case .authorized:       return "authorized"
        @unknown default:       return "unknown(\(s.rawValue))"
        }
    }
}
