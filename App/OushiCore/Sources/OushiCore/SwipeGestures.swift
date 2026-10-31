// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

/// What a swipe does to the photo on top: keep it and go on to the next (跳过), or queue it for deletion (删除).
public enum SwipeAction: Sendable {
    case keep, queue
}

/// The sideways swipes the user has chosen: to the left, either way, or to the right.
public enum SidewaysSwipe: String, CaseIterable, Codable, Sendable {
    case left, either, right

    public var directions: [SwipeDirection] {
        switch self {
        case .left: [.left]
        case .either: [.left, .right]
        case .right: [.right]
        }
    }

    /// The one way to name when a single way is wanted (VoiceOver's actions): to the right when either will do.
    public var primary: SwipeDirection { self == .left ? .left : .right }
}

/// The up-and-down swipes the user has chosen: down, either way, or up.
public enum UpDownSwipe: String, CaseIterable, Codable, Sendable {
    case down, either, up

    public var directions: [SwipeDirection] {
        switch self {
        case .down: [.down]
        case .either: [.up, .down]
        case .up: [.up]
        }
    }

    /// The one way to name when a single way is wanted (VoiceOver's actions): down when either will do.
    public var primary: SwipeDirection { self == .up ? .up : .down }
}

/// The deck's gestures as the user has set them: sideways swipes keep a photo and up-and-down ones queue it, or,
/// swapped, the other way round, each in the directions chosen. A way not chosen does nothing: the card only gives
/// a little, then goes back.
public struct SwipeGestures: Equatable, Sendable {
    public var sideways: SidewaysSwipe
    public var upDown: UpDownSwipe
    /// Sideways swipes queue and up-and-down ones keep.
    public var swapped: Bool

    public init(sideways: SidewaysSwipe = .either, upDown: UpDownSwipe = .down, swapped: Bool = false) {
        self.sideways = sideways
        self.upDown = upDown
        self.swapped = swapped
    }

    /// What a swipe in `direction` does, or nil when that way does nothing.
    public func action(for direction: SwipeDirection) -> SwipeAction? {
        let chosen = direction.isHorizontal ? sideways.directions : upDown.directions
        guard chosen.contains(direction) else { return nil }
        return direction.isHorizontal != swapped ? .keep : .queue
    }

    /// `action` is done by sideways swipes (rather than up-and-down ones).
    public func isSideways(_ action: SwipeAction) -> Bool {
        (action == .keep) != swapped
    }

    /// The ways that do `action`, all along one axis, in the order the lessons show them.
    public func directions(for action: SwipeAction) -> [SwipeDirection] {
        isSideways(action) ? sideways.directions : upDown.directions
    }

    /// The one way that does `action`, when a single way is wanted (VoiceOver's actions).
    public func direction(for action: SwipeAction) -> SwipeDirection {
        isSideways(action) ? sideways.primary : upDown.primary
    }

    /// The way a card undo brings back comes in from, held to the gestures as they are now, not as they were when
    /// it left: the way it left, if that way still does what the swipe did; otherwise a way that does it now, the
    /// side matching the one it left by when there are two (left goes with up, right with down). A step saved
    /// before directions were has none, and stays without: its card grows back in place.
    public func returnDirection(for action: SwipeAction, leftBy direction: SwipeDirection?) -> SwipeDirection? {
        guard let direction else { return nil }
        let ways = directions(for: action)
        if ways.contains(direction) { return direction }
        return ways.first { $0.isPositive == direction.isPositive } ?? self.direction(for: action)
    }
}
