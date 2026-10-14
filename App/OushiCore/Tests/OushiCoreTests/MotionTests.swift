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
    }

    @Test func armingHasHysteresis() {
        let arm = SwipePhysics.armDistance(in: size)
        #expect(arm == 160)
        #expect(!SwipePhysics.isArmed(after: 159, wasArmed: false, armDistance: arm))
        #expect(SwipePhysics.isArmed(after: 160, wasArmed: false, armDistance: arm))
        #expect(SwipePhysics.isArmed(after: 100, wasArmed: true, armDistance: arm), "Armed, the card stays armed above half the distance")
        #expect(!SwipePhysics.isArmed(after: 79, wasArmed: true, armDistance: arm), "And re-holds below it")
    }

    @Test func heldCardGivesALittle() {
        #expect(SwipePhysics.pullOffset(100, armed: false) == 30)
        #expect(SwipePhysics.pullOffset(-100, armed: false) == -15)
        #expect(SwipePhysics.pullOffset(100, armed: true) == 100)
    }

    @Test func progressFollowsTheLargerAxis() {
        #expect(SwipePhysics.progress(of: CGSize(width: -224, height: 0), in: size) == 0.5)
        #expect(SwipePhysics.progress(of: CGSize(width: 0, height: 424), in: size) == 0.5)
        #expect(SwipePhysics.progress(of: CGSize(width: 0, height: -424), in: size) == 0, "An upward pull is no progress")
        #expect(SwipePhysics.progress(of: CGSize(width: 1000, height: 0), in: size) == 1)
        #expect(SwipePhysics.progress(of: .zero, in: .zero) == 0)
    }

    @Test func sidewaysReleaseFlingsOrSettles() throws {
        #expect(SwipePhysics.sidewaysFling(offset: 50, velocity: 0, width: 400) == nil, "A short drag settles")
        let flung = try #require(SwipePhysics.sidewaysFling(offset: 50, velocity: 800, width: 400))
        #expect(flung.direction == .right && flung.speed == 800, "A fast release flings, projected ahead")
        let farLeft = try #require(SwipePhysics.sidewaysFling(offset: -200, velocity: 300, width: 400))
        #expect(farLeft.direction == .left && farLeft.speed == 0, "Speed counts only when the finger moved the card's way")
    }

    @Test func relativeVelocityIsCapped() {
        #expect(SwipePhysics.relativeVelocity(speed: 400, distance: 400) == 1)
        #expect(SwipePhysics.relativeVelocity(speed: 40_000, distance: 400) == 10)
        #expect(SwipePhysics.relativeVelocity(speed: 400, distance: 0) == 0)
    }

    @Test func takeoverKeepsAnArmedPull() {
        let arm = SwipePhysics.armDistance(in: size)
        #expect(SwipePhysics.takeoverPull(offset: CGSize(width: 0, height: 200), armed: true, armDistance: arm) == 200)
        #expect(SwipePhysics.takeoverPull(offset: CGSize(width: 0, height: 30), armed: false, armDistance: arm) == 100, "A held card's offset is read back through its give")
        #expect(SwipePhysics.takeoverPull(offset: CGSize(width: 0, height: 60), armed: false, armDistance: arm) == 128, "But never as a pull that would already arm")
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
