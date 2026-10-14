// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import SwiftUI

/// The app's animations, named: one place to tune the feel, and no duration lives in two files.
enum Motion {
    /// A card going back to its place, and the end of the welcome.
    static let settle = Animation.spring(duration: 0.35, bounce: 0)
    /// Undo bringing a card back, and other brisk moves of a whole card.
    static let undo = Animation.spring(duration: 0.4, bounce: 0)
    /// The access card coming or going, a new batch coming up.
    static let cardChange = Animation.smooth(duration: 0.4)
    /// The cards dissolving into blur on leaving the foreground, and coming back into focus.
    static let cover = Animation.smooth(duration: 0.35)
    static let uncover = Animation.smooth(duration: 0.45)
    /// The welcome's words coming into and going out of focus, and how long after the last lesson's card leaves.
    static let welcomeFade = Animation.smooth(duration: 0.6)
    static let welcomeDelay: Duration = .milliseconds(450)
    /// The first photo coming up once the welcome's words have gone.
    static let welcomeEnd = Animation.spring(duration: 0.45, bounce: 0)
    /// A lesson's card refusing the wrong gesture: straight back where it was, at once, and only then the shake
    /// of its head. The easy return of a card let go would read as nothing having happened.
    static let refuseSnap: TimeInterval = 0.08
    static let refuse = Animation.easeOut(duration: refuseSnap)
    /// A finger taking a card over from a demo, and an armed pull catching up with the finger.
    static let catchUp = Animation.interactiveSpring(duration: 0.18, extraBounce: 0)
    /// A demo card sliding to one side, and easing back.
    static let demoSlide = Animation.spring(duration: 0.5, bounce: 0.15)
    static let demoReturn = Animation.spring(duration: 0.45, bounce: 0)
    static let demoHold = Animation.spring(duration: 0.4, bounce: 0)
    /// The pool growing out of its card to the screen, and shrinking back.
    static let poolGrow = Animation.spring(duration: 0.55, bounce: 0)
    static let poolShrink = Animation.spring(duration: 0.5, bounce: 0)
    /// A fling with Reduce Motion on: the card fades where it is.
    static let reducedFling = Animation.easeOut(duration: 0.2)

    /// A flung card's flight: critically damped (no bounce), starting at the finger's speed relative to the
    /// distance it has to cover.
    static func fling(relativeVelocity: Double) -> Animation {
        .interpolatingSpring(mass: 1, stiffness: 170, damping: 27, initialVelocity: relativeVelocity)
    }
}
