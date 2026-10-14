// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import Foundation

/// A value gliding to its target on a critically damped spring: no overshoot, retargeting keeps the velocity, so a
/// run of changes is one continuous glide. Stepped by whoever drives it (a display link); pure arithmetic here.
public struct CriticallyDampedSpring: Equatable, Sendable {
    public var value: Double
    public var velocity: Double = 0
    public var target: Double

    public init(value: Double) {
        self.value = value
        target = value
    }

    /// The spring's rate for a given settling time (the time to get close to the target).
    public static func omega(settleTime: Double) -> Double {
        2 * .pi / settleTime
    }

    /// Whether the value is at its target and still.
    public var isSettled: Bool {
        abs(value - target) < 0.0005 && abs(velocity) < 0.005
    }

    /// Advances by `elapsed` seconds at rate `omega`. Returns whether the spring has settled; a settled spring sits
    /// exactly on its target.
    @discardableResult
    public mutating func step(elapsed: TimeInterval, omega: Double) -> Bool {
        // Exact step of a critically damped spring toward the target.
        let offset = value - target
        let decay = exp(-omega * elapsed)
        let next = (offset + (velocity + omega * offset) * elapsed) * decay
        velocity = (velocity - omega * (velocity + omega * offset) * elapsed) * decay
        if abs(next) < 0.0005, abs(velocity) < 0.005 {
            value = target
            velocity = 0
            return true
        }
        value = target + next
        return false
    }

    /// Sets the value with no motion.
    public mutating func jump(to value: Double) {
        self.value = value
        target = value
        velocity = 0
    }
}
