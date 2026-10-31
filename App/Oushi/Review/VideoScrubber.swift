// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import SwiftUI

/// The playback control on a video card, drawn to the measurements of the one in the Photos app: a 44-point glass
/// pill with play/pause at its left end, sound at its right, and between them a thin bar filling as the video
/// plays. A finger held on the bar grows the pill upward to 68 points, the bar staying on its line but at once
/// thicker and reaching nearly to the pill's ends as the two buttons fade; above the bar appear the time played,
/// to the hundredth, and the time left, at its two ends. Dragging moves the time by the finger's travel, from where it
/// was rather than to where the finger is, past either end with the stretch of the volume slider; a throw keeps
/// the time moving after the finger lifts, and only once it has run out does the pill settle back to 44 points.
struct VideoScrubber: View {
    let playback: VideoPlaybackController
    /// The video this scrubber is for: what it asks of the player is for that video only, so a scrubber still
    /// finishing as its card leaves does not move the next video.
    let videoID: String
    /// The width of the area the pill sits in; the pill is narrower by its margins.
    let width: CGFloat

    /// Where the scrub stands. The finger down opens the pill; a real drag moves the time; after the finger lifts
    /// the time runs on, then eases back and the pill closes.
    private enum Phase: Equatable {
        case idle
        /// The finger is down at `x`; the time waits for a drag of `dragThreshold`.
        case pressed(x: CGFloat)
        /// The time and finger position the drag measures from: set where the threshold was crossed, so the bar
        /// starts from rest rather than jumping by the threshold, as a picture dragged starts from where it was.
        case dragging(time: Double, x: CGFloat)
        case throwing
        case settling

        var isFingerDown: Bool {
            switch self {
            case .pressed, .dragging: true
            case .idle, .throwing, .settling: false
            }
        }
    }

    @State private var phase: Phase = .idle
    /// The unstretched time while scrubbing (nil otherwise): what a throw or a re-grab carries on from. The time
    /// shown stretches it past the ends; stretching a stretched time again would double the give.
    @State private var rawTime: Double?
    /// Which end the bar is pulled past, kept while it eases back so the stretch stays on that side.
    @State private var overshootEnd: OvershootEnd?
    /// The finger is on the bar, as the gesture reports it; reset by the system when it takes the touch away,
    /// which `onEnded` never hears of.
    @GestureState private var isTouching = false
    @State private var clock = FrameClock()
    /// Which settling is under way, so an earlier one ending late does not finish a later one.
    @State private var settleToken = UUID()

    private static let restHeight: CGFloat = 44
    private static let heldHeight: CGFloat = 68
    /// From the sides of the area to the pill: Photos keeps the pill 26 points off the screen's edges, and the
    /// deck's room already stands 12 in from them.
    private static let margin: CGFloat = 14
    private static let buttonWidth: CGFloat = 44
    private static let restBar = (thickness: CGFloat(6), inset: CGFloat(48))
    private static let heldBar = (thickness: CGFloat(14), inset: CGFloat(20))
    private static let dragThreshold: CGFloat = 6
    /// The held bar's bottom edge above the pill's bottom: with its 14 points, its centre line is at 22, where
    /// the resting bar's is too.
    private static let barBottom: CGFloat = 15
    /// How a throw slows: the time constant of its decay, and the much shorter one past an end.
    private static let throwDecay = 0.3
    private static let overshootDecay = 0.06
    /// One step of VoiceOver's adjustment, in seconds.
    private static let adjustmentStep = 5.0

    private enum OvershootEnd { case start, end }
    /// How far past the ends the bar may be pulled, as a share of the length, and how much of the pull it yields.
    private static let overshootLimit = 0.08
    private static let overshootGive = 0.35

    private var expanded: Bool { phase != .idle || rawTime != nil }
    private var pillWidth: CGFloat { max(width - 2 * Self.margin, 0) }
    private var pillHeight: CGFloat { expanded ? Self.heldHeight : Self.restHeight }
    private var bar: (thickness: CGFloat, inset: CGFloat) { expanded ? Self.heldBar : Self.restBar }
    private var barLength: CGFloat { max(pillWidth - 2 * bar.inset, 1) }
    /// The bar's length when held: what a finger's travel is measured against.
    private var heldBarLength: CGFloat { max(pillWidth - 2 * Self.heldBar.inset, 1) }
    private var duration: Double { max(playback.duration, 0.01) }
    /// The scrub's time with the stretch past the ends, or nil when the player's own time is shown.
    private var scrubTime: Double? { rawTime.map(stretched) }
    /// Beyond an end, by how much of the bar.
    private var overshoot: Double {
        guard let scrubTime else { return 0 }
        let fraction = scrubTime / duration
        return fraction < 0 ? -fraction : fraction > 1 ? fraction - 1 : 0
    }

    // The pill is a glass shape that grows upward from its bottom edge; the contents are laid out separately, in
    // a frame of the full held height anchored to the same bottom edge, so nothing in them moves when the pill
    // grows: the bar keeps its line 22 points above the bottom, the buttons fade in place, the times fade in
    // above the bar. The player's time is read only by the bar and the labels (the bar's accessibility value
    // included), so its 30 reports a second redraw those and nothing else.
    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
                .frame(width: pillWidth, height: pillHeight)
                // A container, not a button: it does not answer the touch.
                .modifier(GlassCapsule(interactive: false))
            ZStack(alignment: .bottom) {
                TimeLabels(playback: playback, scrubTime: scrubTime)
                    .frame(width: heldBarLength)
                    .padding(.bottom, Self.barBottom + Self.heldBar.thickness + 7)
                    .opacity(expanded ? 1 : 0)
                Track(playback: playback, scrubTime: scrubTime, length: barLength, thickness: bar.thickness) { direction in
                    let step = direction == .increment ? Self.adjustmentStep : -Self.adjustmentStep
                    playback.seek(to: playback.time + step, precise: true, video: videoID)
                }
                .frame(width: pillWidth, height: Self.restHeight)
                // Pulled past an end, the bar stretches from the other end, like the volume slider.
                .scaleEffect(
                    x: 1 + overshoot * 0.6,
                    anchor: UnitPoint(x: overshootEnd == .start ? 1 - bar.inset / max(pillWidth, 1) : bar.inset / max(pillWidth, 1), y: 0.5)
                )
                // The whole strip takes the finger, not just the thin bar; the buttons lie over its ends.
                .contentShape(.rect)
                .gesture(scrub)
                HStack(spacing: 0) {
                    playButton
                    Spacer()
                    soundButton
                }
                .frame(width: pillWidth, height: Self.restHeight)
                .opacity(expanded ? 0 : 1)
                .allowsHitTesting(!expanded)
            }
            .frame(width: pillWidth, height: Self.heldHeight, alignment: .bottom)
            // Only what the pill covers shows, so the times rise into view with it rather than hang above it.
            .mask(alignment: .bottom) {
                Capsule().frame(width: pillWidth, height: pillHeight)
            }
        }
        .animation(.smooth(duration: 0.3), value: expanded)
        .animation(.smooth(duration: 0.3), value: overshoot == 0)
        // The system took the touch away (a call, a system gesture): the finger is gone without `onEnded`.
        .onChange(of: isTouching) { _, touching in
            if !touching, phase.isFingerDown { fingerLifted(velocity: 0) }
        }
        // Gone (the controls hidden, the card swiped away): the video is not left held still.
        .onDisappear {
            clock.stop()
            if let scrubTime { playback.seek(to: scrubTime, precise: true, video: videoID) }
            rawTime = nil
            overshootEnd = nil
            phase = .idle
            playback.setScrubbing(false, video: videoID)
        }
    }

    private var playButton: some View {
        Button {
            playback.wantsPlaying.toggle()
        } label: {
            Image(systemName: playback.wantsPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: Self.buttonWidth, height: Self.restHeight)
                .contentShape(.rect)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playback.wantsPlaying ? String(localized: "暂停") : String(localized: "播放"))
    }

    private var soundButton: some View {
        Button {
            playback.soundOn.toggle()
        } label: {
            Image(systemName: playback.soundOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: Self.buttonWidth, height: Self.restHeight)
                .contentShape(.rect)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playback.soundOn ? String(localized: "关闭声音") : String(localized: "打开声音"))
    }

    // MARK: Scrubbing

    private var scrub: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .updating($isTouching) { _, state, _ in state = true }
            .onChanged { value in
                let x = value.location.x
                switch phase {
                case .idle, .throwing, .settling:
                    // The finger came down: the pill opens at once, the time waits for a real drag; a throw still
                    // running is caught where it stands.
                    clock.stop()
                    phase = .pressed(x: x)
                    playback.setScrubbing(true, video: videoID)
                case .pressed(let origin):
                    if abs(x - origin) >= Self.dragThreshold {
                        phase = .dragging(time: rawTime ?? playback.time, x: x)
                    }
                case .dragging(let startTime, let startX):
                    move(to: startTime + Double(x - startX) / Double(heldBarLength) * duration)
                }
            }
            .onEnded { value in
                // The finger's speed as the gesture measured it, as seconds of video per second.
                fingerLifted(velocity: Double(value.velocity.width) / Double(heldBarLength) * duration)
            }
    }

    /// The finger is off the bar, lifted or taken away: a drag is thrown and settled; a touch that never became
    /// a drag only closes the pill, unless it landed during a throw, which is then settled where it stands.
    private func fingerLifted(velocity: Double) {
        switch phase {
        case .dragging:
            throwAndSettle(velocity: velocity)
        case .pressed:
            if rawTime != nil {
                throwAndSettle(velocity: 0)
            } else {
                phase = .idle
                playback.setScrubbing(false, video: videoID)
            }
        case .idle, .throwing, .settling:
            break
        }
    }

    /// Takes the time to `raw`, yielding past the ends like the volume slider and seeking the player within them.
    private func move(to raw: Double) {
        rawTime = raw
        if raw < 0 {
            overshootEnd = .start
        } else if raw > duration {
            overshootEnd = .end
        }
        playback.seek(to: stretched(raw), precise: false, video: videoID)
    }

    /// The time as the bar shows it: within the video as it is, past an end with the rubber band's give.
    private func stretched(_ raw: Double) -> Double {
        if raw < 0 { return -Self.yield(-raw, limit: duration * Self.overshootLimit) }
        if raw > duration { return duration + Self.yield(raw - duration, limit: duration * Self.overshootLimit) }
        return raw
    }

    /// How far a pull past an end moves the bar: a rubber band, giving `overshootGive` of a small pull and
    /// stiffening so that no pull takes it beyond `limit`.
    private static func yield(_ pull: Double, limit: Double) -> Double {
        limit * pull / (pull + limit / overshootGive)
    }

    /// Lets the time run on with the finger's speed, slowing as a thrown scroll does and in step with the display,
    /// then eases back from past an end if it went there, and only then lets the pill settle to rest.
    private func throwAndSettle(velocity: Double) {
        phase = .throwing
        var velocity = velocity
        var time = rawTime ?? playback.time
        let duration = duration
        clock.start { elapsed in
            time += velocity * elapsed
            velocity *= exp(-elapsed / Self.throwDecay)
            // Past an end the throw dies fast, the bar stretching only a little.
            if time < 0 || time > duration { velocity *= exp(-elapsed / Self.overshootDecay) }
            move(to: time)
            if abs(velocity) > duration * 0.02 { return true }
            settle()
            return false
        }
    }

    private func settle() {
        phase = .settling
        let token = UUID()
        settleToken = token
        let settled = min(max(rawTime ?? playback.time, 0), duration)
        withAnimation(.smooth(duration: 0.3), completionCriteria: .logicallyComplete) {
            rawTime = settled
        } completion: {
            // Caught again while settling, or settled again since: the newer scrub owns the pill.
            guard phase == .settling, settleToken == token else { return }
            playback.seek(to: settled, precise: true, video: videoID)
            rawTime = nil
            overshootEnd = nil
            phase = .idle
            playback.setScrubbing(false, video: videoID)
        }
    }

    // MARK: Time

    /// Minutes, seconds and hundredths: 02:22.37. Cut, not rounded, to hundredths, so 59.996 is 59.99, not 60.00.
    static func elapsed(_ seconds: Double) -> String {
        let hundredths = Int((max(seconds, 0) * 100).rounded(.down))
        return String(format: "%02d:%02d.%02d", hundredths / 6000, hundredths % 6000 / 100, hundredths % 100)
    }

    /// Minutes and seconds: 00:49.
    static func remaining(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded(.up))
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }
}

/// The time played and the time left, at the bar's two ends.
private struct TimeLabels: View {
    let playback: VideoPlaybackController
    let scrubTime: Double?

    var body: some View {
        let duration = max(playback.duration, 0.01)
        let clamped = min(max(scrubTime ?? playback.time, 0), duration)
        HStack {
            Text(VideoScrubber.elapsed(clamped))
            Spacer()
            Text(VideoScrubber.remaining(duration - clamped))
        }
        .font(.system(size: 13, weight: .semibold).monospacedDigit())
        .foregroundStyle(.white)
    }
}

/// The bar, a shape rather than a laid-out view: it spans the pill's width on the bottom 44 points with the bar
/// centred in it, so a change of length grows evenly from the middle and the centre line never moves. Only the
/// length is animatable; the thickness takes its held value at once. To VoiceOver it is the one adjustable
/// element, its value the time played.
private struct Track: View {
    let playback: VideoPlaybackController
    let scrubTime: Double?
    let length: CGFloat
    let thickness: CGFloat
    /// VoiceOver's adjustment, a step either way.
    let adjust: (AccessibilityAdjustmentDirection) -> Void

    var body: some View {
        let duration = max(playback.duration, 0.01)
        let fraction = (scrubTime ?? playback.time) / duration
        ZStack {
            BarShape(length: length, thickness: thickness)
                .fill(.white.opacity(0.34))
            // Rounded at the start by the track's shape, flat at the playhead.
            BarShape(length: length, thickness: thickness, played: min(max(fraction, 0), 1))
                .fill(.white.opacity(0.92))
                .clipShape(BarShape(length: length, thickness: thickness))
        }
        .accessibilityElement()
        .accessibilityLabel("播放位置")
        .accessibilityValue(Text(VideoScrubber.elapsed(min(max(fraction, 0), 1) * duration)))
        .accessibilityAdjustableAction(adjust)
    }
}

/// The scrubber's bar centred in its rect: the whole track as a capsule, or, with `played`, that share of it from
/// the start as a plain rectangle (to be clipped by the track).
private struct BarShape: Shape {
    var length: CGFloat
    var thickness: CGFloat
    var played: CGFloat?

    var animatableData: CGFloat {
        get { length }
        set { length = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let bar = CGRect(x: rect.midX - length / 2, y: rect.midY - thickness / 2, width: length, height: thickness)
        if let played {
            return Path(CGRect(x: bar.minX, y: bar.minY, width: bar.width * played, height: bar.height))
        }
        return Path(roundedRect: bar, cornerRadius: thickness / 2)
    }
}
