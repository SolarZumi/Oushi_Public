// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import OushiCore
import SwiftUI

@main
struct OushiApp: App {
    // Created once for the app's lifetime and handed down through the environment.
    @State private var library: PhotoLibrary
    @State private var images: PhotoImageLoader
    @State private var palettes = PaletteStore()
    @State private var settings: AppSettings
    @State private var review: ReviewSession
    @State private var onboarding: OnboardingFlow
    @State private var favorites: FavoritesController
    @State private var deck: CardDeck
    @State private var pool: PoolController
    @State private var playback = VideoPlaybackController()

    init() {
        let library = PhotoLibrary()
        let images = PhotoImageLoader(library: library)
        let settings = AppSettings()
        var startingAt: OnboardingProgress?
        #if targetEnvironment(simulator)
        // Screenshot poses skip the lessons, for this run only: the simulator keeps its own progress.
        if Showcase.pose != nil { startingAt = .finished }
        #endif
        let onboarding = OnboardingFlow(store: settings, startingAt: startingAt)
        let review = ReviewSession(
            directory: ReviewStorage.directory,
            cloudContainerID: ReviewStorage.cloudContainerID,
            syncEnabled: settings.iCloudSync,
            batchSize: settings.batchSize,
            order: settings.order,
            resolver: PhotoKitIdentityResolver(),
            accounts: CloudKitAccounts(containerID: ReviewStorage.cloudContainerID)
        )
        // A photo leaving the batch because another device saw it: the card fades out and the next comes up.
        review.changeTransaction = { change in withAnimation(Motion.cardChange, change) }
        _library = State(initialValue: library)
        _images = State(initialValue: images)
        _settings = State(initialValue: settings)
        _onboarding = State(initialValue: onboarding)
        _favorites = State(initialValue: FavoritesController(library: library))
        _review = State(initialValue: review)
        _deck = State(initialValue: CardDeck(review: review, onboarding: onboarding))
        _pool = State(initialValue: PoolController(session: review, library: library, images: images))
    }

    var body: some Scene {
        WindowGroup {
            RootView(deck: deck, pool: pool)
                #if targetEnvironment(simulator)
                // Screenshot poses: the home indicator fades away once nothing touches the screen, so it is not in
                // the store images.
                .persistentSystemOverlays(Showcase.pose != nil ? .hidden : .automatic)
                #endif
                .environment(library)
                .environment(images)
                .environment(palettes)
                .environment(settings)
                .environment(review)
                .environment(onboarding)
                .environment(favorites)
                .environment(playback)
        }
    }
}
