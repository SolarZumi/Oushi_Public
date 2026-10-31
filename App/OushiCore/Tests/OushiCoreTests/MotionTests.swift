// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import Foundation
import Testing
@testable import OushiCore

@Suite("Swipe physics")
struct SwipePhysicsTests {
    private let size = CGSize(width: 400, height: 800)

    @Test func exitsClearTheDeck() {
        #expect(SwipePhysics.exitOffset(.left, in: size) == CGSize(width: -448, height: 0))
        #expect(SwipePhysics.exitOffset(.right, in: size) == CGSize(width: 448, height: 0))
        #expect(SwipePhysics.exitOffset(.down, in: size) == CGSize(width: 0, height: 848))
        #expect(SwipePhysics.exitOffset(.up, in: size) == CGSize(width: 0, height: -848))
        #expect(SwipePhysics.exitOffset(.down, in: size, outside: 100) == CGSize(width: 0, height: 948), "Past the screen beyond the deck too")
        #expect(SwipePhysics.exitOffset(.up, in: size, outside: 120) == CGSize(width: 0, height: -968))
    }

    @Test func armingHasHysteresis() {
        let arm = SwipePhysics.armDistance(in: size, horizontal: false)
        #expect(arm == 70)
        #expect(!SwipePhysics.isArmed(after: 69, wasArmed: false, armDistance: arm))
        #expect(SwipePhysics.isArmed(after: 70, wasArmed: false, armDistance: arm))
        #expect(SwipePhysics.isArmed(after: 40, wasArmed: true, armDistance: arm), "Armed, the card stays armed above half the distance")
        #expect(!SwipePhysics.isArmed(after: 34, wasArmed: true, armDistance: arm), "And re-holds below it")
        #expect(SwipePhysics.armDistance(in: CGSize(width: 1000, height: 1300), horizontal: false) == 70, "The same reach on a tall deck")
    }

    @Test func sidewaysPullsArmAtTheSameDistanceUnlessTheDeckIsNarrow() {
        #expect(SwipePhysics.armDistance(in: CGSize(width: 1000, height: 800), horizontal: true) == 70)
        #expect(SwipePhysics.armDistance(in: CGSize(width: 150, height: 800), horizontal: true) == 60)
    }

    @Test func eachWayMovesTheCardByWhatItDoes() {
        #expect(SwipePhysics.offset(travel: 100, action: .keep, armed: false) == 100, "Keeping follows the finger")
        #expect(SwipePhysics.offset(travel: -100, action: .queue, armed: false) == -30, "A held pull gives a little, either way")
        #expect(SwipePhysics.offset(travel: 100, action: .queue, armed: true) == 100, "An armed pull follows the finger")
        #expect(SwipePhysics.offset(travel: -100, action: nil, armed: false) == -15, "A way that does nothing gives less")
    }

    @Test func progressFollowsTheLargerAxisEitherWay() {
        #expect(SwipePhysics.progress(of: CGSize(width: -224, height: 0), in: size) == 0.5)
        #expect(SwipePhysics.progress(of: CGSize(width: 0, height: 424), in: size) == 0.5)
        #expect(SwipePhysics.progress(of: CGSize(width: 0, height: -424), in: size) == 0.5, "Upward counts as much as downward")
        #expect(SwipePhysics.progress(of: CGSize(width: 1000, height: 0), in: size) == 1)
        #expect(SwipePhysics.progress(of: .zero, in: .zero) == 0)
    }

    @Test func aWayThatDoesNothingIsNoProgress() {
        let gestures = SwipeGestures()
        #expect(SwipePhysics.progress(of: CGSize(width: 0, height: -424), in: size, gestures: gestures) == 0, "Up does nothing by default")
        #expect(SwipePhysics.progress(of: CGSize(width: 0, height: 424), in: size, gestures: gestures) == 0.5)
        #expect(SwipePhysics.progress(of: CGSize(width: 224, height: 0), in: size, gestures: SwipeGestures(sideways: .left)) == 0,
                "Right does nothing when only left skips")
        #expect(SwipePhysics.progress(of: CGSize(width: 0, height: -424), in: size, gestures: SwipeGestures(upDown: .up)) == 0.5)
    }

    @Test func releaseFlingsOrSettles() throws {
        let distance = SwipePhysics.flingDistance(in: size, horizontal: true)
        #expect(distance == 70)
        #expect(SwipePhysics.flingDistance(in: size, horizontal: false) == 70, "Up and down goes as far")
        #expect(distance == SwipePhysics.armDistance(in: size, horizontal: true), "Skipping goes as far as deleting arms")
        #expect(SwipePhysics.fling(offset: 50, velocity: 0, distance: distance) == nil, "A short drag settles")
        let flung = try #require(SwipePhysics.fling(offset: 50, velocity: 800, distance: distance))
        #expect(flung.towardPositive && flung.speed == 800, "A fast release flings, projected ahead")
        let back = try #require(SwipePhysics.fling(offset: -200, velocity: 300, distance: distance))
        #expect(!back.towardPositive && back.speed == 0, "Speed counts only when the finger moved the card's way")
    }

    @Test func relativeVelocityIsCapped() {
        #expect(SwipePhysics.relativeVelocity(speed: 400, distance: 400) == 1)
        #expect(SwipePhysics.relativeVelocity(speed: 40_000, distance: 400) == 10)
        #expect(SwipePhysics.relativeVelocity(speed: 400, distance: 0) == 0)
    }

    @Test func takeoverKeepsAnArmedPull() {
        let arm = SwipePhysics.armDistance(in: size, horizontal: false)
        #expect(SwipePhysics.takeoverTravel(offset: 200, action: .queue, armed: true, armDistance: arm) == 200)
        #expect(SwipePhysics.takeoverTravel(offset: 15, action: .queue, armed: false, armDistance: arm) == 50, "A held card's offset is read back through its give")
        #expect(SwipePhysics.takeoverTravel(offset: -60, action: .queue, armed: false, armDistance: arm) == -56, "But never as a pull that would already arm, either way")
        #expect(SwipePhysics.takeoverTravel(offset: -72, action: .keep, armed: false, armDistance: arm) == -72, "A card that follows the finger is where it is")
    }
}

@Suite("Swipe gestures")
struct SwipeGesturesTests {
    @Test func defaultsKeepSidewaysAndQueueDown() {
        let gestures = SwipeGestures()
        #expect(gestures.action(for: .left) == .keep && gestures.action(for: .right) == .keep)
        #expect(gestures.action(for: .down) == .queue)
        #expect(gestures.action(for: .up) == nil, "Up does nothing unless chosen")
        #expect(gestures.directions(for: .keep) == [.left, .right] && gestures.directions(for: .queue) == [.down])
    }

    @Test func eachChoiceLimitsItsAxis() {
        let gestures = SwipeGestures(sideways: .right, upDown: .either)
        #expect(gestures.action(for: .left) == nil && gestures.action(for: .right) == .keep)
        #expect(gestures.action(for: .up) == .queue && gestures.action(for: .down) == .queue)
        #expect(SwipeGestures(upDown: .up).directions(for: .queue) == [.up])
    }

    @Test func swappingTradesTheActionsNotTheDirections() {
        let gestures = SwipeGestures(sideways: .left, upDown: .up, swapped: true)
        #expect(gestures.action(for: .left) == .queue && gestures.action(for: .right) == nil)
        #expect(gestures.action(for: .up) == .keep && gestures.action(for: .down) == nil)
        #expect(gestures.directions(for: .keep) == [.up] && gestures.directions(for: .queue) == [.left])
    }

    @Test func undoReturnsTheWaysTheSettingsNowAllow() {
        #expect(SwipeGestures().returnDirection(for: .keep, leftBy: .right) == .right, "A way still allowed is kept")
        #expect(SwipeGestures(sideways: .left).returnDirection(for: .keep, leftBy: .right) == .left,
                "Kept to the right, but only left keeps now: it comes back from the left")
        #expect(SwipeGestures(upDown: .up).returnDirection(for: .queue, leftBy: .down) == .up, "Queueing moved upward")
        let swapped = SwipeGestures(sideways: .either, upDown: .either, swapped: true)
        #expect(swapped.returnDirection(for: .keep, leftBy: .left) == .up, "Kept sideways, keeping is up and down now: left goes with up")
        #expect(swapped.returnDirection(for: .keep, leftBy: .right) == .down)
        #expect(swapped.returnDirection(for: .queue, leftBy: .down) == .right, "Queued downward, queueing is sideways now")
        #expect(SwipeGestures(sideways: .left, swapped: true).returnDirection(for: .queue, leftBy: .down) == .left,
                "With one way left, that way")
        #expect(SwipeGestures().returnDirection(for: .keep, leftBy: nil) == nil, "A step without a direction stays without")
    }

    @Test func eachActionNamesOneWay() {
        #expect(SwipeGestures().direction(for: .keep) == .right && SwipeGestures().direction(for: .queue) == .down)
        #expect(SwipeGestures(sideways: .left, upDown: .up, swapped: true).direction(for: .keep) == .up)
        #expect(SwipeGestures(sideways: .left, upDown: .up, swapped: true).direction(for: .queue) == .left)
    }
}

@Suite("Critically damped spring")
struct CriticallyDampedSpringTests {
    @Test func settlesWithoutOvershoot() {
        var spring = CriticallyDampedSpring(value: 0)
        spring.target = 1
        let omega = CriticallyDampedSpring.omega(settleTime: 0.25)
        var highest = 0.0
        var frames = 0
        while !spring.step(elapsed: 1.0 / 120, omega: omega), frames < 1000 {
            highest = max(highest, spring.value)
            frames += 1
        }
        #expect(spring.isSettled && spring.value == 1)
        #expect(highest <= 1, "No overshoot")
        #expect(frames < 120, "Settled within a second at 120 frames per second")
    }

    @Test func retargetingKeepsVelocity() {
        var spring = CriticallyDampedSpring(value: 0)
        spring.target = 1
        let omega = CriticallyDampedSpring.omega(settleTime: 0.25)
        for _ in 0..<6 { spring.step(elapsed: 1.0 / 120, omega: omega) }
        let velocity = spring.velocity
        #expect(velocity > 0)
        spring.target = 2
        spring.step(elapsed: 1.0 / 120, omega: omega)
        #expect(spring.velocity > velocity * 0.9, "A new target does not stop the motion")
        spring.jump(to: 5)
        #expect(spring.value == 5 && spring.velocity == 0 && spring.isSettled)
    }
}
