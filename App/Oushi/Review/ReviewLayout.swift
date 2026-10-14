// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import Observation
import SwiftUI

/// Where parts of the review screen are on screen, reported by the views that know and read by those that need
/// to draw in relation to them: the progress capsule's glass, which the welcome's halo pulses out of.
@MainActor
@Observable
final class ReviewLayout {
    /// The capsule's glass in global coordinates; zero until it has been laid out.
    var capsuleFrame: CGRect = .zero
}
