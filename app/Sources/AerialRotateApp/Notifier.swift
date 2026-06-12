import Foundation
import AppKit
import UserNotifications

/// Posts the app's own Notification Center banners and routes a banner click to
/// the main window. This is the whole point of the app: it runs in the user GUI
/// session, so `UNUserNotificationCenter` actually works here, where the root
/// daemon could never get a notification grant (swiftDialog issue #373).
///
/// Requires the app to be code-signed (even ad-hoc) and launched as a bundle.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    /// Call from applicationDidFinishLaunching, BEFORE launch completes, so a
    /// cold launch from a notification click still routes through `didReceive`.
    func bootstrap() {
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil)            // nil = deliver immediately
        center.add(request)
    }

    // Show banners even when the app is frontmost.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // Banner clicked: foreground the app and open/raise the window.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            AppState.shared.requestOpenWindow()
        }
        completionHandler()
    }
}
