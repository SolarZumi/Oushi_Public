// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import Foundation

/// The review as a whole: the ledger of every photo and video plus the batch on screen, and the moves that touch
/// both. A plain value; the session owns one and persists its two halves together.
public struct ReviewState: Equatable, Sendable {
    public var ledger: ReviewLedger
    public var batch: ReviewBatch

    /// The default; the session may ask for another size.
    public static let batchSize = 15

    /// One photo's record before and after a move.
    public struct Change: Equatable, Sendable {
        public let id: String
        public let before: PhotoRecord
        public let after: PhotoRecord

        public init(id: String, before: PhotoRecord, after: PhotoRecord) {
            self.id = id
            self.before = before
            self.after = after
        }
    }

    public init(ledger: ReviewLedger = ReviewLedger(), batch: ReviewBatch = ReviewBatch()) {
        self.ledger = ledger
        self.batch = batch
    }

    /// Sideways swipes keep the photo (delete=false), taking it out of the pool should another device have put it
    /// there meanwhile; a downward swipe queues it.
    @discardableResult
    public mutating func advance(delete: Bool, direction: SwipeDirection? = nil, at date: Date = .now) -> Change? {
        guard let id = batch.currentID else { return nil }
        let before = ledger[id]
        ledger.markSeen(id, at: date)
        ledger.setPending(id, delete, at: date)
        batch.advance(ReviewBatch.Step(id: id, previous: before, direction: direction, produced: ledger[id]))
        return Change(id: id, before: before, after: ledger[id])
    }

    /// Steps back to the last photo swiped and puts its record back the way it was. A record that is no longer
    /// what the swipe left (another device's earlier move replaced it) is that device's word: it stands, and only
    /// the position goes back, for the photo to be decided again knowing it.
    @discardableResult
    public mutating func undo() -> Change? {
        guard let step = batch.undo() else { return nil }
        let before = ledger[step.id]
        if let produced = step.produced, SyncedValue(before) != SyncedValue(produced) {
            return Change(id: step.id, before: before, after: before)
        }
        ledger.restore(step.previous)
        return Change(id: step.id, before: before, after: ledger[step.id])
    }

    /// Starts a fresh batch, led by `first` when given (the simulator's screenshot poses ask for one). Undo does
    /// not reach back into the batch before.
    public mutating func startNextBatch(availableIDs: [String], first: String? = nil, order: ReviewOrder = .random, count: Int = batchSize, using generator: inout some RandomNumberGenerator) {
        var ids = ledger.nextBatch(from: availableIDs.filter { $0 != first }, count: count, order: order, using: &generator)
        if let first, availableIDs.contains(first) {
            ids = [first] + ids.prefix(max(count - 1, 0))
        }
        batch = ReviewBatch(ids: ids)
    }

    public mutating func startNextBatch(availableIDs: [String], first: String? = nil, order: ReviewOrder = .random, count: Int = batchSize) {
        var generator = SystemRandomNumberGenerator()
        startNextBatch(availableIDs: availableIDs, first: first, order: order, count: count, using: &generator)
    }

    /// Brings the batch to `count` at once: a larger count adds the next photos in `order` (a finished batch thereby
    /// goes on); a smaller one ends the batch at the current photo (a finished one is already ended).
    public mutating func resizeBatch(to count: Int, availableIDs: [String], order: ReviewOrder) {
        guard !batch.ids.isEmpty else { return }
        if count > batch.ids.count {
            let present = Set(batch.ids)
            let extra = ledger.nextBatch(from: availableIDs.filter { !present.contains($0) }, count: count - batch.ids.count, order: order)
            batch.append(extra)
        } else if count < batch.ids.count {
            batch.endAfterCurrent()
        }
    }

    /// Takes the photos still to come, after the current one, from the library again in `order`, up to `count` in
    /// the batch: the next photo is the first there is in that order, not the first of those the batch happened
    /// to hold. What has been reviewed, and the current photo, stay as they are.
    public mutating func refillRemaining(availableIDs: [String], order: ReviewOrder, count: Int) {
        guard batch.currentID != nil else { return }
        let kept = Set(batch.ids.prefix(batch.cursor + 1))
        let room = count == Int.max ? Int.max : max(count - kept.count, 0)
        let rest = ledger.nextBatch(from: availableIDs.filter { !kept.contains($0) }, count: room, order: order)
        batch.replaceRemaining(with: rest)
    }

    /// Fits the batch to the photos the app can see, and starts one if there is none. The ledger is left alone:
    /// under limited access a missing photo is merely hidden, and the session decides what missing means.
    public mutating func fit(availableIDs: [String], order: ReviewOrder = .random, count: Int = batchSize) {
        batch.fit(to: Set(availableIDs))
        if batch.ids.isEmpty { startNextBatch(availableIDs: availableIDs, order: order, count: count) }
    }

    /// Takes a photo out of the deletion pool by hand; it stays seen.
    @discardableResult
    public mutating func restoreFromPool(_ id: String, at date: Date = .now) -> Change? {
        let before = ledger[id]
        guard before.pendingSince != nil else { return nil }
        ledger.setPending(id, false, at: date)
        batch.forgetPendingState(of: id)
        return Change(id: id, before: before, after: ledger[id])
    }
}
