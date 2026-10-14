// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import OushiCore
import SwiftUI
import UIKit

/// The screen behind the deck (user request, 2026-10-09): darkness lit by a few soft glows in the photo's main colors,
/// drifting slowly.
///
/// There are always the same seven glows, each living in its own area of the screen. A photo decides each glow's color,
/// size, brightness and where in its area it sits (random, but fixed per photo). Changing photos never swaps one set of
/// glows for another: the same glows move, resize and change color toward the new photo, eased by SwiftUI's animation
/// of the target, so swipes, flings and undo all read as light flowing rather than a crossfade.
///
/// When a batch is done the same glows turn one dim, slowly shifting color and flow around the screen behind the summary.
///
/// The ground also answers the deck: while a pull toward deletion is armed every glow leans red, and while undo
/// brings a card back up from the pool they lean green.
///
/// Drawn by the `ambientGlow` shader, which computes the soft falloff per pixel and everything that moves on its own
/// (drift, breathing, the flowing color) from the time it is given, so the view's body is a plain function of its
/// state and the frame's date. It stands still under Reduce Motion, in Low Power Mode and when the phone runs hot.
struct AmbientBackground: View {
    enum Source: Equatable {
        case photo(String)
        /// One slowly shifting color, flowing: the end of a batch
        case colorful
        /// No light: nothing to show
        case dark

        var photoID: String? {
            if case .photo(let id) = self { return id }
            return nil
        }
    }

    /// The deck whose cards light the ground; nil leaves the ground flowing in one slow color.
    let deck: CardDeck?
    /// Something opaque covers the whole background (the open pool): nothing is drawn for no one to see.
    var isHidden = false

    @Environment(ReviewSession.self) private var review
    @Environment(PhotoLibrary.self) private var library
    @Environment(PhotoImageLoader.self) private var images
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(PaletteStore.self) private var palettes
    @State private var clock = PlayClock()
    /// The signal's last color, for it to fade out in once it is gone, and the glows last laid out, for a photo
    /// whose colors are still loading to keep.
    @State private var lastSignal = SignalColor.delete
    @State private var shownGlows: [GlowState]?
    @State private var isPowerConstrained = ProcessInfo.processInfo.isLowPowerModeEnabled || ProcessInfo.processInfo.thermalState.isHot

    /// Motion stops when the user asks (Reduce Motion) and when it would cost what the phone is short of.
    private var isStill: Bool { reduceMotion || isPowerConstrained }
    private var isPaused: Bool { scenePhase != .active || isHidden || isStill }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: isPaused)) { context in
            glowLayer(at: clock.time(at: context.date))
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        // The glows' own clock runs only while frames are drawn, so leaving the app and coming back picks up the
        // motion where it stopped instead of jumping to wherever wall-clock time would have carried it.
        .onChange(of: isPaused, initial: true) { _, paused in clock.setPaused(paused, at: Date()) }
        .onChange(of: signal) { _, signal in
            if let signal { lastSignal = signal }
        }
        .onChange(of: currentLayout, initial: true) { _, layout in
            if let layout { shownGlows = layout }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange).receive(on: RunLoop.main)) { _ in
            isPowerConstrained = ProcessInfo.processInfo.isLowPowerModeEnabled || ProcessInfo.processInfo.thermalState.isHot
        }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification).receive(on: RunLoop.main)) { _ in
            isPowerConstrained = ProcessInfo.processInfo.isLowPowerModeEnabled || ProcessInfo.processInfo.thermalState.isHot
        }
        // Rerun once the library is read: before that, photos cannot be looked up.
        .task(id: PaletteKey(source: current, libraryLoaded: library.hasLoaded)) {
            if let id = current.photoID { await palettes.load(id, images: images) }
        }
        .task(id: PaletteKey(source: next, libraryLoaded: library.hasLoaded)) {
            if let id = next?.photoID { await palettes.load(id, images: images) }
        }
    }

    private struct PaletteKey: Equatable {
        var source: Source?
        var libraryLoaded: Bool
    }

    /// The shader with its targets. Each target is animated on its own: the glows at a photo's pace, the flowing
    /// look over a moment, the signal at once, since it answers a gesture and must be seen the moment it arms.
    /// The signal's strength is a modifier of its own outside the glows' animations: in one modifier, a glow
    /// change in the same update (a pull moves the glows every frame) would carry the signal at the glows' pace.
    private func glowLayer(at time: TimeInterval) -> some View {
        let signal = self.signal
        return Rectangle()
            .modifier(GlowEffect(
                glows: targetGlows,
                colorful: current == .colorful ? 1 : 0,
                // Gone, the signal fades out in its own color rather than through black.
                signal: signal ?? lastSignal,
                time: time,
                drifting: !isStill
            ))
            .animation(.smooth(duration: 0.7), value: targetGlows)
            .animation(.smooth(duration: 0.7), value: current == .colorful)
            .modifier(SignalStrength(amount: signal == nil ? 0 : 1))
            .animation(.smooth(duration: 0.2), value: signal == nil)
    }

    /// The batch is done: the ground turns to flowing color behind the summary.
    private var current: Source {
        guard let deck else { return .colorful }
        // System cards (the lessons, the access card) sit on flowing color, like the end-of-batch card.
        if deck.phase != .reviewing { return .colorful }
        if let id = deck.currentID { return .photo(id) }
        return review.batch.isComplete ? .colorful : .dark
    }

    private var next: Source? {
        guard let deck else { return nil }
        if let id = deck.nextID { return .photo(id) }
        return deck.currentID == nil ? nil : .colorful
    }

    /// Where the glows are heading: the current source's, blended toward the next one's by the swipe. A photo
    /// whose colors have not loaded yet keeps the glows as they were (dark at first) rather than dipping through
    /// dark on the way.
    private var targetGlows: GlowVector {
        let current = currentLayout ?? shownGlows ?? GlowState.dark
        let progress = deck?.progress ?? 0
        var glows = current
        if progress > 0, let next, let upcoming = layout(for: next) {
            glows = zip(current, upcoming).map { $0.mixed(with: $1, by: progress) }
        }
        return GlowVector(glows)
    }

    /// Red while a pull toward deletion is armed; green while undo brings a card back from the pool.
    private var signal: SignalColor? {
        guard let deck else { return nil }
        if deck.isDeleteArmed { return .delete }
        if deck.isReturningFromBottom { return .restore }
        return nil
    }

    private var currentLayout: [GlowState]? { layout(for: current) }

    /// A photo's glows, laid out once per photo; the flowing look keeps the glows at their anchors, dark, and the
    /// shader lights and moves them; nothing to show is darkness at the anchors.
    private func layout(for source: Source) -> [GlowState]? {
        switch source {
        case .photo(let id): palettes.glows(for: id)
        case .colorful, .dark: GlowState.dark
        }
    }
}

/// The glows' own time: it advances only while frames are drawn. Changed only from `onChange`, never while a
/// frame is being drawn; reading the time is a plain function of the frame's date.
private struct PlayClock {
    private var start: Date?
    private var pausedAt: Date?
    private var pausedFor: TimeInterval = 0

    mutating func setPaused(_ paused: Bool, at now: Date) {
        if start == nil { start = now }
        if paused {
            if pausedAt == nil { pausedAt = now }
        } else if let pausedAt {
            pausedFor += now.timeIntervalSince(pausedAt)
            self.pausedAt = nil
        }
    }

    /// Paused, the time stands where it was paused, whatever the date of a frame drawn meanwhile.
    func time(at date: Date) -> TimeInterval {
        guard let start else { return 0 }
        let now = pausedAt.map { min($0, date) } ?? date
        return max(now.timeIntervalSince(start) - pausedFor, 0)
    }
}

/// The ground's answer to a gesture, as a color.
private struct SignalColor: Equatable {
    var red: Double
    var green: Double
    var blue: Double

    static let delete = SignalColor(red: 1, green: 0.1, blue: 0.08)
    static let restore = SignalColor(red: 0.12, green: 1, blue: 0.3)
}

private extension ProcessInfo.ThermalState {
    var isHot: Bool { self == .serious || self == .critical }
}

/// The shader's targets as an animatable modifier: SwiftUI interpolates the glows and the flowing amount between
/// what they were and what they are now. The signal's strength comes down from `SignalStrength`, animated apart.
private struct GlowEffect: ViewModifier, Animatable {
    var glows: GlowVector
    var colorful: Double
    var signal: SignalColor
    var time: TimeInterval
    var drifting: Bool

    @Environment(\.signalStrength) private var signalAmount

    nonisolated var animatableData: AnimatablePair<GlowVector, Double> {
        get { AnimatablePair(glows, colorful) }
        set {
            glows = newValue.first
            colorful = newValue.second
        }
    }

    func body(content: Content) -> some View {
        content.visualEffect { [glows, colorful, signal, signalAmount, time, drifting] content, proxy in
            content.colorEffect(ShaderLibrary.ambientGlow(
                .float2(proxy.size),
                .float(time),
                .float(drifting ? 1 : 0),
                .float(colorful),
                .float4(Float(signal.red), Float(signal.green), Float(signal.blue), Float(signalAmount)),
                .floatArray(glows.values)
            ))
        }
    }
}

/// How strongly the ground answers a gesture, 0 to 1, animated on its own and handed to the shader through the
/// environment.
private struct SignalStrength: ViewModifier, Animatable {
    var amount: Double

    nonisolated var animatableData: Double {
        get { amount }
        set { amount = newValue }
    }

    func body(content: Content) -> some View {
        content.environment(\.signalStrength, amount)
    }
}

private struct SignalStrengthKey: EnvironmentKey {
    static let defaultValue = 0.0
}

private extension EnvironmentValues {
    var signalStrength: Double {
        get { self[SignalStrengthKey.self] }
        set { self[SignalStrengthKey.self] = newValue }
    }
}

/// Six floats per glow, as a vector SwiftUI can animate.
struct GlowVector: VectorArithmetic, Equatable, Sendable {
    var values: [Float]

    init(_ glows: [GlowState]) {
        values = []
        values.reserveCapacity(glows.count * 6)
        for glow in glows {
            values += [Float(glow.x), Float(glow.y), Float(glow.radius), Float(glow.red), Float(glow.green), Float(glow.blue)]
        }
    }

    private init(values: [Float]) {
        self.values = values
    }

    static var zero: GlowVector { GlowVector(values: []) }

    static func + (lhs: GlowVector, rhs: GlowVector) -> GlowVector {
        GlowVector(values: combine(lhs.values, rhs.values, +))
    }

    static func - (lhs: GlowVector, rhs: GlowVector) -> GlowVector {
        GlowVector(values: combine(lhs.values, rhs.values, -))
    }

    static func += (lhs: inout GlowVector, rhs: GlowVector) { lhs = lhs + rhs }
    static func -= (lhs: inout GlowVector, rhs: GlowVector) { lhs = lhs - rhs }

    mutating func scale(by rhs: Double) {
        let factor = Float(rhs)
        for index in values.indices { values[index] *= factor }
    }

    var magnitudeSquared: Double {
        values.reduce(0) { $0 + Double($1 * $1) }
    }

    /// A shorter vector is padded with zeros: the zero vector has no length of its own.
    private static func combine(_ a: [Float], _ b: [Float], _ operation: (Float, Float) -> Float) -> [Float] {
        let count = max(a.count, b.count)
        var result = [Float](repeating: 0, count: count)
        for index in 0..<count {
            result[index] = operation(index < a.count ? a[index] : 0, index < b.count ? b[index] : 0)
        }
        return result
    }
}

/// One glow: center as fractions of the screen's width and height, radius as a fraction of its height.
/// Color is scaled by brightness.
struct GlowState: Equatable, Sendable {
    var x: Double
    var y: Double
    var radius: Double
    var red: Double
    var green: Double
    var blue: Double

    /// The area each glow lives in, as fractions of the screen's width and height. Irregular on purpose.
    static let anchors: [(x: Double, y: Double)] = [
        (0.15, 0.10), (0.85, 0.16), (0.50, 0.34), (0.10, 0.52),
        (0.90, 0.60), (0.28, 0.88), (0.78, 0.92),
    ]

    /// All glows dark at their anchors: what the screen fades to with no photo, and where the flowing look lives.
    static var dark: [GlowState] {
        anchors.map { GlowState(x: $0.x, y: $0.y, radius: 0.22, red: 0, green: 0, blue: 0) }
    }

    /// A photo's glows: each one takes a color from the palette in proportion to how much of the photo it covers.
    static func layout(for photoID: String, palette: [PaletteColor]) -> [GlowState] {
        guard !palette.isEmpty else { return dark }
        var random = SeededRandom(seed: photoID)
        let totalWeight = palette.reduce(0) { $0 + $1.weight }
        return anchors.map { anchor in
            var pick = random.next(in: 0...totalWeight)
            var color = palette[0]
            for entry in palette {
                pick -= entry.weight
                if pick <= 0 { color = entry; break }
            }
            let x = anchor.x + random.next(in: -0.12...0.12)
            let y = anchor.y + random.next(in: -0.08...0.08)
            let radius = (0.16 + 0.08 * color.weight) * random.next(in: 0.85...1.2)
            // Some glows stay faint so the screen is not evenly lit.
            let faint = random.next(in: 0...1) < 0.3
            let brightness = (0.55 + 0.45 * color.weight) * random.next(in: 0.7...1) * (faint ? 0.3 : 1)
            return GlowState(
                x: x, y: y, radius: radius,
                red: color.red * brightness, green: color.green * brightness, blue: color.blue * brightness
            )
        }
    }

    func mixed(with other: GlowState, by amount: Double) -> GlowState {
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * amount }
        return GlowState(
            x: mix(x, other.x), y: mix(y, other.y), radius: mix(radius, other.radius),
            red: mix(red, other.red), green: mix(green, other.green), blue: mix(blue, other.blue)
        )
    }
}

/// Photo palettes and the glow layouts made from them, extracted once per photo off the main thread. Observed, so
/// a still background redraws when a palette arrives. Only recent photos are kept.
@MainActor
@Observable
final class PaletteStore {
    private var palettes: [String: [PaletteColor]] = [:]
    @ObservationIgnored private var layouts: [String: [GlowState]] = [:]
    @ObservationIgnored private var order: [String] = []
    /// Loads under way, one per photo, shared by whoever asks, with who is waiting: a load nobody waits for any
    /// more (the card swiped away) is cancelled.
    @ObservationIgnored private var loads: [String: Load] = [:]

    private struct Load {
        let task: Task<[PaletteColor]?, Never>
        var waiters: Set<UUID> = []
    }

    private static let keptPhotos = 60

    func palette(for id: String) -> [PaletteColor]? { palettes[id] }

    /// The photo's glows, laid out once and kept with its palette.
    func glows(for id: String) -> [GlowState]? {
        guard let palette = palettes[id] else { return nil }
        if let layout = layouts[id] { return layout }
        let layout = GlowState.layout(for: id, palette: palette)
        layouts[id] = layout
        return layout
    }

    func load(_ id: String, images: PhotoImageLoader) async {
        guard palettes[id] == nil else { return }
        var load = loads[id] ?? Load(task: Task {
            // A small, quick version is enough for a few colors; the ordinary request only where PhotoKit has no
            // quick one to give.
            let size = CGSize(width: 32, height: 32)
            var small = await images.quickImage(for: id, targetSize: size)
            if small == nil { small = await images.image(for: id, targetSize: size) }
            guard let image = small?.cgImage else { return nil }
            return await Task.detached(priority: .utility) { PaletteColor.dominant(in: image) }.value
        })
        let ticket = UUID()
        load.waiters.insert(ticket)
        loads[id] = load
        let task = load.task
        // Giving up (the card swiped away before the colors came) takes this waiter off the load; the load itself
        // is cancelled only when the last waiter is gone.
        let colors = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { @MainActor in self.leave(id, ticket: ticket) }
        }
        leave(id, ticket: ticket)
        guard let colors, palettes[id] == nil else { return }
        palettes[id] = colors
        order.append(id)
        if order.count > Self.keptPhotos {
            let dropped = order.removeFirst()
            palettes[dropped] = nil
            layouts[dropped] = nil
        }
    }

    /// A waiter is done with the load, finished or given up (either way once: the ticket is spent). With none
    /// left, the load is let go, and cancelled if it is still running.
    private func leave(_ id: String, ticket: UUID) {
        guard var load = loads[id], load.waiters.remove(ticket) != nil else { return }
        if load.waiters.isEmpty {
            loads[id] = nil
            load.task.cancel()
        } else {
            loads[id] = load
        }
    }
}

/// One of a photo's main colors, brightened to read as light, with its share of the photo (0...1, largest = 1).
struct PaletteColor: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let weight: Double

    /// Buckets pixels by hue, favoring vivid ones, and returns up to `count` colors that each cover a fair share.
    /// A photo with no real color gives one dim neutral; a dark photo gives none.
    static func dominant(in image: CGImage, count: Int = 4) -> [PaletteColor] {
        let side = 24
        // The context owns its pixels; a buffer passed in by pointer would only be good for the call that made it.
        guard let context = CGContext(
            data: nil, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let data = context.data else { return [] }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        let pixels = UnsafeBufferPointer(start: data.bindMemory(to: UInt8.self, capacity: side * side * 4), count: side * side * 4)

        let hueBins = 12
        var sums = [(r: Double, g: Double, b: Double, weight: Double)](repeating: (0, 0, 0, 0), count: hueBins + 1)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[index]) / 255
            let g = Double(pixels[index + 1]) / 255
            let b = Double(pixels[index + 2]) / 255
            let maximum = max(r, g, b)
            let minimum = min(r, g, b)
            let saturation = maximum > 0 ? (maximum - minimum) / maximum : 0
            guard maximum > 0.12 else { continue }
            let bin: Int
            let weight: Double
            if saturation < 0.18 {
                bin = hueBins
                weight = 0.15 * maximum
            } else {
                bin = Int(hue(r: r, g: g, b: b, maximum: maximum, minimum: minimum) * Double(hueBins)) % hueBins
                weight = saturation * maximum
            }
            sums[bin].r += r * weight
            sums[bin].g += g * weight
            sums[bin].b += b * weight
            sums[bin].weight += weight
        }

        let total = sums.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return [] }
        let ranked = sums.enumerated()
            .filter { $0.element.weight / total > 0.06 }
            .sorted { $0.element.weight > $1.element.weight }
            .prefix(count)
        guard let largest = ranked.first?.element.weight else { return [] }
        return ranked.map { bin, sum in
            let average = UIColor(
                red: sum.r / sum.weight, green: sum.g / sum.weight, blue: sum.b / sum.weight, alpha: 1
            )
            let light = average.asLight(neutral: bin == hueBins)
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            light.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return PaletteColor(red: red, green: green, blue: blue, weight: sum.weight / largest)
        }
    }

    private static func hue(r: Double, g: Double, b: Double, maximum: Double, minimum: Double) -> Double {
        let delta = maximum - minimum
        guard delta > 0 else { return 0 }
        var hue: Double
        if maximum == r {
            hue = (g - b) / delta
        } else if maximum == g {
            hue = (b - r) / delta + 2
        } else {
            hue = (r - g) / delta + 4
        }
        hue /= 6
        return hue < 0 ? hue + 1 : hue
    }
}

private extension UIColor {
    /// Same hue, pushed bright and a little more saturated so it glows; neutrals stay dim.
    func asLight(neutral: Bool) -> UIColor {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        if neutral {
            return UIColor(hue: hue, saturation: saturation, brightness: min(brightness, 0.45), alpha: 1)
        }
        return UIColor(hue: hue, saturation: min(saturation * 1.2, 1), brightness: max(brightness, 0.85), alpha: 1)
    }
}

/// Deterministic per seed: the same string always lays out its glows (or a shape card) the same way.
struct SeededRandom {
    private var state: UInt64

    init(seed: String) {
        // FNV-1a, stable across launches unlike String.hashValue.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        state = hash == 0 ? 1 : hash
    }

    mutating func next(in range: ClosedRange<Double>) -> Double {
        // xorshift64*
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        let value = Double((state &* 0x2545_f491_4f6c_dd1d) >> 11) / Double(1 << 53)
        return range.lowerBound + (range.upperBound - range.lowerBound) * value
    }
}
