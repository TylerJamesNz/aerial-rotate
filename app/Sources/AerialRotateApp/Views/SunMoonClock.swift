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
                    .frame(height: 196)
                    .frame(maxWidth: .infinity)
            }

            VStack(spacing: 0) {
                ForEach(Array(state.rotationTimes.enumerated()), id: \.element.id) { index, rt in
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
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(index.isMultiple(of: 2) ? Color.primary.opacity(0.05) : Color.clear)
                }
            }

            HStack(spacing: 10) {
                if busy {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                // Add control, right-aligned at the end of the list (the plus sits
                // in the same column as each row's delete button), with the label
                // to the left of the icon.
                Button { addTime() } label: {
                    HStack(spacing: 4) {
                        Text("Add time")
                        Image(systemName: "plus.circle.fill")
                    }
                }
                .buttonStyle(.borderless)
                .help("Add a time")
            }
            .padding(.horizontal, 8)

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
            let R = min(size.width / 2, size.height / 2) * 0.70
            let cx = size.width / 2
            let cy = size.height / 2
            let center = CGPoint(x: cx, y: cy)

            // Dark "sky" backdrop card: a rounded rect filling the canvas with a
            // night-sky gradient. The window behind the dial is light gray, which
            // washed out the neon arc, ticks, and captions; a dark card makes every
            // bright element (cyan dots, white ticks, neon track) read with high
            // contrast regardless of system light/dark mode.
            let cardRect = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
            let card = Path(roundedRect: cardRect, cornerRadius: 14)
            let sky = Gradient(colors: [
                Color(red: 0.10, green: 0.13, blue: 0.23),   // upper sky
                Color(red: 0.05, green: 0.06, blue: 0.12),   // horizon/ground
            ])
            context.fill(
                card,
                with: .linearGradient(sky,
                                      startPoint: CGPoint(x: cx, y: cardRect.minY),
                                      endPoint: CGPoint(x: cx, y: cardRect.maxY)))
            context.stroke(card, with: .color(.white.opacity(0.08)), lineWidth: 1)

            // Faint full ring (the night side of the cycle).
            let ring = Path(ellipseIn: CGRect(x: cx - R, y: cy - R, width: 2 * R, height: 2 * R))
            context.stroke(ring, with: .color(.white.opacity(0.14)), lineWidth: 1)

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
                style: StrokeStyle(lineWidth: 3.5, lineCap: .round))

            // Horizon line across the full width.
            var horizon = Path()
            horizon.move(to: CGPoint(x: 6, y: cy))
            horizon.addLine(to: CGPoint(x: size.width - 6, y: cy))
            context.stroke(horizon, with: .color(.white.opacity(0.28)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

            // Fine tick graduations every hour around the upper arc; cardinal
            // hours get full 12-hour labels (6 AM / 12 PM / 6 PM on the track).
            for hour in stride(from: 0, through: 24, by: 1) {
                let sf = Double(hour) / 24.0
                let p = point(sf, R: R, cx: cx, cy: cy)
                guard p.y <= cy + 0.5 else { continue }   // upper arc + horizon only
                let isCardinal = (hour % 6 == 0)
                let inner = pointAt(sf, radius: R - (isCardinal ? 7 : 4), cx: cx, cy: cy)
                var tick = Path()
                tick.move(to: inner)
                tick.addLine(to: p)
                context.stroke(tick, with: .color(.white.opacity(isCardinal ? 0.8 : 0.45)),
                               lineWidth: isCardinal ? 1.6 : 1)
                if isCardinal && hour != 0 && hour != 24 {
                    let lp = clamped(pointAt(sf, radius: R + 26, cx: cx, cy: cy), in: size, inset: 14)
                    let label = Text(Format.hour12(hour))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.9))
                    context.draw(label, at: lp)
                }
            }

            // Scheduled-time markers: a glowing notch per time, bright above the
            // horizon, dimmed below, each with a small caption just outside.
            for t in times {
                let sf = (Double(t.hour) * 60 + Double(t.minute)) / 1440.0
                let p = point(sf, R: R, cx: cx, cy: cy)
                let up = p.y <= cy
                let dot = Path(ellipseIn: CGRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9))
                context.fill(dot, with: .color(up ? .cyan : .white.opacity(0.45)))
                context.stroke(dot, with: .color(.white.opacity(up ? 0.95 : 0.4)), lineWidth: 1.2)
                let cap = clamped(pointAt(sf, radius: R + (up ? 22 : 18), cx: cx, cy: cy), in: size, inset: 16)
                let label = Text(Format.time12(t))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(up ? Color.cyan : .white.opacity(0.6))
                context.draw(label, at: cap)
            }

            // Sun and moon ride the ring 12h apart; the one above the horizon is
            // lit (with a glow), the one below is dimmed.
            let dayFraction = fractionOfDay(now)
            let sun = point(dayFraction, R: R, cx: cx, cy: cy)
            let moon = point((dayFraction + 0.5).truncatingRemainder(dividingBy: 1), R: R, cx: cx, cy: cy)
            drawBody(context, "sun.max.fill", at: sun, up: sun.y <= cy, color: .orange, glow: .orange)
            drawBody(context, "moon.fill", at: moon, up: moon.y <= cy, color: Color(white: 0.92), glow: .white)
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

    /// Keep a label's draw point inside the canvas by `inset` on every edge, so
    /// the now-larger captions (a time scheduled near noon sits at the very top,
    /// near 06:00/18:00 at the sides) never clip the card edge.
    private func clamped(_ p: CGPoint, in size: CGSize, inset: CGFloat) -> CGPoint {
        CGPoint(x: min(max(p.x, inset), size.width - inset),
                y: min(max(p.y, inset), size.height - inset))
    }

    private func drawBody(_ context: GraphicsContext, _ name: String, at p: CGPoint, up: Bool, color: Color, glow: Color) {
        if up {
            // Soft radial halo so the body pops off the dark sky: bright at the
            // centre, fading to nothing at the rim. The moon uses a white glow so
            // it stands out as much as the sun's warm one.
            let r: CGFloat = 16
            let halo = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
            context.fill(halo, with: .radialGradient(
                Gradient(colors: [glow.opacity(0.6), glow.opacity(0)]),
                center: p, startRadius: 0, endRadius: r))
        }
        let image = Image(systemName: name)
        var resolved = context.resolve(image)
        resolved.shading = .color(up ? color : color.opacity(0.35))
        context.draw(resolved, at: p)
    }
}
