// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import Foundation
import Observation
import OushiCore

/// A value that glides to its target on a critically damped spring, driven by the display's refresh while moving
/// and idle otherwise. Retargeting keeps the current velocity, so a run of changes is one continuous glide.
@MainActor
@Observable
final class SpringValue {
    private(set) var value: Double = 0

    @ObservationIgnored private var spring = CriticallyDampedSpring(value: 0)
    @ObservationIgnored private var lastFollow: (value: Double, time: TimeInterval)?
    @ObservationIgnored private let clock = FrameClock()
    @ObservationIgnored private let omega: Double
    /// The spring's rate while gliding across a gap under a finger: unhurried, so it reads as motion.
    @ObservationIgnored private let catchUpOmega: Double
    @ObservationIgnored private var isCatchingUp = false

    init(settleTime: Double, catchUpTime: Double = 0.3) {
        omega = CriticallyDampedSpring.omega(settleTime: settleTime)
        catchUpOmega = CriticallyDampedSpring.omega(settleTime: catchUpTime)
    }

    /// Sets the value with no motion.
    func jump(to value: Double) {
        clock.stop()
        spring.jump(to: value)
        self.value = value
        lastFollow = nil
    }

    /// Tracks a value driven from outside (a finger), remembering its speed so a later glide carries it on. A
    /// step too big for a finger's movement between two frames (a finger taking the card over from a demo, say)
    /// is not taken at once: the value glides across it on its own spring, following the finger as it goes, and
    /// is back under the finger within a third of a second.
    func follow(_ value: Double) {
        let now = Date.timeIntervalSinceReferenceDate
        if let last = lastFollow, now > last.time {
            let measured = (value - last.value) / (now - last.time)
            spring.velocity = spring.velocity * 0.5 + min(max(measured, -4), 4) * 0.5
        }
        lastFollow = (value, now)
        spring.target = value
        if clock.isRunning || abs(value - spring.value) > 0.02 {
            start(catchingUp: true)
        } else {
            clock.stop()
            spring.value = value
            self.value = value
        }
    }

    func animate(to target: Double) {
        spring.target = target
        lastFollow = nil
        guard !spring.isSettled else { return }
        start(catchingUp: false)
    }

    /// Runs the spring toward the target if it is not running; a running one just retargets, so a run of changes
    /// is one continuous glide. `catchingUp` chooses the rate for a gap under a finger.
    private func start(catchingUp: Bool) {
        isCatchingUp = catchingUp
        guard !clock.isRunning else { return }
        clock.start { [weak self] elapsed in
            guard let self else { return false }
            let settled = self.spring.step(elapsed: elapsed, omega: self.isCatchingUp ? self.catchUpOmega : self.omega)
            self.value = self.spring.value
            return !settled
        }
    }
}
