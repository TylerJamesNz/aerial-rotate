import SwiftUI

/// Feature 5: schedule one or more daily rotation times. The top half is a live
/// "celestial dial" (a high-tech horizon clock: sun and moon ride a neon arc as
/// the day turns, with a marker per scheduled time); the bottom half is the
/// editor (a digital picker per time, the actual source of truth, plus +/−).
///
/// Apply is automatic and debounced: any add, remove, or picker edit rewrites
/// the user LaunchAgent's `StartCalendarInterval` and reloads it ~0.4s later, so
/// scrubbing a picker coalesces into one `launchctl` reload instead of one per
/// tick. No "Set" button, no password (the agent plist is user-owned).
///
/// The struct name stays `SunMoonClock` so `MainWindow` needs no change.
struct SunMoonClock: View {
    @EnvironmentObject private var state: AppState

    @State private var status: String = ""
    @State private var busy = false
    /// The pending debounced apply; cancelled and rescheduled on each edit so a
    /// burst of picker changes collapses to a single launchctl reload.
    @State private var pendingApply: DispatchWorkItem?
    /// Gate the disk-driven first sync so opening the window doesn't auto-apply.
    @State private var armed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rotation times").font(.headline)

            TimelineView(.periodic(from: .now, by: 60)) { ctx in
                CelestialDial(now: ctx.date, times: state.rotationTimes)
                    .frame(height: 150)
                    .frame(maxWidth: .infinity)
            }

            VStack(spacing: 8) {
                ForEach(state.rotationTimes) { rt in
                    HStack(spacing: 10) {
                        Image(systemName: "clock").foregroundStyle(.secondary)
                        DatePicker("", selection: timeBinding(for: rt), displayedComponents: .hourAndMinute)
                            .datePickerStyle(.stepperField)
                            .labelsHidden()
                            // Force 12-hour AM/PM in the field regardless of the
                            // system's 24-hour setting, so the picker matches the
                            // AM/PM labels everywhere else in the app.
                            .environment(\.locale, Locale(identifier: "en_US"))
                        Spacer()
                        Button(role: .destructive) { remove(rt) } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                        .help("Remove this time")
                    }
                }
            }

            HStack {
                Button { addTime() } label: { Label("Add time", systemImage: "plus.circle.fill") }
                    .buttonStyle(.borderless)
                Spacer()
                if busy {
                    ProgressView().controlSize(.small)
                }
            }

            if !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        // Auto-apply on any schedule edit. Gated by `armed` so the disk-driven
        // first refresh that populates the list on window open doesn't fire a
        // redundant reschedule.
        .onChange(of: state.rotationTimes) { _, _ in
            guard armed else { return }
            scheduleApply()
        }
        .onAppear {
            // Arm a beat after appear so the initial refresh's assignment lands
            // first. Any genuinely new on-disk schedule that arrives later writes
            // itself back once (idempotent), which is harmless.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { armed = true }
        }
    }

    // MARK: - editor actions

    /// A `Binding<Date>` for a row's `DatePicker`, keyed by the time's id so an
    /// edit writes back into the live `rotationTimes` array (which drives the
    /// auto-apply). Reads/writes only the hour and minute.
    private func timeBinding(for rt: RotationTime) -> Binding<Date> {
        Binding<Date>(
            get: {
                let current = state.rotationTimes.first { $0.id == rt.id } ?? rt
                var c = DateComponents()
                c.hour = current.hour
                c.minute = current.minute
                return Calendar.current.date(from: c) ?? Date()
            },
            set: { newDate in
                guard let i = state.rotationTimes.firstIndex(where: { $0.id == rt.id }) else { return }
                let c = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                state.rotationTimes[i].hour = c.hour ?? 0
                state.rotationTimes[i].minute = c.minute ?? 0
            }
        )
    }

    private func addTime() {
        // Default to the next round hour so a fresh row is rarely a duplicate.
        let h = ((Calendar.current.component(.hour, from: Date())) + 1) % 24
        state.rotationTimes.append(RotationTime(hour: h, minute: 0))
    }

    private func remove(_ rt: RotationTime) {
        state.rotationTimes.removeAll { $0.id == rt.id }
    }

    // MARK: - debounced auto-apply

    private func scheduleApply() {
        pendingApply?.cancel()
        let work = DispatchWorkItem { applyNow() }
        pendingApply = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func applyNow() {
        let times = state.rotationTimes
        busy = true
        // launchctl reload can take a moment; keep it off the main runloop so the
        // picker stays responsive, then hop back for status + refresh.
        DispatchQueue.global(qos: .userInitiated).async {
            let result = DaemonScheduler.reschedule(times: times)
            DispatchQueue.main.async {
                busy = false
                switch result {
                case .success:
                    status = times.isEmpty
                        ? "No rotations scheduled."
                        : "Rescheduled: \(Format.timeList(times))"
                    state.refresh()
                case .failure(let msg):
                    status = "Failed: \(msg)"
                }
            }
        }
    }
}

/// The live horizon clock. A neon upper arc is the daylight track; a horizon line
/// runs across the middle; the sun and moon ride the full ring (offset 12h), the
/// one above the horizon highlighted, the one below dimmed. A notch per scheduled
/// time sits at its position on the ring. `now` advances via the parent's
/// `TimelineView`, so the bodies glide without manual refresh.
private struct CelestialDial: View {
    let now: Date
    let times: [RotationTime]

    var body: some View {
        Canvas { context, size in
            let R = min(size.width / 2, size.height / 2) * 0.84
            let cx = size.width / 2
            let cy = size.height / 2
            let center = CGPoint(x: cx, y: cy)

            // Faint full ring (the night side of the cycle).
            let ring = Path(ellipseIn: CGRect(x: cx - R, y: cy - R, width: 2 * R, height: 2 * R))
            context.stroke(ring, with: .color(.secondary.opacity(0.18)), lineWidth: 1)

            // Bright upper arc = daylight track, neon gradient left→top→right.
            var arc = Path()
            arc.addArc(center: center, radius: R,
                       startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            let neon = Gradient(colors: [
                Color(red: 0.20, green: 0.55, blue: 0.95),   // dawn (left)
                Color(red: 0.65, green: 0.95, blue: 1.00),   // noon (top)
                Color(red: 0.55, green: 0.35, blue: 0.95),   // dusk (right)
            ])
            context.stroke(
                arc,
                with: .linearGradient(neon,
                                      startPoint: CGPoint(x: cx - R, y: cy),
                                      endPoint: CGPoint(x: cx + R, y: cy)),
                style: StrokeStyle(lineWidth: 3, lineCap: .round))

            // Horizon line across the full width.
            var horizon = Path()
            horizon.move(to: CGPoint(x: 6, y: cy))
            horizon.addLine(to: CGPoint(x: size.width - 6, y: cy))
            context.stroke(horizon, with: .color(.secondary.opacity(0.35)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

            // Fine tick graduations every hour around the upper arc; cardinal
            // hours get monospaced 12-hour labels (6a / 12p / 6p on the track).
            for hour in stride(from: 0, through: 24, by: 1) {
                let sf = Double(hour) / 24.0
                let p = point(sf, R: R, cx: cx, cy: cy)
                guard p.y <= cy + 0.5 else { continue }   // upper arc + horizon only
                let isCardinal = (hour % 6 == 0)
                let inner = pointAt(sf, radius: R - (isCardinal ? 7 : 4), cx: cx, cy: cy)
                var tick = Path()
                tick.move(to: inner)
                tick.addLine(to: p)
                context.stroke(tick, with: .color(.secondary.opacity(isCardinal ? 0.6 : 0.3)),
                               lineWidth: isCardinal ? 1.5 : 1)
                if isCardinal && hour != 0 && hour != 24 {
                    let lp = pointAt(sf, radius: R + 11, cx: cx, cy: cy)
                    let label = Text(Format.hour12Compact(hour))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                    context.draw(label, at: lp)
                }
            }

            // Scheduled-time markers: a glowing notch per time, bright above the
            // horizon, dimmed below, each with a small caption just outside.
            for t in times {
                let sf = (Double(t.hour) * 60 + Double(t.minute)) / 1440.0
                let p = point(sf, R: R, cx: cx, cy: cy)
                let up = p.y <= cy
                let dot = Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
                context.fill(dot, with: .color(up ? .cyan : .secondary.opacity(0.5)))
                context.stroke(dot, with: .color(.white.opacity(up ? 0.9 : 0.3)), lineWidth: 1)
                let cap = pointAt(sf, radius: R + (up ? 22 : 16), cx: cx, cy: cy)
                let label = Text(Format.time12Compact(t))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(up ? Color.cyan : .secondary)
                context.draw(label, at: cap)
            }

            // Sun and moon ride the ring 12h apart; the one above the horizon is
            // lit (with a glow), the one below is dimmed.
            let dayFraction = fractionOfDay(now)
            let sun = point(dayFraction, R: R, cx: cx, cy: cy)
            let moon = point((dayFraction + 0.5).truncatingRemainder(dividingBy: 1), R: R, cx: cx, cy: cy)
            drawBody(context, "sun.max.fill", at: sun, up: sun.y <= cy, color: .orange)
            drawBody(context, "moon.fill", at: moon, up: moon.y <= cy, color: .indigo)
        }
    }

    // MARK: - geometry

    /// Fraction of the day in [0,1); 0 = 00:00, 0.5 = noon.
    private func fractionOfDay(_ date: Date) -> Double {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return Double((c.hour ?? 0) * 60 + (c.minute ?? 0)) / 1440.0
    }

    /// Position on the ring for a day-fraction. Noon sits at top, midnight at
    /// bottom, 06:00 on the left horizon, 18:00 on the right: `theta = 3π/2 −
    /// 2π·sf`, screen y inverted.
    private func point(_ sf: Double, R: CGFloat, cx: CGFloat, cy: CGFloat) -> CGPoint {
        pointAt(sf, radius: R, cx: cx, cy: cy)
    }

    private func pointAt(_ sf: Double, radius: CGFloat, cx: CGFloat, cy: CGFloat) -> CGPoint {
        let theta = (3 * Double.pi / 2) - 2 * Double.pi * sf
        let x = Double(cx) + Double(radius) * cos(theta)
        let y = Double(cy) - Double(radius) * sin(theta)
        return CGPoint(x: x, y: y)
    }

    private func drawBody(_ context: GraphicsContext, _ name: String, at p: CGPoint, up: Bool, color: Color) {
        if up {
            // soft glow halo
            let glow = Path(ellipseIn: CGRect(x: p.x - 13, y: p.y - 13, width: 26, height: 26))
            context.fill(glow, with: .color(color.opacity(0.22)))
        }
        let image = Image(systemName: name)
        var resolved = context.resolve(image)
        resolved.shading = .color(up ? color : color.opacity(0.35))
        context.draw(resolved, at: p)
    }
}
