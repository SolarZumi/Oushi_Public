// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import QuartzCore

/// Calls back once per display frame, on the main actor, with the time since the last frame: for motion that has
/// to run by hand (a throw's physics) in step with the screen rather than on a timer.
@MainActor
final class FrameClock {
    private var link: CADisplayLink?
    private var tick: ((TimeInterval) -> Bool)?
    private var lastTimestamp: CFTimeInterval?

    /// Starts calling `tick` every frame until it returns false or `stop()` is called. A frame that comes long after
    /// the last (the app was away) counts as one ordinary frame.
    func start(_ tick: @escaping (TimeInterval) -> Bool) {
        stop()
        self.tick = tick
        lastTimestamp = nil
        let link = CADisplayLink(target: Target(self), selector: #selector(Target.frame(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        tick = nil
    }

    var isRunning: Bool { link != nil }

    /// Returns once the display has drawn its next frame: for an animation that must start only after the screen
    /// is updating again (on the way back from the background).
    static func nextFrame() async {
        let clock = FrameClock()
        await withCheckedContinuation { continuation in
            clock.start { _ in
                continuation.resume()
                return false
            }
        }
    }

    private func frame(timestamp: CFTimeInterval) {
        let elapsed = lastTimestamp.map { min(max(timestamp - $0, 0), 0.05) } ?? 1.0 / 120
        lastTimestamp = timestamp
        if tick?(elapsed) != true { stop() }
    }

    /// The display link's target: an object of its own, so the link does not keep the clock alive.
    private final class Target: NSObject {
        private weak var clock: FrameClock?

        init(_ clock: FrameClock) {
            self.clock = clock
        }

        @MainActor @objc func frame(_ link: CADisplayLink) {
            guard let clock else {
                link.invalidate()
                return
            }
            clock.frame(timestamp: link.timestamp)
        }
    }
}
