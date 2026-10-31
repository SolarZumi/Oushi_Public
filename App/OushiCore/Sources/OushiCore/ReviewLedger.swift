// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import Foundation

/// Every photo the app has an opinion about: seen when, queued for deletion since when. Long-lived and growing
/// with the library, unlike the batch on screen. Persisted record by record: `takeJournal()` hands the store the
/// records changed since the last write, so a swipe writes one row, not the whole history.
public struct ReviewLedger: Sendable {
    public private(set) var records: [String: PhotoRecord] = [:]
    public private(set) var seenIDs: Set<String> = []
    public private(set) var pendingIDs: Set<String> = []
    public private(set) var journal = Journal()

    /// Records changed or removed since the journal was last taken, and what each was before its first change.
    public struct Journal: Equatable, Sendable {
        public var upserted: Set<String>
        public var removed: Set<String>
        /// Each changed record as it stood before the first change since the journal was last taken (a blank
        /// record for one that was not there): what the device knew when it moved.
        public var before: [String: PhotoRecord]

        public init(upserted: Set<String> = [], removed: Set<String> = [], before: [String: PhotoRecord] = [:]) {
            self.upserted = upserted
            self.removed = removed
            self.before = before
        }

        public var isEmpty: Bool { upserted.isEmpty && removed.isEmpty }

        /// Folds a later journal into this one: a record's later fate wins; what it was first stays.
        public mutating func merge(_ other: Journal) {
            upserted.subtract(other.removed)
            removed.subtract(other.upserted)
            upserted.formUnion(other.upserted)
            removed.formUnion(other.removed)
            before.merge(other.before) { mine, _ in mine }
        }
    }

    public init(records: [PhotoRecord] = []) {
        for record in records where !record.isBlank {
            self.records[record.id] = record
            if record.seenAt != nil { seenIDs.insert(record.id) }
            if record.pendingSince != nil { pendingIDs.insert(record.id) }
        }
    }

    public subscript(id: String) -> PhotoRecord {
        records[id] ?? PhotoRecord(id: id)
    }

    public mutating func markSeen(_ id: String, at date: Date) {
        var record = self[id]
        record.seenAt = date
        set(record)
    }

    public mutating func setPending(_ id: String, _ pending: Bool, at date: Date) {
        var record = self[id]
        record.pendingSince = pending ? (record.pendingSince ?? date) : nil
        set(record)
    }

    /// Puts a record back the way it was, for undo, or takes a record in from elsewhere (another device's).
    public mutating func restore(_ record: PhotoRecord) {
        set(record)
    }

    /// Moves a record to the local identifier its photo has now, after the old one stopped matching.
    public mutating func relink(_ id: String, to newID: String) {
        guard id != newID, var record = records[id] else { return }
        forget([id])
        record.id = newID
        set(record)
    }

    public mutating func forget(_ ids: some Sequence<String>) {
        for id in ids where records[id] != nil {
            remember(id)
            records[id] = nil
            seenIDs.remove(id)
            pendingIDs.remove(id)
            journal.upserted.remove(id)
            journal.removed.insert(id)
        }
    }

    /// The record as it is now, before a change, kept for the journal once per round.
    private mutating func remember(_ id: String) {
        if journal.before[id] == nil { journal.before[id] = self[id] }
    }

    /// Drops every "seen" mark except the pool's: a photo waiting to be deleted was seen on its way in, stays out
    /// of the batches regardless, and must not count as unseen afterward.
    public mutating func forgetSeen() {
        for id in seenIDs where !pendingIDs.contains(id) {
            var record = self[id]
            record.seenAt = nil
            set(record)
        }
    }

    /// Takes a record in as the store already has it (read back, or arrived from another device): nothing to
    /// journal. A blank record takes the photo's record away.
    public mutating func adopt(_ record: PhotoRecord) {
        let id = record.id
        if record.isBlank {
            records[id] = nil
            seenIDs.remove(id)
            pendingIDs.remove(id)
        } else {
            records[id] = record
            if record.seenAt != nil { seenIDs.insert(id) } else { seenIDs.remove(id) }
            if record.pendingSince != nil { pendingIDs.insert(id) } else { pendingIDs.remove(id) }
        }
        journal.upserted.remove(id)
        journal.removed.remove(id)
        journal.before[id] = nil
    }

    /// Lets records go without journaling: the store keeps them (the photo merely left this device), or has
    /// already dropped them (another device forgot it).
    public mutating func detach(_ ids: some Sequence<String>) {
        for id in ids {
            records[id] = nil
            seenIDs.remove(id)
            pendingIDs.remove(id)
            journal.upserted.remove(id)
            journal.removed.remove(id)
            journal.before[id] = nil
        }
    }

    public mutating func takeJournal() -> Journal {
        defer { journal = Journal() }
        return journal
    }

    /// Records whose photo is not among `available`.
    public func ids(missingFrom available: Set<String>) -> [String] {
        records.keys.filter { !available.contains($0) }
    }

    /// Records iCloud has no identifier for yet.
    public var idsWithoutCloudID: [String] {
        records.values.filter { $0.cloudID == nil }.map(\.id)
    }

    /// Which photos to show next: never-seen ones, in `order` (at random, or by `availableIDs`' own order, which
    /// the library gives newest first, forward or backward). Once every photo has been seen, the ones seen longest
    /// ago, so the library keeps turning over instead of running dry. Queued photos are never shown again.
    public func nextBatch(
        from availableIDs: [String],
        count: Int,
        order: ReviewOrder = .random,
        using generator: inout some RandomNumberGenerator
    ) -> [String] {
        guard count > 0 else { return [] }
        var eligible: [String] = []
        var unseen: [String] = []
        var included: Set<String> = []
        for id in availableIDs where !pendingIDs.contains(id) && included.insert(id).inserted {
            eligible.append(id)
            if !seenIDs.contains(id) { unseen.append(id) }
        }
        if !unseen.isEmpty {
            switch order {
            case .random: return Array(unseen.shuffled(using: &generator).prefix(count))
            case .newest: return Array(unseen.prefix(count))
            case .oldest: return Array(unseen.reversed().prefix(count))
            }
        }
        let oldestFirst = eligible.sorted { (records[$0]?.seenAt ?? .distantPast) < (records[$1]?.seenAt ?? .distantPast) }
        return Array(oldestFirst.prefix(count)).shuffled(using: &generator)
    }

    public func nextBatch(from availableIDs: [String], count: Int, order: ReviewOrder = .random) -> [String] {
        var generator = SystemRandomNumberGenerator()
        return nextBatch(from: availableIDs, count: count, order: order, using: &generator)
    }

    private mutating func set(_ record: PhotoRecord) {
        let id = record.id
        if record.isBlank {
            guard records[id] != nil else { return }
            remember(id)
            records[id] = nil
            seenIDs.remove(id)
            pendingIDs.remove(id)
            journal.upserted.remove(id)
            journal.removed.insert(id)
            return
        }
        remember(id)
        records[id] = record
        if record.seenAt != nil { seenIDs.insert(id) } else { seenIDs.remove(id) }
        if record.pendingSince != nil { pendingIDs.insert(id) } else { pendingIDs.remove(id) }
        journal.removed.remove(id)
        journal.upserted.insert(id)
    }
}

extension ReviewLedger: Equatable {
    /// The journal is bookkeeping for the store, not part of what the ledger says.
    public static func == (lhs: ReviewLedger, rhs: ReviewLedger) -> Bool {
        lhs.records == rhs.records
    }
}
