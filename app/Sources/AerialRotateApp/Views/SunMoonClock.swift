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
    /// Fast-forward preview: when on, the dial races the day and cycles the weather
    /// instead of tracking live time and the real local condition.
    @State private var simulating = false
    /// Frame-persistent precipitation accumulator passed into the dial so rain/snow
    /// can ease in and dissipate across redraws (a reference type so mutating it from
    /// the Canvas closure doesn't churn SwiftUI state).
    @State private var precipFade = PrecipFade()
    /// Frame-persistent cloud population passed into the dial so condition changes ease
    /// by drift instead of popping clouds in and out (a reference type for the same
    /// reason as `precipFade`).
    @State private var cloudField = CloudField()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Rotation times").font(.headline)
                Spacer()
                // Fast-forward preview toggle, right-aligned like the catalog's refresh
                // button. Off, it's a fast-forward glyph; tapping races the day and
                // cycles through every sky condition so all phases can be seen at once.
                // While the preview runs the icon turns into a clock; tapping the clock
                // returns the dial to live, standard time.
                Button { simulating.toggle() } label: {
                    Image(systemName: simulating ? "clock" : "forward.fill")
                }
                .buttonStyle(HoverIconButtonStyle())
                .help(simulating ? "Return to standard time" : "Fast-forward the sky preview")
            }

            // 10fps ticks keep the clouds, stars and rain animating smoothly in both
            // live and preview modes; the preview toggle changes the time mapping inside
            // the dial, not this cadence.
            TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
                CelestialDial(now: ctx.date, times: state.rotationTimes,
                              condition: state.weather.condition, simulating: simulating,
                              fade: precipFade, clouds: cloudField)
                    .frame(height: 140)
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
                        .buttonStyle(HoverIconButtonStyle())
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
                .buttonStyle(SoftButtonStyle())
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
        // Start at the next round hour, then walk forward to the first hour with
        // no existing :00 slot, so a fresh row never lands on a duplicate and
        // silently collapses. The operator drags it to the time they actually
        // want; this only guarantees it appears.
        let start = ((Calendar.current.component(.hour, from: Date())) + 1) % 24
        let taken = Set(state.rotationTimes.filter { $0.minute == 0 }.map(\.hour))
        let h = (0..<24).map { (start + $0) % 24 }.first { !taken.contains($0) } ?? start
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

/// The live timeline. A solid horizontal line runs left (past) to right (future)
/// with "now" pinned to a bold white notch at the centre, the current time read just
/// above it, and a glowing sky icon above that. A dot per scheduled time rides the
/// line at its offset from now, so as the day advances the dots stream from right to
/// left past the centre. The line's colour shimmers by time of day. A line is far
/// easier to read and to place times on than the old circular dial. `now` advances
/// via the parent's `TimelineView`, so it glides without manual refresh.
/// Frame-persistent precipitation state. Held as a reference on the parent view and
/// passed into the dial so the Canvas render closure can ease `level` toward the
/// current condition every frame (rain/snow ramp in, then thin out and dissipate when
/// it clears) without writing SwiftUI state. `snow` records the active precip type so
/// the correct particle keeps drawing through the fade-out, and `last` carries the
/// previous wall timestamp for the per-frame easing step.
final class PrecipFade {
    var level: Double = 0
    var snow: Bool = false
    var last: Double = 0
}

/// Frame-persistent cloud population. A fixed pool of slots, each drifting left to
/// right; the dial enables as many as the current condition wants. A newly-wanted slot
/// re-spawns at the left edge and drifts in; a no-longer-wanted slot keeps drifting
/// until it slides off the right edge, then goes dormant, so condition changes never
/// pop a cloud in or out. `density` is frozen while a slot is leaving so a clear-up
/// doesn't blink the departing clouds. Held as a reference on the parent view so the
/// Canvas closure can mutate it each frame without churning SwiftUI state.
final class CloudField {
    struct Slot {
        var phaseBase: Double = 0   // drift phase; reset on re-spawn so x starts off the left edge
        var visible = false
        var leaving = false         // wanted off but still drifting clear of the right edge
        var density: Double = 0     // last active density, held through the leaving drift
    }
    var slots = [Slot](repeating: Slot(), count: 5)
    var initialized = false
}

private struct CelestialDial: View {
    let now: Date
    let times: [RotationTime]
    /// Current local sky condition (from `WeatherStore`); drives the atmosphere
    /// layer (stars, clouds, rain/snow) drawn over the time-of-day gradient.
    let condition: SkyCondition
    /// Preview mode: race the day and cycle every condition instead of tracking
    /// the live time of day and the real local weather.
    let simulating: Bool
    /// Frame-persistent precipitation accumulator (owned by the parent view) so
    /// rain/snow can ease in and dissipate across frames instead of cutting out.
    let fade: PrecipFade
    /// Frame-persistent cloud population (owned by the parent view) so condition
    /// changes ease by drift instead of popping clouds in and out.
    let clouds: CloudField

    var body: some View {
        Canvas { context, size in
            let cx = size.width / 2
            let lineInset: CGFloat = 3   // keep the rounded line ends inside the card edge
            let usable = size.width - 2 * lineInset
            // Vertically centre the whole stack in the available height. It runs from the
            // sky icon's glyph top (71pt above the line: 60 to the icon centre + 11 for its
            // top half) down to the time captions (~25pt below the line), so the stack's
            // midpoint sits 23pt above the line. Putting that midpoint at the centre leaves
            // equal space above the icon and below the captions.
            let lineY = size.height / 2 + 23
            // Live mode tracks the real time of day. Preview mode races the whole day
            // every ~20s so every phase (night, dawn, noon, dusk) can be eyeballed.
            let nowFrac = simulating
                ? (now.timeIntervalSinceReferenceDate / 20).truncatingRemainder(dividingBy: 1)
                : fractionOfDay(now)

            // Map a clock fraction `sf` (0 = midnight, 0.5 = noon) to an x on the line.
            // The signed offset from now is wrapped to [-0.5, 0.5] (half a day either
            // side), so `sf == nowFrac` lands dead centre, +0.5 at the right edge (12h
            // ahead) and -0.5 at the left (12h behind). As `now` advances, every
            // element's offset shrinks then goes negative: it streams right to left
            // past the centre.
            func offset(_ sf: Double) -> Double {
                var o = sf - nowFrac
                o -= o.rounded()
                return o
            }
            func xFor(_ sf: Double) -> CGFloat { cx + CGFloat(offset(sf)) * usable }

            // Deep "sky" backdrop card with rounded corners so the bright line
            // elements read against the window's light gray, in either appearance.
            // The two gradient stops glide through the day (deep indigo night ->
            // plum dawn -> ocean-blue day -> amber sunset). Every anchor is kept
            // low-luminance on purpose so the light foreground keeps its contrast.
            let cardRect = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
            let card = Path(roundedRect: cardRect, cornerRadius: 14)
            let (skyUpper, skyLower) = skyColors(nowFrac)
            let sky = Gradient(colors: [skyUpper, skyLower])
            context.fill(
                card,
                with: .linearGradient(sky,
                                      startPoint: CGPoint(x: cx, y: cardRect.minY),
                                      endPoint: CGPoint(x: cx, y: cardRect.maxY)))
            context.stroke(card, with: .color(.white.opacity(0.08)), lineWidth: 1)

            // Live mode draws the real local condition. Preview mode cycles through
            // every condition (~20s each) so clouds, rain, snow and fog can all be seen.
            let cond: SkyCondition
            if simulating {
                let cycle: [SkyCondition] = [.clear, .partlyCloudy, .cloudy, .rain, .snow, .thunder, .fog]
                cond = cycle[Int(now.timeIntervalSinceReferenceDate / 20) % cycle.count]
            } else {
                cond = condition
            }

            // Ease the precipitation level toward the current condition (real wall-clock
            // seconds, so it behaves the same live or in fast-forward). Rain/snow ramps
            // up quickly (~0.6s) but fades out gently (~1.6s), so when the weather clears
            // the particles thin out and dissipate instead of cutting off instantly. The
            // accumulator lives on the parent view, so it survives each frame's redraw.
            let isPrecip = (cond == .rain || cond == .thunder || cond == .snow)
            if isPrecip { fade.snow = (cond == .snow) }
            let twall = now.timeIntervalSinceReferenceDate
            let dt = min(0.5, max(0, twall - fade.last))
            fade.last = twall
            let target = isPrecip ? 1.0 : 0.0
            let perSec = target > fade.level ? 1.6 : 0.6
            if target > fade.level { fade.level = min(target, fade.level + perSec * dt) }
            else { fade.level = max(target, fade.level - perSec * dt) }

            // Atmosphere layer: stars on clear/partly nights, drifting clouds when
            // overcast or foggy, falling streaks for rain/thunder, soft flakes for
            // snow. Clipped to the card and drawn under the timeline line so the
            // schedule stays readable on top of the weather.
            context.drawLayer { layer in
                layer.clip(to: card)
                drawAtmosphere(layer, rect: cardRect, nowFrac: nowFrac,
                               wall: twall, condition: cond,
                               precipLevel: fade.level, precipSnow: fade.snow,
                               clouds: clouds)
            }

            // The timeline itself: short segments across the usable width, each tinted
            // by the time of day at that point, so the colour streams with the line
            // (indigo midnight -> blue dawn -> ice noon -> violet dusk).
            let segs = 120
            for i in 0..<segs {
                let o0 = Double(i) / Double(segs) - 0.5
                let o1 = Double(i + 1) / Double(segs) - 0.5
                let x0 = cx + CGFloat(o0) * usable
                let x1 = cx + CGFloat(o1) * usable
                var seg = Path()
                seg.move(to: CGPoint(x: x0, y: lineY))
                seg.addLine(to: CGPoint(x: x1, y: lineY))
                context.stroke(seg, with: .color(timeOfDayColor(nowFrac + o0)),
                               style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }

            // Faint hour graduations along the line; the 6-hour cardinals taller.
            for hour in 0..<24 {
                let sf = Double(hour) / 24.0
                let x = xFor(sf)
                let cardinal = hour % 6 == 0
                let half: CGFloat = cardinal ? 7 : 4
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: lineY - half))
                tick.addLine(to: CGPoint(x: x, y: lineY + half))
                context.stroke(tick, with: .color(.white.opacity(cardinal ? 0.5 : 0.22)),
                               lineWidth: cardinal ? 1.4 : 1)
            }

            // Scheduled-time dots ride the line at their offset from now, each captioned
            // just below. They stay a constant grey whatever their distance from "now",
            // so sliding along the line never changes their colour.
            for t in times {
                let sf = (Double(t.hour) * 60 + Double(t.minute)) / 1440.0
                let x = xFor(sf)
                let dot = Path(ellipseIn: CGRect(x: x - 4.5, y: lineY - 4.5, width: 9, height: 9))
                context.fill(dot, with: .color(Color(white: 0.72)))
                context.stroke(dot, with: .color(.white.opacity(0.6)), lineWidth: 1.2)
                let cap = CGPoint(x: min(max(x, 18), size.width - 18), y: lineY + 18)
                let label = Text(Format.time12(t))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                context.draw(label, at: cap)
            }

            // The fixed "now" marker: a bold white notch through the centre of the
            // line, the current time (ticking with seconds) read just above it, and a
            // sky icon above that which cuts between night, sunrise, day and sunset as
            // the hours pass. Everything else streams past this; it never moves.
            var nowTick = Path()
            nowTick.move(to: CGPoint(x: cx, y: lineY - 13))
            nowTick.addLine(to: CGPoint(x: cx, y: lineY + 13))
            context.stroke(nowTick, with: .color(.white.opacity(0.35)), lineWidth: 6)
            context.stroke(nowTick, with: .color(.white), lineWidth: 2.5)

            // The centre clock shows live wall-clock time; in preview mode it reads the
            // simulated time-of-day so the read-out races along with the dial.
            let nowText: Text
            if simulating {
                let simSecs = Int(nowFrac * 86400)
                var simH = (simSecs / 3600) % 12; if simH == 0 { simH = 12 }
                nowText = Text(String(format: "%d:%02d:%02d%@", simH, (simSecs % 3600) / 60,
                                      simSecs % 60, simSecs < 43200 ? "AM" : "PM"))
            } else {
                nowText = Text(timeWithSeconds(now))
            }
            context.draw(nowText
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white), at: CGPoint(x: cx, y: lineY - 30))

            // Sky icon above the time, picked from the current hour so it cuts over
            // through the day: night moon, sunrise, daytime sun, sunset. Given the
            // same soft radial halo the sun and moon used to carry, so it reads as
            // the lit "current sky" floating over the timeline.
            let (iconName, iconColor) = skyIcon(nowFrac)
            drawBody(context, iconName, at: CGPoint(x: cx, y: lineY - 60),
                     up: true, color: iconColor, glow: iconColor,
                     glyph: 22, haloR: 18, alwaysLit: true)
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

    /// The card's two gradient stops (upper + lower) for a day fraction, gliding
    /// through four deep-toned phases: indigo night -> plum dawn -> ocean-blue day
    /// -> amber sunset, then back to night. Same wrap-around stop interpolation as
    /// `timeOfDayColor`. Every anchor is kept low-luminance (brightest channel
    /// ~0.34) so the light foreground keeps strong contrast at every point.
    private func skyColors(_ f: Double) -> (upper: Color, lower: Color) {
        // (at, upper rgb, lower rgb)
        let stops: [(at: Double, up: (Double, Double, Double), lo: (Double, Double, Double))] = [
            (0.00, (0.08, 0.09, 0.20), (0.03, 0.04, 0.10)),   // night indigo
            (0.27, (0.22, 0.12, 0.26), (0.10, 0.06, 0.16)),   // dawn plum/rose
            (0.50, (0.20, 0.40, 0.62), (0.10, 0.24, 0.45)),   // day ocean blue
            (0.77, (0.28, 0.13, 0.12), (0.14, 0.06, 0.10)),   // sunset amber/maroon
            (1.00, (0.08, 0.09, 0.20), (0.03, 0.04, 0.10)),   // night indigo
        ]
        let x = f - floor(f)
        var lo = stops[0], hi = stops[stops.count - 1]
        for i in 0..<(stops.count - 1) where x >= stops[i].at && x <= stops[i + 1].at {
            lo = stops[i]; hi = stops[i + 1]; break
        }
        let t = (x - lo.at) / max(hi.at - lo.at, 0.0001)
        func lerp(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Color {
            Color(red: a.0 + (b.0 - a.0) * t,
                  green: a.1 + (b.1 - a.1) * t,
                  blue: a.2 + (b.2 - a.2) * t)
        }
        return (lerp(lo.up, hi.up), lerp(lo.lo, hi.lo))
    }

    // MARK: - geometry

    /// Fraction of the day in [0,1); 0 = 00:00, 0.5 = noon.
    private func fractionOfDay(_ date: Date) -> Double {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return Double((c.hour ?? 0) * 60 + (c.minute ?? 0)) / 1440.0
    }

    /// Current time as "h:mm:ss AM/PM" so the readout visibly ticks every second.
    private func timeWithSeconds(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        let h24 = c.hour ?? 0
        var h = h24 % 12
        if h == 0 { h = 12 }
        return String(format: "%d:%02d:%02d%@", h, c.minute ?? 0, c.second ?? 0,
                      h24 < 12 ? "AM" : "PM")
    }

    /// The sky icon + tint for the current time of day, cutting between night,
    /// dawn, day and sunset across the whole day so the icon always reflects the
    /// current phase (`f` is the day fraction, 0.5 = noon). The glyph snaps at the
    /// phase boundaries while its halo/tint and the card behind it glide.
    private func skyIcon(_ f: Double) -> (String, Color) {
        switch f {
        case 0.22..<0.33: return ("sunrise.fill", Color(red: 1.0, green: 0.78, blue: 0.55))  // dawn, rose-gold
        case 0.33..<0.71: return ("sun.max.fill", Color(red: 1.0, green: 0.85, blue: 0.35))  // day, warm yellow
        case 0.71..<0.83: return ("sunset.fill", Color(red: 1.0, green: 0.55, blue: 0.30))   // sunset, deep orange
        default:          return ("moon.stars.fill", Color(white: 0.92))                      // night, soft white
        }
    }

    // MARK: - atmosphere (weather)

    /// Cheap deterministic [0,1) hash so particle positions are stable frame to
    /// frame (no per-frame RNG would make stars/rain jump around).
    private func hash(_ n: Double) -> Double {
        let s = sin(n) * 43758.5453
        return s - floor(s)
    }

    /// How "night" the sky is for a day fraction: 1 through deep night, ramping to
    /// 0 across dawn (0.20->0.28) and dusk (0.78->0.86). Fades the stars in/out so
    /// they don't pop on at the phase boundary.
    private func nightFactor(_ f: Double) -> Double {
        let x = f - floor(f)
        if x <= 0.20 || x >= 0.86 { return 1 }
        if x < 0.28 { return (0.28 - x) / 0.08 }
        if x > 0.78 { return (x - 0.78) / 0.08 }
        return 0
    }

    /// Draw the weather layer for the current condition. `wall` is real wall-clock
    /// seconds (so motion is smooth even while the DEBUG fast-forward races the
    /// day); `nowFrac` is the (possibly simulated) day fraction used for day/night.
    private func drawAtmosphere(_ context: GraphicsContext, rect: CGRect,
                                nowFrac: Double, wall: Double, condition: SkyCondition,
                                precipLevel: Double, precipSnow: Bool, clouds: CloudField) {
        let night = nightFactor(nowFrac)
        // Stars show through on clear and partly-cloudy nights.
        switch condition {
        case .clear, .unknown:
            if night > 0.01 { drawStars(context, rect: rect, t: wall, alpha: night) }
        case .partlyCloudy:
            if night > 0.01 { drawStars(context, rect: rect, t: wall, alpha: night * 0.6) }
        default:
            break
        }
        // Each condition maps to a target cloud count + density; the cloud field eases
        // between targets by drift (spawn left / exit right), so changing condition never
        // pops clouds in or out.
        let (target, density): (Int, Double)
        switch condition {
        case .partlyCloudy:   (target, density) = (2, 0.5)
        case .cloudy:         (target, density) = (4, 0.9)
        case .fog:            (target, density) = (5, 1.0)
        case .rain, .thunder: (target, density) = (3, 0.95)
        case .snow:           (target, density) = (3, 0.7)
        case .clear, .unknown:(target, density) = (0, 0.9)   // density only matters for clouds drifting off
        }
        drawClouds(context, rect: rect, t: wall, target: target, night: night,
                   density: density, field: clouds)
        // Precipitation rides the eased level, not the raw condition, so it thins out
        // and fades when the weather clears instead of cutting off the instant the
        // condition flips. `precipSnow` holds the type through the fade-out.
        if precipLevel > 0.01 {
            drawPrecip(context, rect: rect, t: wall, snow: precipSnow, intensity: precipLevel)
        }
    }

    private func drawStars(_ context: GraphicsContext, rect: CGRect, t: Double, alpha: Double) {
        let minX = Double(rect.minX), minY = Double(rect.minY)
        let W = Double(rect.width), H = Double(rect.height)
        for i in 0..<34 {
            let fi = Double(i)
            let x = minX + hash(fi * 1.7 + 0.3) * W
            let y = minY + hash(fi * 3.1 + 1.1) * H * 0.62      // upper ~60% of the card
            let r = 0.6 + hash(fi * 5.9) * 1.1
            let phase = hash(fi * 7.3) * 6.2831
            let speed = 1.4 + hash(fi * 2.2) * 2.0
            let twinkle = 0.35 + 0.65 * (0.5 + 0.5 * sin(t * speed + phase))
            let a = alpha * twinkle
            let dot = Path(ellipseIn: CGRect(x: CGFloat(x - r), y: CGFloat(y - r),
                                             width: CGFloat(r * 2), height: CGFloat(r * 2)))
            context.fill(dot, with: .color(.white.opacity(a)))
            // The brightest few carry a soft halo so the field has some sparkle depth.
            if hash(fi * 9.1) > 0.80 {
                let gr = r * 2.6
                let glow = Path(ellipseIn: CGRect(x: CGFloat(x - gr), y: CGFloat(y - gr),
                                                  width: CGFloat(gr * 2), height: CGFloat(gr * 2)))
                context.fill(glow, with: .radialGradient(
                    Gradient(colors: [.white.opacity(a * 0.5), .white.opacity(0)]),
                    center: CGPoint(x: CGFloat(x), y: CGFloat(y)), startRadius: 0, endRadius: CGFloat(gr)))
            }
        }
    }

    private func drawClouds(_ context: GraphicsContext, rect: CGRect, t: Double,
                            target: Int, night: Double, density: Double, field: CloudField) {
        // Procedural puff clouds: each cloud is a union of overlapping circles sitting
        // on a flat-ish baseline (bumpy crown, flat bottom), built as one Path so the
        // lobes merge into a single silhouette with no seams or double-darkened overlaps.
        // Tone shifts near-white by day to grey at night; a subtle top->bottom gradient
        // plus a soft blur give the blob some body and atmosphere. Every cloud varies its
        // width, height, lobe count and radii so no two read as the same stamp.
        //
        // The cloud population is a persistent pool of slots, not a fresh count each
        // frame, so condition changes read as natural drift rather than a pop. When more
        // clouds are wanted a dormant slot re-spawns at the left edge and drifts in; when
        // fewer are wanted the surplus slots keep drifting until they slide off the right
        // edge, then go dormant. Each slot freezes its last density while leaving so a
        // clear-up doesn't blink the departing clouds out.
        let topTone = 0.66 + (0.99 - 0.66) * (1 - night)
        let botTone = topTone - 0.22                           // shaded underside for depth
        let minX = Double(rect.minX), minY = Double(rect.minY)
        let maxX = Double(rect.maxX)
        let W = Double(rect.width), H = Double(rect.height)
        // Per-slot geometry is a pure function of the slot index, so a slot keeps its
        // look across spawns; only its phase (entry point) and on/off state are stored.
        func geom(_ c: Int) -> (cw: Double, ch: Double, baseY: Double, speed: Double, span: Double, alphaRand: Double) {
            let fc = Double(c) + 1
            let cw = W * (0.20 + hash(fc * 1.3) * 0.15)
            let ch = cw * (0.40 + hash(fc * 2.7) * 0.18)
            let bandY = minY + H * (0.10 + hash(fc * 3.1) * 0.20)
            return (cw, ch, bandY + ch * 0.5, 5 + hash(fc * 3.9) * 8, W + cw * 2,
                    0.40 + hash(fc * 5.5) * 0.22)
        }
        func cxOf(_ c: Int, _ phaseBase: Double, _ speed: Double, _ span: Double, _ cw: Double) -> Double {
            minX - cw + (phaseBase + t * speed).truncatingRemainder(dividingBy: span)
        }

        // One-time seed: spread the initial clouds across the band (original look) so the
        // first open isn't a clump entering from the left.
        if !field.initialized {
            for c in 0..<field.slots.count {
                let g = geom(c)
                field.slots[c].phaseBase = hash((Double(c) + 1) * 4.1) * g.span
                field.slots[c].visible = c < target
                field.slots[c].density = density
            }
            field.initialized = true
        }

        // Lifecycle pass: spawn / retire slots so the count eases by drift, not by popping.
        for c in 0..<field.slots.count {
            let g = geom(c)
            var s = field.slots[c]
            let cxC = cxOf(c, s.phaseBase, g.speed, g.span, g.cw)
            let offRight = cxC - g.cw / 2 > maxX
            if c < target {
                if !s.visible {
                    s.phaseBase = -(t * g.speed)            // re-enter from the left edge now
                    s.visible = true
                }
                s.leaving = false
                s.density = density                        // track live density while active
            } else if s.visible {
                s.leaving = true                           // drift off, holding frozen density
                if offRight { s.visible = false }
            }
            field.slots[c] = s
        }

        // Draw pass: every visible slot, at its current drifted position.
        for c in 0..<field.slots.count where field.slots[c].visible {
            let g = geom(c)
            let s = field.slots[c]
            let fc = Double(c) + 1
            let cxC = cxOf(c, s.phaseBase, g.speed, g.span, g.cw)
            let cw = g.cw, ch = g.ch, baseY = g.baseY
            let alpha = s.density * g.alphaRand

            let shape = cloudShape(cx: cxC, baseY: baseY, w: cw, h: ch, seed: fc)
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: max(0.7, cw * 0.012)))
                layer.clip(to: shape.silhouette)              // keep all texture inside the cloud
                // Body: a flat vertical shade (lit top -> shadowed underside).
                layer.fill(shape.silhouette, with: .linearGradient(
                    Gradient(colors: [Color(white: topTone).opacity(alpha),
                                      Color(white: botTone).opacity(alpha)]),
                    startPoint: CGPoint(x: cxC, y: baseY - ch),
                    endPoint: CGPoint(x: cxC, y: baseY)))
                // Per-lobe modelling: a lit billow on the upper-left of each bump and a
                // soft shadow tucked under it, so the cloud reads as stacked cauliflower
                // puffs with real volume instead of one even blob.
                for lobe in shape.lobes {
                    let lr = Double(lobe.r)
                    let hr = lr * 0.85
                    let hx = Double(lobe.c.x) - lr * 0.20, hy = Double(lobe.c.y) - lr * 0.32
                    layer.fill(
                        Path(ellipseIn: CGRect(x: hx - hr, y: hy - hr, width: hr * 2, height: hr * 2)),
                        with: .radialGradient(
                            Gradient(colors: [Color(white: min(1, topTone + 0.10)).opacity(alpha * 0.6),
                                              Color(white: topTone).opacity(0)]),
                            center: CGPoint(x: hx, y: hy), startRadius: 0, endRadius: hr))
                    let sr = lr * 0.95
                    let sx = Double(lobe.c.x) + lr * 0.12, sy = Double(lobe.c.y) + lr * 0.48
                    layer.fill(
                        Path(ellipseIn: CGRect(x: sx - sr, y: sy - sr, width: sr * 2, height: sr * 2)),
                        with: .radialGradient(
                            Gradient(colors: [Color(white: botTone).opacity(alpha * 0.5),
                                              Color(white: botTone).opacity(0)]),
                            center: CGPoint(x: sx, y: sy), startRadius: 0, endRadius: sr))
                }
            }
        }
    }

    private struct CloudShape {
        var silhouette: Path
        var lobes: [(c: CGPoint, r: CGFloat)]
    }

    /// One puffy cloud as a union of overlapping ellipses: a wide low base ellipse for
    /// the flat bottom and bulk, topped by a run of round lobes that peak in the middle
    /// and shrink toward the edges, so the crown is bumpy and the underside stays flat.
    /// Returns the silhouette plus each lobe's centre/radius so the caller can model
    /// highlights and shadows onto the individual bumps.
    private func cloudShape(cx: Double, baseY: Double, w: Double, h: Double, seed: Double) -> CloudShape {
        var p = Path()
        var lobes: [(c: CGPoint, r: CGFloat)] = []
        let baseH = h * 0.62
        p.addEllipse(in: CGRect(x: CGFloat(cx - w / 2), y: CGFloat(baseY - baseH),
                                width: CGFloat(w), height: CGFloat(baseH)))
        let n = 4 + Int(hash(seed * 6.1) * 3.0)               // 4..6 bumps
        for i in 0..<n {
            let fi = Double(i)
            let u = (fi + 0.5) / Double(n)                     // 0..1 across the width
            let centred = 1 - abs(u - 0.5) * 2                 // 1 mid, 0 at the flanks
            let r = h * (0.26 + 0.44 * centred) * (0.78 + hash(seed * 9.3 + fi) * 0.55)
            let lx = cx - w / 2 + u * w + (hash(seed * 7.7 + fi) - 0.5) * w * 0.14
            let ly = baseY - baseH * 0.5 - r * (0.28 + hash(seed * 5.2 + fi) * 0.48)
            p.addEllipse(in: CGRect(x: CGFloat(lx - r), y: CGFloat(ly - r),
                                    width: CGFloat(r * 2), height: CGFloat(r * 2)))
            lobes.append((CGPoint(x: lx, y: ly), CGFloat(r)))
        }
        return CloudShape(silhouette: p, lobes: lobes)
    }

    private func drawPrecip(_ context: GraphicsContext, rect: CGRect, t: Double, snow: Bool,
                            intensity: Double) {
        // `intensity` (0..1, eased by the caller) thins the field on two axes at once so
        // a clearing sky reads as "reduce then dissipate": the active particle count
        // scales down, and each remaining drop/flake also fades. Particle positions are
        // a fixed function of the index, so shrinking the count peels them off the tail
        // rather than reshuffling the whole field.
        let full = snow ? 34 : 64
        let active = Int((Double(full) * intensity).rounded())
        if active <= 0 { return }
        let minX = Double(rect.minX), minY = Double(rect.minY)
        let W = Double(rect.width), H = Double(rect.height)
        for i in 0..<active {
            let fi = Double(i)
            let x = minX + hash(fi * 1.9 + 0.5) * W
            let speed = snow ? (18 + hash(fi * 2.3) * 14) : (150 + hash(fi * 2.3) * 90)
            let phase = hash(fi * 3.7) * H
            let y = minY + (phase + t * speed).truncatingRemainder(dividingBy: H)
            if snow {
                let drift = sin(t * 1.2 + fi) * 4
                let r = 1.0 + hash(fi * 4.4) * 1.0
                let dot = Path(ellipseIn: CGRect(x: CGFloat(x + drift - r), y: CGFloat(y - r),
                                                 width: CGFloat(r * 2), height: CGFloat(r * 2)))
                context.fill(dot, with: .color(.white.opacity(0.8 * intensity)))
            } else {
                let len = 7 + hash(fi * 4.4) * 5
                var streak = Path()
                streak.move(to: CGPoint(x: CGFloat(x), y: CGFloat(y)))
                streak.addLine(to: CGPoint(x: CGFloat(x - 2), y: CGFloat(y + len)))
                context.stroke(streak, with: .color(Color(red: 0.70, green: 0.80, blue: 0.95).opacity(0.5 * intensity)),
                               style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
            }
        }
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
        // Fit the glyph inside a `glyph`-sized box preserving its natural aspect, so
        // wide symbols (sunrise/sunset carry a horizon + rays) keep their shape
        // instead of being squashed into a square and reading as vertically stretched.
        let nat = resolved.size
        let s = glyph / max(nat.width, nat.height, 1)
        let w = nat.width * s, h = nat.height * s
        let rect = CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h)
        context.draw(resolved, in: rect)
    }
}
