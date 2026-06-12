import SwiftUI
import AppKit

@main
struct AerialRotateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        // Entry point 1: the menu-bar status item. Its label is the persistent
        // observer that opens the window on a notification-click request.
        MenuBarExtra {
            MenuBarContent().environmentObject(state)
        } label: {
            MenuBarLabel().environmentObject(state)
        }
        .menuBarExtraStyle(.menu)

        // Entry point 2: the rich window, also opened from a notification click.
        Window("Aerial Rotate", id: "main") {
            MainWindow().environmentObject(state)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

/// The menu-bar icon. Always alive while the app runs, so it is the right place
/// to observe `openWindowRequests` and open/raise the window from a
/// notification click (the window scene's own views aren't alive while closed).
private struct MenuBarLabel: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: "photo.on.rectangle.angled")
            .onChange(of: state.openWindowRequests) { _, _ in
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let tailer = LogTailer()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement already sets accessory policy; assert it for clarity.
        NSApp.setActivationPolicy(.accessory)
        // Delegate must be set before launch completes so a cold launch from a
        // notification click routes through didReceive.
        Notifier.shared.bootstrap()
        tailer.start()
        AppState.shared.refresh()
    }

    // Agent app: closing the window must not quit it; the menu bar item lives on.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
