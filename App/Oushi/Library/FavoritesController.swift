// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import Observation

/// Favorites as the heart shows them: a tap fills or empties the heart at once and the library saves in the
/// background; the heart stays as tapped until the library agrees, reverting only if saving fails. A tap while a
/// save is under way is kept and saved after it (the latest value wins). On a system card (a lesson, the access
/// card) the heart works for show: it fills and empties and saves nothing.
@MainActor
@Observable
final class FavoritesController {
    /// What each card's heart was tapped to, by card: a photo's entry goes once the library agrees; a system
    /// card's stays, there being nothing to agree.
    private var tapped: [String: Bool] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private let library: PhotoLibrary

    @ObservationIgnored private var watching: Task<Void, Never>?

    init(library: PhotoLibrary) {
        self.library = library
        // The library's changes land whatever is on screen; entries it has caught up with are done.
        watching = Task { [weak self] in
            let changes = Observations<Int?, Never> { [weak self] in self?.library.changeRevision }
            for await revision in changes {
                guard revision != nil, let self else { return }
                self.reconcile()
            }
        }
    }

    /// The heart for a card: the photo's favorite as last tapped or as the library has it; a system card's as
    /// tapped, never filled to begin with.
    func isFavorite(photoID: String?, cardID: String?) -> Bool {
        if let cardID, let value = tapped[cardID] { return value }
        return photoID.flatMap { library.asset(for: $0)?.isFavorite } ?? false
    }

    /// Flips the heart for a card and, for a photo, saves it. Returns the new value.
    @discardableResult
    func toggle(photoID: String?, cardID: String) -> Bool {
        let favorite = !isFavorite(photoID: photoID, cardID: cardID)
        tapped[cardID] = favorite
        if let photoID { save(photoID) }
        return favorite
    }

    /// The library reported changes: entries it has caught up with are done. Not one whose save is under way:
    /// the library still shows the old value then, which a second tap may have come back to, and the entry must
    /// stay for that tap to be saved after.
    func reconcile() {
        for (id, value) in tapped where !inFlight.contains(id) && library.asset(for: id)?.isFavorite == value { tapped[id] = nil }
    }

    /// Saves the value last tapped for `id`; if a tap changed it again while saving, saves again after.
    private func save(_ id: String) {
        guard !inFlight.contains(id), let wanted = tapped[id] else { return }
        inFlight.insert(id)
        Task {
            let saved = await library.setFavorite(wanted, id: id)
            inFlight.remove(id)
            if !saved {
                if tapped[id] == wanted { tapped[id] = nil }
            } else if let again = tapped[id], again != wanted {
                save(id)
            }
        }
    }
}
