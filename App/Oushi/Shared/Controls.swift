// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import SwiftUI

/// A glass capsule ground, following the capsule's size as it animates.
struct GlassCapsule: ViewModifier {
    /// Whether the glass answers a touch with its highlight and swell: yes for a button, no for a mere container.
    var interactive = true

    func body(content: Content) -> some View {
        content.glassEffect(interactive ? .regular.interactive() : .regular, in: .capsule)
    }
}

/// The system's Liquid Glass button in a pill.
struct GlassPillButton: ViewModifier {
    func body(content: Content) -> some View {
        content
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
    }
}
