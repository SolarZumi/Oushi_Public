// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import SwiftUI

/// What every card in the deck shares: the app's dark card color, continuous rounded corners, and a two-pixel
/// inner edge so the outline reads against the dark ground. Photos, the end-of-batch card, the lessons, the access
/// card and the pool as it grows all go through here, differing only in size, corner radius and what is inside.
enum CardShape {
    /// A photo card's corners.
    static let photoCornerRadius: CGFloat = 24
    /// A system card's corners: the end-of-batch card, a lesson, the access card, the empty library's card.
    static let systemCornerRadius: CGFloat = 42
    /// The card color, the same on every card and under every photo.
    static let ground = Color(uiColor: .secondarySystemBackground)
    /// The padding a system card keeps around its words.
    static let systemPadding: CGFloat = 28

    /// A system card's size: golden ratio, fitted in the deck's bounds; upright where the deck is taller than
    /// wide, lying down where it is wider (the phone held sideways), so the card uses the room it has.
    static func systemSize(in bounds: CGSize) -> CGSize {
        let phi = (1 + 5.0.squareRoot()) / 2
        return fittedSize(aspectRatio: bounds.width > bounds.height ? phi : 1 / phi, in: bounds)
    }

    /// A system card's inner padding, tighter on a short card.
    static func systemPadding(for size: CGSize) -> CGFloat {
        size.height < 320 ? 16 : systemPadding
    }

    /// The deck is wide and short (sideways): system cards lay their content out more compactly.
    static func isCompact(_ bounds: CGSize) -> Bool {
        systemSize(in: bounds).height < 320
    }
}

extension EnvironmentValues {
    /// The app is leaving the foreground (the swipe toward the app switcher begins, a call comes in): every card
    /// hides what it shows under the card color, so the switcher's snapshot shows a plain card. Set once, over the
    /// deck and the pool, and honored by every card through `CardFrame`.
    @Entry var cardsCovered = false
}

/// `content` at a fixed size on the card ground, cut to the card's corners, with the card's edge. The size and the
/// radius are the card's two parameters; animating either morphs the card. Out of the foreground the content
/// dissolves into blur under the card color, whatever it is (a photo, a video, the pool's grid, a lesson's words),
/// and focuses again on return: one behavior for every card.
struct CardFrame<Content: View>: View {
    let size: CGSize
    let cornerRadius: CGFloat
    /// The inner edge; off while the pool card fills the screen, where there is nothing to read it against.
    var showsEdge = true
    @ViewBuilder let content: Content

    @Environment(\.displayScale) private var displayScale
    @Environment(\.cardsCovered) private var isCovered

    var body: some View {
        content
            .blur(radius: isCovered ? 24 : 0)
            .overlay {
                CardShape.ground.opacity(isCovered ? 1 : 0)
            }
            .frame(width: size.width, height: size.height)
            .background(CardShape.ground)
            .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(showsEdge ? 0.1 : 0), lineWidth: 2 / displayScale)
            }
    }
}

/// A system card's content in the system card's size: a lesson, the access card, the empty library's card.
struct SystemCard<Content: View>: View {
    /// Size of the area the deck lays cards out in.
    let bounds: CGSize
    @ViewBuilder let content: Content

    var body: some View {
        let size = CardShape.systemSize(in: bounds)
        CardFrame(size: size, cornerRadius: CardShape.systemCornerRadius) {
            content.padding(CardShape.systemPadding(for: size))
        }
    }
}
