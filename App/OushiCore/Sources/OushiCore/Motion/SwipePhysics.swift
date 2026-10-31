// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import CoreGraphics
import Foundation

/// The arithmetic of a card under a finger: how far it must go to leave, when a pull toward deletion arms, how the
/// card gives before that, and what a lifted finger's offset and speed amount to. Pure functions of sizes and
/// numbers, so the deck's feel is in one place and can be checked without a screen. A drag runs along one axis, and
/// its amounts are signed along it: positive toward the right or the bottom.
public enum SwipePhysics {
    /// The next card's scale while it waits under the top one.
    public static let nextCardScale: CGFloat = 0.8
    /// Past the deck's edge a flung card travels, so it is fully off screen from the center.
    public static let exitMargin: CGFloat = 48
    /// How far a swipe must go to do what it does, the same for every way: a pull toward deletion to arm, a
    /// release that keeps (projected ahead by its speed) to fling. A reach of the finger, the same on any screen, so
    /// a large deck (an iPad's) does not ask for a longer, more tiring stroke.
    public static let triggerLength: CGFloat = 70
    /// Sideways, never further than this share of the deck's width, so a narrow deck still leaves room past it.
    public static let sidewaysTriggerFraction: CGFloat = 0.4
    /// Letting an armed pull back to this share of the arming distance re-holds the card.
    public static let reholdFraction: CGFloat = 0.5
    /// How far ahead a release's velocity is projected, in seconds.
    public static let projectionTime: CGFloat = 0.15
    /// How much of a pull the held card gives before it arms, and of a drag the way that does nothing.
    public static let heldGive: CGFloat = 0.3
    public static let idleGive: CGFloat = 0.15
    /// A fling's start velocity relative to its distance is capped below the spring's natural frequency (about 13),
    /// which also keeps the next card, which shares the animation, from overshooting.
    public static let maxRelativeVelocity: Double = 10

    public static func exitDistance(in size: CGSize) -> CGSize {
        CGSize(width: size.width + exitMargin, height: size.height + exitMargin)
    }

    /// Where a card flung `direction` comes to rest: past the deck's edge, and past `outside`, how far the screen
    /// reaches beyond the deck on that side (under the bars), so that even a card as long as the deck has left the
    /// screen, not only the deck.
    public static func exitOffset(_ direction: SwipeDirection, in size: CGSize, outside: CGFloat = 0) -> CGSize {
        let exit = exitDistance(in: size)
        switch direction {
        case .left: return CGSize(width: -(exit.width + outside), height: 0)
        case .right: return CGSize(width: exit.width + outside, height: 0)
        case .down: return CGSize(width: 0, height: exit.height + outside)
        case .up: return CGSize(width: 0, height: -(exit.height + outside))
        }
    }

    /// How far a swipe must go to do what it does, along the given axis.
    public static func triggerDistance(in size: CGSize, horizontal: Bool) -> CGFloat {
        horizontal ? min(triggerLength, size.width * sidewaysTriggerFraction) : triggerLength
    }

    /// How far a pull toward deletion goes before it arms, along the given axis.
    public static func armDistance(in size: CGSize, horizontal: Bool) -> CGFloat {
        triggerDistance(in: size, horizontal: horizontal)
    }

    /// How far a release that keeps must be projected to fling, along the given axis: as far as a pull arms.
    public static func flingDistance(in size: CGSize, horizontal: Bool) -> CGFloat {
        triggerDistance(in: size, horizontal: horizontal)
    }

    /// Whether a pull of `pull` points (its length, whichever way) leaves the card armed: arming at the arming
    /// distance, re-holding only once the pull has come back well short of it (hysteresis, so a finger resting at
    /// the line does not flicker).
    public static func isArmed(after pull: CGFloat, wasArmed: Bool, armDistance: CGFloat) -> Bool {
        if !wasArmed { return pull >= armDistance }
        return pull >= armDistance * reholdFraction
    }

    /// Where the card sits along the drag for the finger's signed travel, by what moving that way does: a keep
    /// follows the finger; a queue holds the card, giving only a little, until the pull arms, then follows; a way
    /// that does nothing gives less still.
    public static func offset(travel: CGFloat, action: SwipeAction?, armed: Bool) -> CGFloat {
        switch action {
        case .keep: travel
        case .queue: armed ? travel : travel * heldGive
        case nil: travel * idleGive
        }
    }

    /// 0...1, how far the top card has moved toward leaving, either way along either axis, measured against the
    /// distance a fling sends it.
    public static func progress(of offset: CGSize, in size: CGSize) -> Double {
        let exit = exitDistance(in: size)
        guard exit.width > 0, exit.height > 0 else { return 0 }
        return min(max(abs(offset.width) / exit.width, abs(offset.height) / exit.height), 1)
    }

    /// The same, counting only a way that does something: a drag the way that does nothing only gives, and is no
    /// progress toward anything (the next card stays down, the glows stay put).
    public static func progress(of offset: CGSize, in size: CGSize, gestures: SwipeGestures) -> Double {
        let horizontal = abs(offset.width) >= abs(offset.height)
        let along = horizontal ? offset.width : offset.height
        guard along != 0, gestures.action(for: .along(horizontal: horizontal, positive: along > 0)) != nil else { return 0 }
        return progress(of: offset, in: size)
    }

    /// A release with the card following the finger: whether it flings, toward the positive end of the axis or
    /// the negative, and at what speed; nil when it settles back. The speed counts only when the finger was moving
    /// the card's way.
    public static func fling(offset: CGFloat, velocity: CGFloat, distance: CGFloat) -> (towardPositive: Bool, speed: CGFloat)? {
        let projected = offset + velocity * projectionTime
        guard abs(projected) > distance else { return nil }
        let speed = velocity * projected > 0 ? abs(velocity) : 0
        return (projected > 0, speed)
    }

    /// The start velocity of a fling's spring, relative to the distance it covers.
    public static func relativeVelocity(speed: CGFloat, distance: CGFloat) -> Double {
        distance > 1 ? min(Double(speed / distance), maxRelativeVelocity) : 0
    }

    /// The signed travel a finger takes over a demo at, from where the card is along the drag's axis: an armed or
    /// following card keeps its offset as the travel; a held one is taken as held short of arming, so the finger
    /// still has to pull to arm it.
    public static func takeoverTravel(offset: CGFloat, action: SwipeAction?, armed: Bool, armDistance: CGFloat) -> CGFloat {
        guard action == .queue, !armed else { return offset }
        let pull = min(abs(offset) / heldGive, armDistance * 0.8)
        return offset < 0 ? -pull : pull
    }
}
