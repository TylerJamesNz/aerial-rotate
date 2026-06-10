import SwiftUI

/// Feature 5: set the daily rotation time. The aesthetic is f.lux-style: a
/// day/night gradient arc with a sun and moon and a marker that glides to the
/// selected time. The actual input is a digital clock field (the source of
/// truth). "Set" reschedules the daemon via an admin-auth prompt.
struct SunMoonClock: View {
    @EnvironmentObject private var state: AppState

    @State private var time = Date()
    @State private var status: String = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rotation time").font(.headline)

            SunMoonArc(fraction: fractionOfDay(time))
                .frame(height: 96)
                .frame(maxWidth: .infinity)

            HStack(spacing: 12) {
                Image(systemName: "clock.badge.checkmark").foregroundStyle(.secondary)
                DatePicker("", selection: $time, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.field)
                    .labelsHidden()
                Spacer()
                Button(busy ? "Setting…" : "Set rotation time") { applyTime() }
                    .disabled(busy)
            }

            if !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .onAppear { syncFromState() }
        .onChange(of: state.rotationHour) { _, _ in syncFromState() }
        .onChange(of: state.rotationMinute) { _, _ in syncFromState() }
    }

    private func syncFromState() {
        var comps = DateComponents()
        comps.hour = state.rotationHour
        comps.minute = state.rotationMinute
        if let d = Calendar.current.date(from: comps) { time = d }
    }

    private func fractionOfDay(_ date: Date) -> Double {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        let mins = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return Double(mins) / 1440.0
    }

    private func applyTime() {
        let c = Calendar.current.dateComponents([.hour, .minute], from: time)
        let h = c.hour ?? 0, m = c.minute ?? 0
        busy = true
        status = ""
        // NSAppleScript admin auth is synchronous/modal; run on the next runloop
        // tick so the button shows "Setting…" first.
        DispatchQueue.main.async {
            let result = DaemonScheduler.reschedule(hour: h, minute: m)
            busy = false
            switch result {
            case .success:
                status = String(format: "Rescheduled to %02d:%02d daily.", h, m)
                state.refresh()
            case .canceled:
                status = "Cancelled, schedule unchanged."
            case .failure(let msg):
                status = "Failed: \(msg)"
            }
        }
    }
}

/// The day/night arc with sun, moon, and a marker at `fraction` (0 = 00:00,
/// 0.5 = noon at the top, 1 = 24:00). Read-only; driven by the selected time.
private struct SunMoonArc: View {
    var fraction: Double

    var body: some View {
        Canvas { context, size in
            let r = min(size.width, size.height * 2) / 2 * 0.82
            let cx = size.width / 2
            let cy = size.height - 6
            let center = CGPoint(x: cx, y: cy)

            // Arc path (semicircle bulging up).
            var arc = Path()
            arc.addArc(center: center, radius: r,
                       startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)

            // Night -> day -> night gradient along the arc.
            let gradient = Gradient(colors: [
                Color(red: 0.10, green: 0.12, blue: 0.30),   // night (left)
                Color(red: 0.98, green: 0.78, blue: 0.36),   // day (top)
                Color(red: 0.10, green: 0.12, blue: 0.30),   // night (right)
            ])
            context.stroke(
                arc,
                with: .linearGradient(gradient,
                                      startPoint: CGPoint(x: cx - r, y: cy),
                                      endPoint: CGPoint(x: cx + r, y: cy)),
                style: StrokeStyle(lineWidth: 5, lineCap: .round))

            // Marker on the arc at the selected fraction.
            let theta = Double.pi * (1 - max(0, min(1, fraction)))
            let mp = CGPoint(x: cx + r * cos(theta), y: cy - r * sin(theta))
            let dot = Path(ellipseIn: CGRect(x: mp.x - 7, y: mp.y - 7, width: 14, height: 14))
            context.fill(dot, with: .color(.white))
            context.stroke(dot, with: .color(.black.opacity(0.25)), lineWidth: 1)

            // Sun (top) and moons (corners) as resolved SF Symbols.
            drawSymbol(context, "sun.max.fill", at: CGPoint(x: cx, y: cy - r - 2), size: 20, color: .orange)
            drawSymbol(context, "moon.fill", at: CGPoint(x: cx - r, y: cy + 12), size: 14, color: .indigo)
            drawSymbol(context, "moon.fill", at: CGPoint(x: cx + r, y: cy + 12), size: 14, color: .indigo)
        }
    }

    private func drawSymbol(_ context: GraphicsContext, _ name: String, at p: CGPoint, size: CGFloat, color: Color) {
        let image = Image(systemName: name)
        var resolved = context.resolve(image)
        resolved.shading = .color(color)
        context.draw(resolved, at: p)
    }
}
