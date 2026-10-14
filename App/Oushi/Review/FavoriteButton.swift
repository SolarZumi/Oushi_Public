// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import SwiftUI

/// The heart in the bottom bar. Its own view with its own state, so a tap redraws only the heart. What the heart
/// means, and the saving, is `FavoritesController`'s; this draws it, animates the change under the finger, and
/// taps along.
struct FavoriteButton: View {
    let photoID: String?
    /// A system card on top, standing in for a photo.
    var pretendID: String? = nil

    @Environment(FavoritesController.self) private var favorites
    @Environment(AppSettings.self) private var settings
    /// The card whose heart was tapped; only its change animates.
    @State private var animatedID: String?
    /// Bumped on every tap, for the tap under the finger; on every fill, for the bounce.
    @State private var taps = 0
    @State private var bounces = 0

    /// The card the heart is about: the photo, or the system card standing in for one.
    private var cardID: String? { photoID ?? pretendID }
    private var isFavorite: Bool {
        #if targetEnvironment(simulator)
        if Showcase.pose == .favorite, photoID != nil { return true }
        #endif
        return favorites.isFavorite(photoID: photoID, cardID: cardID)
    }
    private var animates: Bool { animatedID != nil && animatedID == cardID }

    var body: some View {
        Button(action: toggle) {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .foregroundStyle(isFavorite ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                .modifier(HeartSymbolTransition(isEnabled: animates))
                .symbolEffect(.bounce, value: bounces)
                // Switching cards inside a swipe's animation must not animate the heart either.
                .animation(nil, value: cardID)
        }
        .disabled(cardID == nil)
        .accessibilityLabel(isFavorite ? String(localized: "取消收藏") : String(localized: "收藏"))
        // A firmer tap when the heart fills, a softer one when it empties; none if the user wants no taps.
        .sensoryFeedback(trigger: taps) { _, _ in
            guard settings.hapticsEnabled else { return nil }
            return isFavorite ? .impact(weight: .medium, intensity: 0.9) : .impact(flexibility: .soft, intensity: 0.7)
        }
        .onChange(of: cardID) { animatedID = nil }
    }

    private func toggle() {
        guard let cardID else { return }
        animatedID = cardID
        taps += 1
        if favorites.toggle(photoID: photoID, cardID: cardID) { bounces += 1 }
    }
}

/// The system's heart animation: Magic Replace fills and empties the heart in place.
private struct HeartSymbolTransition: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content.contentTransition(.symbolEffect(.replace.magic(fallback: .downUp.byLayer), options: .nonRepeating))
        } else {
            content.contentTransition(.identity)
        }
    }
}
