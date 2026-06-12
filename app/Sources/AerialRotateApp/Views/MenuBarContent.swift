import SwiftUI
import AppKit

/// The dropdown shown when the menu-bar icon is clicked: a quick status line, an
/// Open button into the rich window, refresh, and quit.
struct MenuBarContent: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let p = state.progress {
            Text("Downloading \(p.name.isEmpty ? "aerial" : p.name) — \(p.percent)%")
        } else {
            Text("Current: \(state.currentName)")
        }

        if !state.lastEvent.isEmpty {
            Text(state.lastEvent).font(.caption)
        }

        Divider()

        Button("Open Aerial Rotate") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Refresh") { state.refresh() }

        Divider()

        Button("Quit Aerial Rotate") { NSApp.terminate(nil) }
    }
}
