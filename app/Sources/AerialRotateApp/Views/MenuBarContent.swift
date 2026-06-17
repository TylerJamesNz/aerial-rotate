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

        // Self-verify which build a given Mac is on after `git pull && ./app/update.sh`.
        Text("v\(appVersion)").font(.caption).foregroundStyle(.secondary)
        Button("Quit Aerial Rotate") { NSApp.terminate(nil) }
    }

    /// "<short> (<build>)" from the bundle's Info.plist, e.g. "1.1 (2)".
    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
