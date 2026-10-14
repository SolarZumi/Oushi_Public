// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import Observation
import OushiCore
import SwiftUI

/// The deletion pool: the queued photos the app can see, newest first; the pool's opening over the screen out
/// of the card on top (never out of a button), its selection, and its shrinking back; and the restoring and
/// deleting done from it.
///
/// Opening: the first screen of photos is brought into memory first (waiting a moment at most), so the grid
/// grows with its photos in their cells rather than photos arriving behind it. The overlay is then mounted at
/// the card's size and grows to the screen once it is on screen; the system grid takes over from the preview
/// once the growth has settled (the grid is opaque and laid out on the same pixels, so nothing of the swap can
/// show). Closing runs it back. Each step waits for its animation to be fully removed, not just logically done,
/// so the frame is exactly at rest before the next thing happens.
@MainActor
@Observable
final class PoolController {
    enum Phase: Equatable {
        case closed
        /// The first photos are being brought into memory; the overlay is not up yet.
        case warming
        /// The overlay is up at the card's size, or growing.
        case opening
        case open
        case closing
    }

    private(set) var phase: Phase = .closed
    /// The layout the card is heading for; flipped inside the growth and shrink animations.
    private(set) var isExpanded = false
    /// The system grid is (fading) in over the preview.
    private(set) var showsLiveGrid = false
    /// What the pool grows out of, which decides what the overlay shows while it is still card-sized.
    private(set) var source: TopCard = .summary
    /// Where the overlay last stood at the card's size, kept for the shrink back should the card's anchor be gone.
    var lastOrigin: CGRect = .zero
    /// Queued photos the app can see, newest first.
    private(set) var pendingIDs: [String] = []
    private(set) var isDeleting = false
    var isSelecting = false
    var selection: Set<String> = []

    @ObservationIgnored private let session: ReviewSession
    @ObservationIgnored private let library: PhotoLibrary
    @ObservationIgnored private let images: PhotoImageLoader
    @ObservationIgnored private var warmingTask: Task<Void, Never>?
    /// Bumped by every growth and shrink, so the completion of one that was turned around does nothing.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var sorting: Task<Void, Never>?

    /// How long the opening waits for the first photos at most.
    private static let warmingLimit: Duration = .milliseconds(200)
    /// The pool's photos on screen as it opens, in either layout, and a few screens more.
    private static let firstScreen = 48

    init(session: ReviewSession, library: PhotoLibrary, images: PhotoImageLoader) {
        self.session = session
        self.library = library
        self.images = images
        // Sorted once per change of the pool or the library, for the summary card and the grid. The loop holds
        // the controller weakly and ends once it is gone.
        sorting = Task { [weak self] in
            let changes = Observations<Bool, Never> { [weak self] in
                guard let self else { return false }
                _ = (self.session.pendingIDs, self.library.structureRevision)
                return true
            }
            for await alive in changes {
                guard alive, let self else { return }
                self.sortPendingIDs()
            }
        }
    }

    /// The overlay exists: growing, open, or shrinking.
    var isPresented: Bool { phase == .opening || phase == .open || phase == .closing }

    /// The selection while selecting, else the whole pool.
    var targets: [String] {
        isSelecting ? pendingIDs.filter(selection.contains) : pendingIDs
    }

    /// The pool's photos on screen as it opens, worth keeping decoded.
    var firstScreen: [String] { Array(pendingIDs.prefix(Self.firstScreen)) }

    private func sortPendingIDs() {
        let sorted = session.pendingIDs
            .compactMap(library.asset(for:))
            .sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
            .map(\.localIdentifier)
        if sorted != pendingIDs {
            pendingIDs = sorted
            selection.formIntersection(sorted)
            if sorted.isEmpty { isSelecting = false }
        }
    }

    // MARK: Opening and closing

    /// Opens the pool out of `source` once the first screen of its photos is in memory. Asked while the pool is
    /// still shrinking back, it turns around and grows again from where it is. The card is chosen when the pool
    /// opens, not when the button was tapped: a swipe in between moves on.
    func open(from source: @escaping () -> TopCard, imageSide: CGFloat) {
        if phase == .closing {
            phase = .opening
            grow()
            return
        }
        guard phase == .closed else { return }
        phase = .warming
        let ids = firstScreen
        warmingTask = Task { [weak self] in
            if imageSide > 0 {
                let side = imageSide
                await self?.images.warm(ids, targetSize: CGSize(width: side, height: side), waitingUpTo: Self.warmingLimit)
            }
            guard let self, !Task.isCancelled, self.phase == .warming else { return }
            self.present(from: source())
        }
    }

    private func present(from source: TopCard) {
        self.source = source
        isSelecting = false
        selection = []
        isExpanded = false
        showsLiveGrid = false
        phase = .opening
        // The overlay is laid out compact first and grows once it is on screen (`overlayAppeared`), so the
        // growth animates from where it starts. Grown on the next turn of the run loop instead, it could at times
        // be grown before its first frame was drawn, and would then merely fade in at full size.
    }

    /// The overlay has been laid out at the card's size: now it grows.
    func overlayAppeared() {
        guard phase == .opening, !isExpanded else { return }
        grow()
    }

    private func grow() {
        generation += 1
        let generation = generation
        withAnimation(Motion.poolGrow, completionCriteria: .removed) {
            isExpanded = true
        } completion: { [self] in
            guard self.generation == generation, phase == .opening else { return }
            phase = .open
            // The grid is laid out by the same metrics as the preview, pixel for pixel, so it can simply take over.
            showsLiveGrid = true
        }
    }

    /// Asked while the pool is still growing, it turns around and shrinks back from where it is; asked while the
    /// photos are still being warmed, the opening is called off.
    func dismiss() {
        if phase == .warming {
            warmingTask?.cancel()
            warmingTask = nil
            phase = .closed
            lastOrigin = .zero
            return
        }
        guard phase == .open || phase == .opening else { return }
        phase = .closing
        generation += 1
        let generation = generation
        withAnimation(Motion.poolShrink, completionCriteria: .removed) {
            // The live grid fades with the shrink (its touches end at once): scrolled, it shows other rows than
            // the preview beneath, which begins at the top, and gone at once it would jump to them.
            showsLiveGrid = false
            isExpanded = false
            isSelecting = false
            selection = []
        } completion: { [self] in
            if self.generation == generation, phase == .closing {
                phase = .closed
                lastOrigin = .zero
            }
        }
    }

    /// Not animated: the bar's words change at once, as the system's own do.
    func toggleSelecting() {
        isSelecting.toggle()
        selection.removeAll()
    }

    // MARK: Restoring and deleting

    func restore(_ ids: [String]) {
        guard !isDeleting else { return }
        session.removeFromPool(ids: ids)
        selection.subtract(ids)
    }

    /// The system asks for confirmation before anything is deleted. What the library would not delete stays
    /// selected, and the library says so.
    func delete(_ ids: [String]) {
        guard !isDeleting else { return }
        isDeleting = true
        Task {
            if let deleted = await session.deleteFromLibrary(ids: ids, using: { await library.deleteAssets(ids: $0) }) {
                selection.subtract(deleted)
            }
            isDeleting = false
        }
    }
}
