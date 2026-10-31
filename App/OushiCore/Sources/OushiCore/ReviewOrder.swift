// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

/// The order photos and videos come up for review: at random, the newest first, or the oldest first. Whatever
/// the order, what has been seen does not come up again until everything has.
public enum ReviewOrder: String, CaseIterable, Codable, Sendable {
    case random, newest, oldest
}

/// Which way a photo was swiped off the screen. Saved with the steps so undo brings it back from that side, even
/// after the app is relaunched.
public enum SwipeDirection: String, Codable, Sendable {
    case left, right, down, up

    public var isHorizontal: Bool { self == .left || self == .right }

    /// Toward the right or the bottom of the screen, the way offsets grow.
    public var isPositive: Bool { self == .right || self == .down }

    /// The direction along one axis that a signed movement on it goes.
    public static func along(horizontal: Bool, positive: Bool) -> SwipeDirection {
        horizontal ? (positive ? .right : .left) : (positive ? .down : .up)
    }
}
