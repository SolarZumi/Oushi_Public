// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import CoreGraphics
import Foundation

/// The arithmetic of a card under a finger: how far it must go to leave, when a downward pull arms, how the pull
/// gives before that, and what a lifted finger's offset and speed amount to. Pure functions of sizes and numbers,
/// so the deck's feel is in one place and can be checked without a screen.
public enum SwipePhysics {
    /// The next card's scale while it waits under the top one.
    public static let nextCardScale: CGFloat = 0.8
    /// Past the deck's edge a flung card travels, so it is fully off screen from the center.
    public static let exitMargin: CGFloat = 48
    /// How far down, as a share of the deck's height, a pull must go before the card lets go of its place.
    public static let armFraction: CGFloat = 0.2
    /// Letting an armed pull back to this share of the arming distance re-holds the card.
    public static let reholdFraction: CGFloat = 0.5
    /// A sideways release flings once the projected offset passes this share of the deck's width.
    public static let flingFraction: CGFloat = 0.3
    /// How far ahead a release's velocity is projected, in seconds.
    public static let projectionTime: CGFloat = 0.15
    /// How much of a downward pull the held card gives before it arms, and of an upward one.
    public static let heldGive: CGFloat = 0.3
    public static let upwardGive: CGFloat = 0.15
    /// A fling's start velocity relative to its distance is capped below the spring's natural frequency (about 13),
    /// which also keeps the next card, which shares the animation, from overshooting.
    public static let maxRelativeVelocity: Double = 10

    public static func exitDistance(in size: CGSize) -> CGSize {
        CGSize(width: size.width + exitMargin, height: size.height + exitMargin)
    }

    public static func exitOffset(_ direction: SwipeDirection, in size: CGSize) -> CGSize {
        let exit = exitDistance(in: size)
        switch direction {
        case .left: return CGSize(width: -exit.width, height: 0)
        case .right: return CGSize(width: exit.width, height: 0)
        case .down: return CGSize(width: 0, height: exit.height)
        }
    }

    public static func armDistance(in size: CGSize) -> CGFloat {
        size.height * armFraction
    }

    /// Whether a pull of `pull` points leaves the card armed: arming at the arming distance, re-holding only once
    /// the pull has come back well above it (hysteresis, so a finger resting at the line does not flicker).
    public static func isArmed(after pull: CGFloat, wasArmed: Bool, armDistance: CGFloat) -> Bool {
        if !wasArmed { return pull >= armDistance }
        return pull >= armDistance * reholdFraction
    }

    /// Where the card sits for a pull: following the finger once armed, giving only a little before.
    public static func pullOffset(_ pull: CGFloat, armed: Bool) -> CGFloat {
        if armed { return pull }
        return pull * (pull < 0 ? upwardGive : heldGive)
    }

    /// 0...1, how far the top card has moved toward leaving, measured against the distance a fling sends it.
    public static func progress(of offset: CGSize, in size: CGSize) -> Double {
        let exit = exitDistance(in: size)
        guard exit.width > 0, exit.height > 0 else { return 0 }
        let sideways = abs(offset.width) / exit.width
        let downward = offset.height / exit.height
        return min(max(max(sideways, downward), 0), 1)
    }

    /// A sideways release: the direction and speed of the fling it amounts to, or nil when the card settles back.
    /// The speed counts only when the finger was moving the card's way.
    public static func sidewaysFling(offset: CGFloat, velocity: CGFloat, width: CGFloat) -> (direction: SwipeDirection, speed: CGFloat)? {
        let projected = offset + velocity * projectionTime
        guard abs(projected) > width * flingFraction else { return nil }
        let speed = velocity * projected > 0 ? abs(velocity) : 0
        return (projected < 0 ? .left : .right, speed)
    }

    /// The start velocity of a fling's spring, relative to the distance it covers.
    public static func relativeVelocity(speed: CGFloat, distance: CGFloat) -> Double {
        distance > 1 ? min(Double(speed / distance), maxRelativeVelocity) : 0
    }

    /// The pull a finger takes over from a demo at: an armed card keeps its offset as its pull; a held one is
    /// taken as held short of arming, so the finger still has to pull to arm it.
    public static func takeoverPull(offset: CGSize, armed: Bool, armDistance: CGFloat) -> CGFloat {
        armed ? offset.height : min(max(offset.height, 0) / heldGive, armDistance * 0.8)
    }
}
