import SwiftUI

/// Feature 5: schedule one or more daily rotation times. The top half is a live
/// "celestial dial" (a high-tech horizon clock: sun and moon ride a neon arc as
/// the day turns, with a marker per scheduled time); the bottom half is the
/// editor (a 15-minute-notched slider per time, the actual source of truth, plus
/// an Add control). Dragging a slider glides its dot around the dial live; the
/// list re-sorts chronologically when the slider is released.
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
                        // Live read-out of this row's time. Monospaced and fixed
                        // width so the slider track to its right doesn't jitter as
                        // the digits change while scrubbing.
                        Text(Format.time12(rt))
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 78, alignment: .leading)
                        // A custom day track: 24 clean white hour notches (labelled
                        // at the 6-hour cardinals) with a draggable thumb. Dragging
                        // writes straight into `rotationTimes`, so the matching dot
                        // glides around the dial live; the list is only re-sorted when
                        // the drag ends, so the thumb never jumps out from under it.
                        TimeSlider(minutes: minuteBinding(for: rt), onRelease: sortTimes)
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

    /// A `Binding<Double>` (minutes since midnight) for a row's slider, keyed by
    /// the time's id so a drag writes back into the live `rotationTimes` array
    /// (which drives both the dial and the debounced auto-apply). The slider's
    /// 15-minute step means the written value is always a clean quarter-hour.
    private func minuteBinding(for rt: RotationTime) -> Binding<Double> {
        Binding<Double>(
            get: {
                let current = state.rotationTimes.first { $0.id == rt.id } ?? rt
                return Double(current.hour * 60 + current.minute)
            },
            set: { newValue in
                guard let i = state.rotationTimes.firstIndex(where: { $0.id == rt.id }) else { return }
                let mins = Int(newValue.rounded())
                state.rotationTimes[i].hour = mins / 60
                state.rotationTimes[i].minute = mins % 60
            }
        )
    }

    /// Re-order the rows chronologically. Called when a slider is released, not
    /// during the drag, so the thumb under the cursor never jumps mid-scrub.
    private func sortTimes() {
        // Animate so the rows visibly slide into their new chronological slots
        // when a drag ends, rather than snapping.
        withAnimation(.easeInOut(duration: 0.3)) {
            state.rotationTimes.sort()
        }
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
                    // No success read-out: the scheduled times are already listed
                    // in the rows above, so echoing them here was pure duplication.
                    // The empty-state note still earns its place.
                    status = times.isEmpty ? "No rotations scheduled." : ""
                    state.refresh()
                case .failure(let msg):
                    status = "Failed: \(msg)"
                }
            }
        }
    }
}

/// A custom day track for one rotation time. A thin baseline carries 24 evenly
/// spaced white hour notches; the 6-hour cardinals are taller and labelled
/// (12a / 6a / 12p / 6p). A white thumb marks the current time. Dragging snaps to
/// 15 minutes and writes back through `minutes` (so the dial dot tracks live);
/// `onRelease` fires once when the drag ends (the caller re-sorts the list there).
private struct TimeSlider: View {
    @Binding var minutes: Double
    var onRelease: () -> Void

    private let dayMinutes = 1440.0
    private let step = 15.0
    private let notchY: CGFloat = 11
    private let thumbR: CGFloat = 7
    /// Horizontal breathing room so the end notches' centred labels ("12 AM" at
    /// the far left, the last cardinal near the right) don't clip the track edge.
    private let hPad: CGFloat = 22

    var body: some View {
        GeometryReader { geo in
            let usable = max(geo.size.width - 2 * hPad, 1)
            let frac = min(max(minutes / dayMinutes, 0), 1)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    let span = max(size.width - 2 * hPad, 1)
                    var base = Path()
                    base.move(to: CGPoint(x: hPad, y: notchY))
                    base.addLine(to: CGPoint(x: size.width - hPad, y: notchY))
                    ctx.stroke(base, with: .color(.white.opacity(0.20)), lineWidth: 1)

                    // 0...24 so the day is bookended: a "12 AM" cardinal line at the
                    // far left (00:00) and a matching one at the far right (24:00, the
                    // next midnight), instead of the track trailing off after 11 PM.
                    for h in 0...24 {
                        let x = hPad + CGFloat(h) / 24.0 * span
                        let key = h % 6 == 0
                        let half: CGFloat = key ? 8 : 4
                        var tick = Path()
                        tick.move(to: CGPoint(x: x, y: notchY - half))
                        tick.addLine(to: CGPoint(x: x, y: notchY + half))
                        ctx.stroke(tick, with: .color(.white.opacity(key ? 0.9 : 0.45)),
                                   lineWidth: key ? 1.5 : 1)
                        if key {
                            let label = Text(hourLabel(h == 24 ? 0 : h))
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.7))
                            ctx.draw(label, at: CGPoint(x: x, y: notchY + half + 9))
                        }
                    }
                }
                Circle()
                    .fill(.white)
                    .frame(width: thumbR * 2, height: thumbR * 2)
                    .shadow(color: .black.opacity(0.4), radius: 1.5, y: 0.5)
                    .position(x: hPad + CGFloat(frac) * usable, y: notchY)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let raw = Double((v.location.x - hPad) / usable) * dayMinutes
                        let snapped = (raw / step).rounded() * step
                        minutes = min(max(snapped, 0), dayMinutes - step)
                    }
                    .onEnded { _ in onRelease() }
            )
        }
        .frame(height: 36)
    }

    /// 12-hour cardinal label with the full meridiem: "12 AM", "6 AM", "12 PM",
    /// "6 PM" (same form as the dial's hour labels).
    private func hourLabel(_ h: Int) -> String {
        Format.hour12(h)
    }
}

/// The live rotating clock. The whole ring is offset so the current time is pinned
/// to a bold white notch at the very top; everything else rides the ring and turns
/// past that notch as the day advances. The sun sits at noon and the moon at
/// midnight (half a ring apart), so each climbs to the top at its hour, the body in
/// the upper half lit, the other dimmed. A neon band marks the daylight half, a dot
/// per scheduled time sits at its offset from now, and "12 PM" is the one kept
/// label, riding with the sun. `now` advances via the parent's `TimelineView`, so
/// the ring glides without manual refresh.
private struct CelestialDial: View {
    let now: Date
    let times: [RotationTime]

    var body: some View {
        Canvas { context, size in
            let R = min(size.width / 2, size.height / 2) * 0.60
            let cx = size.width / 2
            let cy = size.height / 2

            let nowFrac = fractionOfDay(now)
            // Rotate the whole dial so the current time is pinned to the top. A clock
            // fraction `sf` (0 = midnight, 0.5 = noon) is mapped through `disp` before
            // being turned into a ring point, and `disp(nowFrac)` lands at 0.5, which
            // `pointAt` draws at the very top. Everything that rides the ring (sun,
            // moon, scheduled dots, the 12 PM anchor) rotates together as the day
            // turns; only the bold "now" notch is painted at a fixed top.
            func disp(_ sf: Double) -> Double { sf - nowFrac + 0.5 }

            // Dark "sky" backdrop card so the bright ring elements read against the
            // window's light gray, regardless of system light/dark mode.
            let cardRect = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
            let card = Path(roundedRect: cardRect, cornerRadius: 14)
            let sky = Gradient(colors: [
                Color(red: 0.10, green: 0.13, blue: 0.23),   // upper sky
                Color(red: 0.05, green: 0.06, blue: 0.12),   // lower sky
            ])
            context.fill(
                card,
                with: .linearGradient(sky,
                                      startPoint: CGPoint(x: cx, y: cardRect.minY),
                                      endPoint: CGPoint(x: cx, y: cardRect.maxY)))
            context.stroke(card, with: .color(.white.opacity(0.08)), lineWidth: 1)

            // One thin, consistent ring whose colour shimmers around the radius by
            // time of day: deep indigo at midnight, cool blue at dawn, bright ice at
            // noon, violet at dusk. Drawn as many short segments (positions via `disp`)
            // so the colour wheel turns with the dial and stays aligned to the sun and
            // moon, rather than as two separate day/night bands.
            let ringSegs = 96
            for i in 0..<ringSegs {
                let sf0 = Double(i) / Double(ringSegs)
                let sf1 = Double(i + 1) / Double(ringSegs)
                let p0 = pointAt(disp(sf0), radius: R, cx: cx, cy: cy)
                let p1 = pointAt(disp(sf1), radius: R, cx: cx, cy: cy)
                var seg = Path()
                seg.move(to: p0)
                seg.addLine(to: p1)
                context.stroke(seg, with: .color(timeOfDayColor(sf0)),
                               style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }

            // Faint hour graduations the whole way round so the gaps between slots are
            // easy to read; the 6-hour cardinals are a touch taller. No hour labels:
            // the sun marks noon, the moon midnight, the bold notch the top is now.
            for hour in 0..<24 {
                let sf = Double(hour) / 24.0
                let cardinal = hour % 6 == 0
                let outer = pointAt(disp(sf), radius: R, cx: cx, cy: cy)
                let inner = pointAt(disp(sf), radius: R - (cardinal ? 7 : 4), cx: cx, cy: cy)
                var tick = Path()
                tick.move(to: inner)
                tick.addLine(to: outer)
                context.stroke(tick, with: .color(.white.opacity(cardinal ? 0.5 : 0.22)),
                               lineWidth: cardinal ? 1.4 : 1)
            }

            // Scheduled-time notches ride the ring at their offset from now: a glowing
            // dot per time, brighter on the half nearer "now" (the upper half), each
            // with a caption just outside the ring.
            for t in times {
                let sf = (Double(t.hour) * 60 + Double(t.minute)) / 1440.0
                let d = disp(sf)
                let p = pointAt(d, radius: R, cx: cx, cy: cy)
                let up = p.y <= cy
                let dot = Path(ellipseIn: CGRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9))
                context.fill(dot, with: .color(up ? .cyan : .cyan.opacity(0.5)))
                context.stroke(dot, with: .color(.white.opacity(up ? 0.95 : 0.5)), lineWidth: 1.2)
                let cap = clamped(pointAt(d, radius: R + 20, cx: cx, cy: cy), in: size, inset: 16)
                let label = Text(Format.time12(t))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(up ? Color.cyan : .white.opacity(0.65))
                context.draw(label, at: cap)
            }

            // Sun rides at noon, moon at midnight, half a ring apart and on the same
            // layer; each climbs to the top at its hour, lit with a glow in the upper
            // half, dimmed in the lower. The sun is the larger body but no longer
            // floats above everything.
            let sun = pointAt(disp(0.5), radius: R, cx: cx, cy: cy)
            let moon = pointAt(disp(0.0), radius: R, cx: cx, cy: cy)
            drawBody(context, "moon.fill", at: moon, up: moon.y <= cy, color: Color(white: 0.92), glow: .white)
            // The sun is always lit (never dimmed below the horizon) so it stays a
            // solid, foreground body rather than a faint shape behind the ring.
            drawBody(context, "sun.max.fill", at: sun, up: sun.y <= cy,
                     color: .orange, glow: .orange, glyph: 30, haloR: 26, alwaysLit: true)

            // The single kept hour label: "12 PM" riding just inside the ring with the
            // sun, the one absolute anchor on an otherwise relative dial.
            let noonLabelP = clamped(pointAt(disp(0.5), radius: R - 18, cx: cx, cy: cy), in: size, inset: 14)
            let noonLabel = Text("12 PM")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.8))
            context.draw(noonLabel, at: noonLabelP)

            // The fixed "now" marker: a bold white notch at the very top with a soft
            // glow, and the current time spelled out above it. Everything else slides
            // past this; it never moves.
            var nowTick = Path()
            nowTick.move(to: CGPoint(x: cx, y: cy - R - 7))
            nowTick.addLine(to: CGPoint(x: cx, y: cy - R + 11))
            context.stroke(nowTick, with: .color(.white.opacity(0.35)), lineWidth: 6)
            context.stroke(nowTick, with: .color(.white), lineWidth: 2.5)
            let nowComps = Calendar.current.dateComponents([.hour, .minute], from: now)
            let nowRT = RotationTime(hour: nowComps.hour ?? 0, minute: nowComps.minute ?? 0)
            // Current time spelled out in the centre of the circle (the top notch
            // marks where "now" sits on the ring; this is the readout).
            let nowText = Text(Format.time12(nowRT))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
            context.draw(nowText, at: CGPoint(x: cx, y: cy))
        }
    }

    // MARK: - colour

    /// A cool "time of day" colour for a clock fraction (0 and 1 = midnight, 0.5 =
    /// noon): deep indigo at midnight, cool blue at dawn, bright ice at noon, violet
    /// at dusk. Used to shimmer the ring around its radius and read day vs night.
    private func timeOfDayColor(_ sf: Double) -> Color {
        let stops: [(at: Double, rgb: (Double, Double, Double))] = [
            (0.00, (0.20, 0.22, 0.45)),   // midnight indigo
            (0.25, (0.25, 0.55, 0.82)),   // dawn blue
            (0.50, (0.68, 0.95, 1.00)),   // noon ice
            (0.75, (0.48, 0.40, 0.82)),   // dusk violet
            (1.00, (0.20, 0.22, 0.45)),   // midnight indigo
        ]
        let f = sf - floor(sf)
        var lo = stops[0], hi = stops[stops.count - 1]
        for i in 0..<(stops.count - 1) where f >= stops[i].at && f <= stops[i + 1].at {
            lo = stops[i]; hi = stops[i + 1]; break
        }
        let t = (f - lo.at) / max(hi.at - lo.at, 0.0001)
        return Color(red: lo.rgb.0 + (hi.rgb.0 - lo.rgb.0) * t,
                     green: lo.rgb.1 + (hi.rgb.1 - lo.rgb.1) * t,
                     blue: lo.rgb.2 + (hi.rgb.2 - lo.rgb.2) * t)
    }

    // MARK: - geometry

    /// Fraction of the day in [0,1); 0 = 00:00, 0.5 = noon.
    private func fractionOfDay(_ date: Date) -> Double {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return Double((c.hour ?? 0) * 60 + (c.minute ?? 0)) / 1440.0
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

    private func drawBody(_ context: GraphicsContext, _ name: String, at p: CGPoint, up: Bool,
                          color: Color, glow: Color, glyph: CGFloat = 18, haloR: CGFloat = 16,
                          alwaysLit: Bool = false) {
        let lit = up || alwaysLit
        if lit {
            // Soft radial halo so the body pops off the dark sky: bright at the
            // centre, fading to nothing at the rim. The moon uses a white glow so
            // it stands out as much as the sun's warm one.
            let halo = Path(ellipseIn: CGRect(x: p.x - haloR, y: p.y - haloR, width: 2 * haloR, height: 2 * haloR))
            context.fill(halo, with: .radialGradient(
                Gradient(colors: [glow.opacity(0.7), glow.opacity(0)]),
                center: p, startRadius: 0, endRadius: haloR))
        }
        let image = Image(systemName: name)
        var resolved = context.resolve(image)
        resolved.shading = .color(lit ? color : color.opacity(0.4))
        // Draw into an explicit rect so the glyph can be scaled up (the foreground
        // sun is larger than the moon).
        let rect = CGRect(x: p.x - glyph / 2, y: p.y - glyph / 2, width: glyph, height: glyph)
        context.draw(resolved, in: rect)
    }
}
