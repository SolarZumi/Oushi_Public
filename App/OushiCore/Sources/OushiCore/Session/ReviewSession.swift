// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import CloudKit
import CoreData
import Foundation
import Observation
import os

/// The review as the app sees it: the batch on screen, the pool, the counts, and the moves. One per app.
///
/// The state itself is a value (`ReviewState`), kept here and persisted through `LedgerRepository`: every move
/// journals the records it touched, and the journal goes to the store in one write together with the batch. What
/// other devices change comes back out of the store's history. The views see only what is published here: the
/// batch, the pool's identifiers and the counts, each a property of its own so a move redraws what it changed.
@MainActor
@Observable
public final class ReviewSession {
    public static let batchSizes = Array(stride(from: 15, through: 50, by: 5))
    /// A batch of everything there is: it ends only when every photo has been seen.
    public static let unlimitedBatchSize = Int.max

    // MARK: Published

    public private(set) var batch = ReviewBatch()
    /// Photos queued for deletion, those the app can see or not.
    public private(set) var pendingIDs: Set<String> = []
    /// The store has been read; until then the batch may refer to photos whose records are not here yet.
    public private(set) var isLoaded = false
    /// Photos in the pool that the app can see.
    public private(set) var pendingCount = 0
    /// Photos the app can see that were never swiped past.
    public private(set) var unseenCount = 0
    public private(set) var availableCount = 0
    /// How many of the photos and videos there are have been looked at, until progress is reset. One deleted no
    /// longer is one there is, so the count follows the library, not the history.
    public private(set) var seenCount = 0
    public private(set) var issues: [ReviewIssue] = []
    public private(set) var syncState: SyncState = .off
    public private(set) var batchSize: Int
    public private(set) var order: ReviewOrder

    /// There is something left to review besides the pool.
    public var hasMore: Bool { availableCount > pendingCount }
    /// Wraps the changes the session makes on its own (a photo leaving the batch because another device saw it),
    /// so the app can animate them: the card on top fades out and the next comes up.
    @ObservationIgnored public var changeTransaction: ((() -> Void) -> Void)?
    /// Every photo and video there is has been looked at (those in the pool were, on their way in): the next step
    /// is to start over, not another batch.
    public var isEverythingSeen: Bool { availableCount > 0 && unseenCount == 0 }
    public var isBatchUnlimited: Bool { batchSize == Self.unlimitedBatchSize }

    // MARK: State

    @ObservationIgnored private var state = ReviewState()
    @ObservationIgnored private let resolver: any PhotoIdentityResolving
    @ObservationIgnored private let accounts: (any CloudAccountChecking)?
    @ObservationIgnored private let directory: URL?
    @ObservationIgnored private let cloudContainerID: String?
    @ObservationIgnored private var repository: LedgerRepository?
    /// Bumped whenever the repository is replaced: work started for the old one is dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Oushi", category: "review")

    /// Local identifier to iCloud identifier, for the photos this device knows, and the reverse.
    @ObservationIgnored private var aliases: [String: String] = [:]
    @ObservationIgnored private var cloudToLocal: [String: String] = [:]
    /// Synced states whose photo is not on this device (not downloaded, deleted here, or not matched yet).
    @ObservationIgnored private var orphans: [String: SyncedValue] = [:]
    /// Orphans PhotoKit could not match since the library last changed; asked again when it does.
    @ObservationIgnored private var unmatchedOrphans: Set<String> = []

    /// Everything the app can see, and the same in the library's order, newest first.
    @ObservationIgnored private var available: Set<String> = []
    @ObservationIgnored private var availableInOrder: [String] = []
    @ObservationIgnored private var hasFullAccess = false

    @ObservationIgnored private var pendingWrite = LedgerWrite()
    /// Records whose write is under way: a change from iCloud for them waits for the next one.
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var writeTask: Task<Void, Never>?
    /// The pause between a failed write and the next try; cancelled by `flush`, which cannot wait it out.
    @ObservationIgnored private var writePause: Task<Void, Never>?
    @ObservationIgnored private var writeFailures = 0
    @ObservationIgnored private var writesStopped = false
    /// The store could not be read: nothing is written over what is there.
    @ObservationIgnored private var isReadOnly = false
    /// The store on disk could not be opened and an in-memory one stands in: it is never swapped for the disk
    /// store later (the sync switch), which would write this run's state over what is there unread.
    @ObservationIgnored private var usesFallbackStore = false
    /// Records known by local identifier only whose photo is not here now (hidden, with iCloud Photos off):
    /// taken back the moment the photo is, kept in the store meanwhile.
    @ObservationIgnored private var localOrphans: [String: PhotoRecord] = [:]
    /// The batch last handed to the store (queued, under way or landed): the next one is queued only when it differs.
    @ObservationIgnored private var queuedBatch: ReviewBatch?
    /// Local records PhotoKit had no iCloud identifier for since the library last changed; asked again when it does.
    @ObservationIgnored private var unresolvedLocalIDs: Set<String> = []
    /// What the user wants of sync, and the one task at a time that brings the store there.
    @ObservationIgnored private var wantsSync = false
    @ObservationIgnored private var syncTask: Task<Bool, Never>?

    @ObservationIgnored private var remoteChangeObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var cloudEventObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var pullTask: Task<Void, Never>?
    @ObservationIgnored private var isPulling = false
    @ObservationIgnored private var pullWanted = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var matchTask: Task<Void, Never>?
    @ObservationIgnored private var resolveTask: Task<Void, Never>?
    @ObservationIgnored private var remoteTask: Task<Void, Never>?

    private static let writeAttempts = 5
    private static let pullDelay: Duration = .seconds(1)

    // MARK: Lifecycle

    /// The app's session: the store under `directory`, mirrored to `cloudContainerID` while `syncEnabled`.
    public init(
        directory: URL,
        cloudContainerID: String,
        syncEnabled: Bool,
        batchSize: Int,
        order: ReviewOrder,
        resolver: any PhotoIdentityResolving,
        accounts: any CloudAccountChecking
    ) {
        self.directory = directory
        self.cloudContainerID = cloudContainerID
        self.batchSize = batchSize
        self.order = order
        self.resolver = resolver
        self.accounts = accounts
        wantsSync = syncEnabled
        syncState = syncEnabled ? .on : .off
        loadTask = Task { await load(syncing: syncEnabled) }
    }

    /// A session over a repository already open, for tests and previews.
    public init(repository: LedgerRepository, resolver: any PhotoIdentityResolving, batchSize: Int = ReviewState.batchSize, order: ReviewOrder = .random) {
        directory = nil
        cloudContainerID = nil
        accounts = nil
        self.repository = repository
        self.batchSize = batchSize
        self.order = order
        self.resolver = resolver
        loadTask = Task { await load(syncing: false) }
    }

    /// Returns once the store has been read.
    public func whenLoaded() async {
        await loadTask?.value
    }

    /// Returns once the work started so far (matching, remote changes, writes) has landed. For tests.
    func settle() async {
        await loadTask?.value
        await matchTask?.value
        await resolveTask?.value
        await remoteTask?.value
        await writeTask?.value
        await matchTask?.value
        await resolveTask?.value
        await writeTask?.value
    }

    private func load(syncing: Bool) async {
        if repository == nil, let directory {
            let location = LedgerLocation(directory: directory, cloudContainerID: syncing ? cloudContainerID : nil)
            do {
                repository = try await Task.detached { try LedgerRepository.open(location) }.value
            } catch {
                log.error("ledger could not be opened: \(error, privacy: .public)")
                // In memory for this run: the review works, and the user is told nothing is kept.
                repository = try? await Task.detached { try LedgerRepository.open(.inMemory()) }.value
                usesFallbackStore = true
                add(.ledgerNotPersistent)
            }
        }
        guard let repository else {
            isLoaded = true
            return
        }
        do {
            var snapshot = try await repository.load()
            if snapshot.isEmpty, let directory, !usesFallbackStore, LegacyStores.exist(in: directory) {
                do {
                    snapshot = try await importLegacy(from: directory, into: repository)
                } catch {
                    // Unreadable old files are put aside, not tried at every launch: the review goes on with a
                    // store that started empty, and the user is told the earlier records could not be read.
                    log.error("the 1.0 files could not be read: \(error, privacy: .public)")
                    LegacyStores.setAside(in: directory)
                    add(.ledgerUnreadable)
                }
            }
            install(snapshot)
        } catch {
            // What is there is not written over, record by record, with a ledger that started empty.
            log.error("ledger could not be read: \(error, privacy: .public)")
            isReadOnly = true
            add(.ledgerUnreadable)
        }
        if syncing, directory != nil {
            observeStore()
            checkAccount()
        }
        isLoaded = true
        try? await repository.pruneHistory()
        scheduleWrite()
    }

    private func importLegacy(from directory: URL, into repository: LedgerRepository) async throws -> LedgerSnapshot {
        let legacy = try await Task.detached { try LegacyStores.read(in: directory) }.value
        var write = LedgerWrite()
        for record in legacy.records {
            write.upserts.append(record)
            if let cloudID = record.cloudID { write.aliases[record.id] = cloudID }
        }
        write.batch = legacy.batch
        try await repository.apply(write)
        log.notice("imported \(legacy.records.count) records from the 1.0 files")
        LegacyStores.remove(in: directory)
        return try await repository.load()
    }

    /// Takes the store's contents as the state. The in-memory ledger is keyed by local identifier: a synced state
    /// becomes a record through its alias, or waits as an orphan until its photo turns up.
    private func install(_ snapshot: LedgerSnapshot) {
        aliases = snapshot.aliases
        cloudToLocal = [:]
        for (localID, cloudID) in aliases { cloudToLocal[cloudID] = localID }
        var ledger = ReviewLedger(records: snapshot.local)
        orphans = [:]
        for (cloudID, value) in snapshot.synced {
            if let localID = cloudToLocal[cloudID] {
                ledger.adopt(PhotoRecord(id: localID, cloudID: cloudID, seenAt: value.seenAt, pendingSince: value.pendingSince))
            } else {
                orphans[cloudID] = value
            }
        }
        state = ReviewState(ledger: ledger, batch: snapshot.batch ?? ReviewBatch())
        queuedBatch = snapshot.batch
        // Photos of the batch seen since the batch was written were seen on another device: not shown here.
        if let savedAt = snapshot.batchSavedAt {
            let seenSince = state.batch.ids.dropFirst(state.batch.cursor).filter { id in
                (state.ledger.records[id]?.seenAt).map { $0 > savedAt } ?? false
            }
            state.batch.dropUpcoming(Set(seenSince))
        }
        // Rows two devices wrote for one photo: written back folded so they converge.
        for cloudID in snapshot.duplicated {
            if let localID = cloudToLocal[cloudID], let record = state.ledger.records[localID] {
                pendingWrite.upserts.append(record)
            }
        }
        publish()
    }

    // MARK: The library

    /// Fits the state to the photos the app can see. With full access, records whose photo is gone are let go of
    /// here (their synced state stays, for the photo on another device, and comes back should the photo return);
    /// under limited access a missing photo may only be hidden, so they are kept.
    public func synchronize(availableIDs: [String], hasFullAccess: Bool) {
        guard isLoaded else { return }
        availableInOrder = availableIDs
        available = Set(availableIDs)
        self.hasFullAccess = hasFullAccess
        takeBackLocalOrphans()
        state.fit(availableIDs: availableIDs, order: order, count: batchSize)
        if hasFullAccess { detachMissingRecords() }
        unmatchedOrphans.removeAll()
        unresolvedLocalIDs.removeAll()
        matchOrphans()
        resolveLocalRecords()
        recountDerived()
        commit()
    }

    /// Photos known by local identifier only that are here again: their records come back as the store has them.
    private func takeBackLocalOrphans() {
        for (id, record) in localOrphans where available.contains(id) {
            localOrphans[id] = nil
            if state.ledger.records[id] == nil { state.ledger.adopt(record) }
        }
    }

    /// Records written before iCloud had an identifier for their photo (an upload not done, iCloud Photos turned
    /// on later): asked for again, and moved to the synced store when one turns up.
    private func resolveLocalRecords() {
        let wanted = state.ledger.idsWithoutCloudID.filter { !unresolvedLocalIDs.contains($0) && available.contains($0) }
        guard !wanted.isEmpty else { return }
        let generation = self.generation
        let resolver = self.resolver
        resolveTask = Task { [weak self] in
            let found = await resolver.cloudIdentifiers(forLocalIdentifiers: wanted)
            guard let self, self.generation == generation else { return }
            var changed = false
            for id in wanted {
                guard var record = self.state.ledger.records[id], record.cloudID == nil else { continue }
                if let cloudID = found[id] {
                    // The identifier is kept as an alias too, like one found on a write's way: removals and
                    // resets after this find the synced rows through it.
                    if let previous = self.cloudToLocal[cloudID], previous != id { self.forgetAlias(previous) }
                    self.aliases[id] = cloudID
                    self.cloudToLocal[cloudID] = id
                    self.pendingWrite.removedAliases.remove(id)
                    self.pendingWrite.aliases[id] = cloudID
                    self.orphans[cloudID] = nil
                    record.cloudID = cloudID
                    self.state.ledger.restore(record)
                    changed = true
                } else {
                    self.unresolvedLocalIDs.insert(id)
                }
            }
            if changed { self.commit() }
        }
    }

    private func detachMissingRecords() {
        let missing = state.ledger.ids(missingFrom: available)
        guard !missing.isEmpty else { return }
        var detached: [String] = []
        for id in missing {
            let record = state.ledger[id]
            if let cloudID = aliases[id] {
                // Known to iCloud: the state stays in the synced store for the photo wherever it is.
                orphans[cloudID] = SyncedValue(seenAt: record.seenAt, pendingSince: record.pendingSince)
                forgetAlias(id)
            } else {
                // Known here only (iCloud Photos off, or not uploaded yet): a hidden photo is missing too, and
                // comes back under the same identifier, so the record waits in the store. One deleted leaves a
                // row of a few bytes behind.
                localOrphans[id] = record
            }
            detached.append(id)
        }
        state.ledger.detach(detached)
    }

    private func forgetAlias(_ localID: String) {
        if let cloudID = aliases.removeValue(forKey: localID) {
            if cloudToLocal[cloudID] == localID { cloudToLocal[cloudID] = nil }
            pendingWrite.aliases[localID] = nil
            pendingWrite.removedAliases.insert(localID)
        }
    }

    /// Asks PhotoKit which of the orphans are photos on this device now (downloaded, restored, or on a device the
    /// records came to for the first time), and takes their states in.
    private func matchOrphans() {
        let wanted = orphans.keys.filter { !unmatchedOrphans.contains($0) }
        guard !wanted.isEmpty, hasFullAccess || !available.isEmpty else { return }
        let generation = self.generation
        let resolver = self.resolver
        let repository = self.repository
        matchTask = Task { [weak self] in
            let found = await resolver.localIdentifiers(forCloudIdentifiers: wanted)
            // The states as the store holds them now, not as they were remembered: this device may have written
            // the photo since (its write overwrites every row of the photo), and that word stands.
            let matchedIDs = wanted.filter { found[$0] != nil }
            let current = (try? await repository?.syncedValues(for: matchedIDs)) ?? [:]
            guard let self, self.generation == generation else { return }
            var matched = false
            var newlySeen: Set<String> = []
            for cloudID in wanted {
                guard self.orphans[cloudID] != nil else { continue }
                if let localID = found[cloudID], self.available.contains(localID) {
                    if let value = current[cloudID] {
                        let wasSeen = self.state.ledger.records[localID]?.seenAt != nil
                        self.adopt(cloudID: cloudID, localID: localID, value: value)
                        if !wasSeen, self.state.ledger.records[localID]?.seenAt != nil { newlySeen.insert(localID) }
                    } else {
                        self.orphans[cloudID] = nil
                    }
                    matched = true
                } else {
                    self.unmatchedOrphans.insert(cloudID)
                }
            }
            if matched {
                self.recountDerived()
                self.skipSeenElsewhere(newlySeen)
            }
        }
    }

    /// Matches a synced state to a photo here: `value` is the store's current fold for the photo, which includes
    /// whatever this device wrote for it. A record this device is still writing stands as it is, and the state
    /// waits as an orphan for the next look. A record known here by local identifier only meets the state as
    /// two devices' states meet everywhere: the move made first stands; the fold is written back, and the local
    /// row goes with it.
    private func adopt(cloudID: String, localID: String, value: SyncedValue) {
        if let previous = cloudToLocal[cloudID], previous != localID { forgetAlias(previous) }
        aliases[localID] = cloudID
        cloudToLocal[cloudID] = localID
        pendingWrite.removedAliases.remove(localID)
        pendingWrite.aliases[localID] = cloudID
        guard !busyIDs.contains(localID) else { return }
        orphans[cloudID] = nil
        if let local = state.ledger.records[localID], local.cloudID == nil {
            let merged = SyncedValue(seenAt: local.seenAt, pendingSince: local.pendingSince).merged(with: value)
            state.ledger.restore(PhotoRecord(id: localID, cloudID: cloudID, seenAt: merged.seenAt, pendingSince: merged.pendingSince))
        } else if value.isBlank {
            state.ledger.detach([localID])
        } else {
            state.ledger.adopt(PhotoRecord(id: localID, cloudID: cloudID, seenAt: value.seenAt, pendingSince: value.pendingSince))
        }
    }

    /// Records changed here whose write has not landed: a change from iCloud for them waits for the next one.
    private var busyIDs: Set<String> {
        inFlight
            .union(pendingWrite.upserts.map(\.id))
            .union(pendingWrite.removals.map(\.localID))
    }

    // MARK: Moves

    @discardableResult
    public func advance(delete: Bool, direction: SwipeDirection? = nil) -> Bool {
        guard isLoaded, let change = state.advance(delete: delete, direction: direction) else { return false }
        apply(change)
        commit()
        return true
    }

    @discardableResult
    public func undo() -> Bool {
        guard isLoaded, let change = state.undo() else { return false }
        apply(change)
        commit()
        return true
    }

    /// `first`, if given and available, leads the new batch.
    public func startNextBatch(first: String? = nil) {
        guard isLoaded else { return }
        state.startNextBatch(availableIDs: availableInOrder, first: first, order: order, count: batchSize)
        commit()
    }

    /// Starts over: every "seen" mark is dropped (the pool is kept), and a fresh batch begins.
    public func resetProgress() {
        guard isLoaded else { return }
        state.ledger.forgetSeen()
        state.startNextBatch(availableIDs: availableInOrder, order: order, count: batchSize)
        recountDerived()
        commit()
    }

    /// Takes photos out of the deletion pool by hand; they stay seen.
    public func removeFromPool(ids: some Sequence<String>) {
        guard isLoaded else { return }
        for id in ids {
            if let change = state.restoreFromPool(id) { apply(change) }
        }
        commit()
    }

    /// Deletes photos from the library through `delete` (the system asks the user first; it answers with the
    /// photos it deleted, or nil when the user declined or it failed) and, once they are gone, forgets their
    /// records on every device: a photo the user deleted is not one that merely left this device. Returns the
    /// photos deleted, or nil.
    public func deleteFromLibrary(ids: [String], using delete: ([String]) async -> [String]?) async -> [String]? {
        guard isLoaded else { return nil }
        // Identities first: once the library reports the photos gone, their records are let go of.
        var cloudIDs: [String: String] = [:]
        for id in ids { cloudIDs[id] = aliases[id] }
        let asked = Set(ids)
        guard let deletedIDs = await delete(ids) else { return nil }
        let ids = deletedIDs.filter(asked.contains)
        guard !ids.isEmpty else { return deletedIDs }
        var write = LedgerWrite()
        for id in ids {
            let cloudID = cloudIDs[id] ?? aliases[id]
            write.removals.append(LedgerWrite.Removal(localID: id, cloudID: cloudID))
            if let cloudID { orphans[cloudID] = nil }
            forgetAlias(id)
        }
        state.ledger.detach(ids)
        // Gone from the library, whatever it still says until its next read.
        let deleted = Set(ids)
        available.subtract(deleted)
        availableInOrder.removeAll { deleted.contains($0) }
        state.fit(availableIDs: availableInOrder, order: order, count: batchSize)
        pendingWrite.merge(write)
        recountDerived()
        commit()
        return deletedIDs
    }

    /// How many photos and videos a batch holds. Multiples of five, 15 to 50, or `unlimitedBatchSize`. The current
    /// batch follows at once: a larger size adds photos to it, a smaller one ends it at the current photo.
    public func setBatchSize(_ size: Int) {
        guard size != batchSize else { return }
        batchSize = size
        state.resizeBatch(to: size, availableIDs: availableInOrder, order: order)
        commit()
    }

    /// The order photos come up in. Takes effect at once on what is still to come: the next photo is the first
    /// there is in the new order, taken from the whole library again; what came before, and the current photo,
    /// stay as they are.
    public func setOrder(_ order: ReviewOrder) {
        guard order != self.order else { return }
        self.order = order
        state.refillRemaining(availableIDs: availableInOrder, order: order, count: batchSize)
        commit()
    }

    public func dismiss(_ issue: ReviewIssue) {
        issues.removeAll { $0 == issue }
    }

    // MARK: Derived counts

    private func apply(_ change: ReviewState.Change) {
        guard available.contains(change.id) else { return }
        let wasSeen = change.before.seenAt != nil, isSeen = change.after.seenAt != nil
        if wasSeen != isSeen { unseenCount += isSeen ? -1 : 1 }
        let wasPending = change.before.pendingSince != nil, isPending = change.after.pendingSince != nil
        if wasPending != isPending { pendingCount += isPending ? 1 : -1 }
    }

    private func recountDerived() {
        let seen = state.ledger.seenIDs
        availableCount = available.count
        unseenCount = available.lazy.filter { !seen.contains($0) }.count
        pendingCount = state.ledger.pendingIDs.lazy.filter(available.contains).count
    }

    private func publish() {
        if batch != state.batch { batch = state.batch }
        if pendingIDs != state.ledger.pendingIDs { pendingIDs = state.ledger.pendingIDs }
        if seenCount != state.ledger.seenIDs.count { seenCount = state.ledger.seenIDs.count }
    }

    // MARK: Writing

    /// Turns the journal into the next write, with the batch when it changed, and publishes the state. Each
    /// record goes with what it was before the move, so the store can tell a decision over a known state from a
    /// move made unknowing of another device's.
    private func commit() {
        let journal = state.ledger.takeJournal()
        var write = LedgerWrite()
        for id in journal.upserted {
            guard var record = state.ledger.records[id] else { continue }
            record.cloudID = record.cloudID ?? aliases[id]
            write.upserts.append(record)
            if let before = journal.before[id] { write.knownStates[id] = SyncedValue(before) }
        }
        for id in journal.removed {
            write.removals.append(LedgerWrite.Removal(localID: id, cloudID: aliases[id]))
            if let before = journal.before[id] { write.knownStates[id] = SyncedValue(before) }
        }
        if state.batch != queuedBatch {
            write.batch = state.batch
            queuedBatch = state.batch
        }
        if !write.isEmpty { pendingWrite.merge(write) }
        publish()
        scheduleWrite()
    }

    private func scheduleWrite() {
        guard isLoaded, !isReadOnly, repository != nil, !writesStopped, writeTask == nil, !pendingWrite.isEmpty else { return }
        writeTask = Task { [weak self] in await self?.runWrites() }
    }

    /// Writes until nothing is waiting. A failed write goes back under whatever changed meanwhile and is tried
    /// again after a growing pause; after enough failures the writes stop until the app is next in front.
    private func runWrites() async {
        defer { writeTask = nil }
        while let repository, !pendingWrite.isEmpty, !writesStopped, !Task.isCancelled {
            var write = pendingWrite
            pendingWrite = LedgerWrite()
            let touched = Set(write.upserts.map(\.id)).union(write.removals.map(\.localID))
            inFlight.formUnion(touched)
            // Records written for the first time get their iCloud identifier on the way, so they can follow
            // their photo to another device; a photo iCloud does not know stays a local record.
            let unresolved = write.upserts.filter { $0.cloudID == nil }.map(\.id)
            if !unresolved.isEmpty {
                let found = await resolver.cloudIdentifiers(forLocalIdentifiers: unresolved)
                for index in write.upserts.indices where write.upserts[index].cloudID == nil {
                    guard let cloudID = found[write.upserts[index].id] else { continue }
                    write.upserts[index].cloudID = cloudID
                    write.aliases[write.upserts[index].id] = cloudID
                }
            }
            do {
                let merged = try await repository.apply(write)
                inFlight.subtract(touched)
                writeFailures = 0
                remove(.saveFailed)
                for (localID, cloudID) in write.aliases {
                    // Let go of meanwhile (the photo left, or was deleted): the store has dropped it too.
                    guard !pendingWrite.removedAliases.contains(localID) else { continue }
                    if state.ledger.records[localID] != nil || orphans[cloudID] == nil {
                        aliases[localID] = cloudID
                        cloudToLocal[cloudID] = localID
                    }
                    if var record = state.ledger.records[localID], record.cloudID == nil {
                        record.cloudID = cloudID
                        state.ledger.adopt(record)
                    }
                    // A removal queued meanwhile for a photo whose identifier was only now learned.
                    for index in pendingWrite.removals.indices where pendingWrite.removals[index].localID == localID && pendingWrite.removals[index].cloudID == nil {
                        pendingWrite.removals[index].cloudID = cloudID
                    }
                }
                // Records whose rows another device had changed first, unknown to this one: the store kept that
                // device's move, which is taken over here unless the record has moved on since.
                var newlySeen: Set<String> = []
                var adopted = false
                for (localID, value) in merged {
                    guard !busyIDs.contains(localID), available.contains(localID) else { continue }
                    let record = state.ledger.records[localID]
                    guard let cloudID = record?.cloudID ?? write.aliases[localID] ?? aliases[localID] else { continue }
                    if record?.seenAt == nil, value.seenAt != nil { newlySeen.insert(localID) }
                    state.ledger.adopt(PhotoRecord(id: localID, cloudID: cloudID, seenAt: value.seenAt, pendingSince: value.pendingSince))
                    adopted = true
                }
                if adopted {
                    recountDerived()
                    skipSeenElsewhere(newlySeen)
                }
            } catch {
                inFlight.subtract(touched)
                log.error("ledger write failed: \(error, privacy: .public)")
                // The failed write is the older one: what changed meanwhile wins over it.
                var retry = write
                retry.merge(pendingWrite)
                pendingWrite = retry
                writeFailures += 1
                if writeFailures >= Self.writeAttempts {
                    writesStopped = true
                    add(.saveFailed)
                    return
                }
                let pause = Task<Void, Never> { try? await Task.sleep(for: .seconds(min(5 * pow(2, Double(writeFailures - 1)), 60))) }
                writePause = pause
                await pause.value
                writePause = nil
            }
        }
    }

    /// Writes whatever is waiting now, failures notwithstanding: for leaving the foreground, so the last moves are
    /// on disk should the app be ended. Returns once the writes have landed or given up.
    public func flush() async {
        writesStopped = false
        writeFailures = max(writeFailures, Self.writeAttempts - 1)
        // A pause before the next try cannot be waited out: the next try is now.
        writePause?.cancel()
        scheduleWrite()
        await writeTask?.value
        writeFailures = 0
    }

    /// Back in front: writes that had given up are tried again.
    public func retryWrites() {
        guard writesStopped else { return }
        writesStopped = false
        writeFailures = 0
        scheduleWrite()
    }

    // MARK: iCloud

    /// Turns the copy in iCloud on or off. On, the synced store is mirrored: what this device wrote while sync was
    /// off goes up, what iCloud has comes down as remote changes, and a photo both sides moved on without knowing
    /// of each other keeps the move made first. Off, the same store stays on this device. Returns whether sync
    /// is on.
    @discardableResult
    public func setCloudSync(_ enabled: Bool) async -> Bool {
        wantsSync = enabled
        // One change at a time, each toward what was last asked: a switch flipped twice while the first flip
        // waited on the account check lands on the second position, not the first.
        let previous = syncTask
        let task = Task { [weak self] () -> Bool in
            _ = await previous?.value
            guard let self else { return false }
            return await self.reconcileSync()
        }
        syncTask = task
        return await task.value
    }

    private func reconcileSync() async -> Bool {
        guard let directory, !usesFallbackStore else { return false }
        let wanted = wantsSync
        let isOn = syncState != .off
        guard wanted != isOn else { return isOn }
        if wanted {
            if let accounts, await accounts.hasAccount() == false {
                guard wantsSync else { return false }
                add(.cloudNeedsAccount)
                syncState = .stalled("account")
                return false
            }
            guard wantsSync else { return false }
            guard await reopen(LedgerLocation(directory: directory, cloudContainerID: cloudContainerID)) else { return false }
            syncState = .on
            observeStore()
            return true
        } else {
            stopObservingStore()
            guard await reopen(LedgerLocation(directory: directory)) else {
                // Still mirrored: its changes are still listened for.
                observeStore()
                return true
            }
            syncState = .off
            return false
        }
    }

    /// Opens the same files again, mirrored or not. The state in memory stands; the store is the same. Returns
    /// whether it opened; if not, the store in use stays as it was.
    private func reopen(_ location: LedgerLocation) async -> Bool {
        await flush()
        do {
            let opened = try await Task.detached { try LedgerRepository.open(location) }.value
            generation += 1
            repository = opened
            scheduleWrite()
            // Matching under way against the old store was dropped with it: asked again of the new one.
            matchOrphans()
            resolveLocalRecords()
            return true
        } catch {
            log.error("ledger could not be reopened: \(error, privacy: .public)")
            return false
        }
    }

    private func checkAccount() {
        guard let accounts else { return }
        Task { [weak self] in
            let hasAccount = await accounts.hasAccount()
            guard let self, self.syncState != .off else { return }
            if hasAccount == false {
                // Nothing would ever sync: said so, and the app turns the switch off, which turns the mirroring off.
                self.add(.cloudNeedsAccount)
                self.syncState = .stalled("account")
            }
        }
    }

    private func observeStore() {
        guard remoteChangeObserver == nil else { return }
        let center = NotificationCenter.default
        // Only the synced store's changes; the local store posts the same notification.
        remoteChangeObserver = center.addObserver(forName: .NSPersistentStoreRemoteChange, object: nil, queue: .main) { [weak self] notification in
            guard let url = notification.userInfo?[NSPersistentStoreURLKey] as? URL, url.lastPathComponent == "synced.store" else { return }
            MainActor.assumeIsolated { self?.schedulePull() }
        }
        cloudEventObserver = center.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil, queue: .main) { [weak self] notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event,
                  event.endDate != nil else { return }
            let failure = event.error?.localizedDescription
            MainActor.assumeIsolated { self?.cloudEventEnded(failure: failure) }
        }
        schedulePull()
    }

    private func stopObservingStore() {
        let center = NotificationCenter.default
        if let remoteChangeObserver { center.removeObserver(remoteChangeObserver) }
        if let cloudEventObserver { center.removeObserver(cloudEventObserver) }
        remoteChangeObserver = nil
        cloudEventObserver = nil
        pullTask?.cancel()
        pullTask = nil
        pullWanted = false
    }

    private func cloudEventEnded(failure: String?) {
        guard syncState != .off else { return }
        if let failure {
            log.error("iCloud mirroring: \(failure, privacy: .public)")
            syncState = .stalled(failure)
        } else if syncState != .on {
            syncState = .on
        }
    }

    /// Remote changes come in bursts; one read a little after the last of them.
    private func schedulePull() {
        guard pullTask == nil else { return }
        pullTask = Task { [weak self] in
            try? await Task.sleep(for: Self.pullDelay)
            guard let self, !Task.isCancelled else { return }
            self.pullTask = nil
            self.pull()
        }
    }

    /// Reads other devices' changes now, without waiting for a notification. For tests.
    func pullNow() async {
        pull()
        await remoteTask?.value
    }

    private func pull() {
        guard let repository, isLoaded else { return }
        guard !isPulling else {
            pullWanted = true
            return
        }
        isPulling = true
        pullWanted = false
        let generation = self.generation
        remoteTask = Task { [weak self] in
            var remote = RemoteChanges()
            do {
                remote = try await repository.remoteChanges()
            } catch {
                self?.log.error("history could not be read: \(error, privacy: .public)")
            }
            guard let self else { return }
            self.isPulling = false
            // Read from a store since replaced (the sync switch): the new store's own read follows.
            guard self.generation == generation else { return }
            if remote.purged { self.restoreAfterPurge() }
            if let everything = remote.everything { self.applyEverything(everything) }
            if !remote.changes.isEmpty { self.applyRemote(remote.changes) }
            if self.pullWanted { self.pull() }
        }
    }

    /// The history could not say what changed: the whole synced store against what is held here. Every state
    /// the store has is taken as an update; every one it no longer has, as a deletion. A store empty where this
    /// device holds synced states was emptied by the system (it cannot be told from another device resetting
    /// everything, and the device's own records are the safer thing to keep).
    private func applyEverything(_ fold: [String: SyncedValue]) {
        let held = Set(state.ledger.records.values.compactMap(\.cloudID)).union(orphans.keys)
        let known = held.union(cloudToLocal.keys)
        if fold.isEmpty, !held.isEmpty {
            restoreAfterPurge()
            return
        }
        var changes = fold.map { RemoteChange.updated(cloudID: $0.key, value: $0.value) }
        changes += known.filter { fold[$0] == nil }.map { RemoteChange.deleted(cloudID: $0) }
        applyRemote(changes)
    }

    /// The system emptied the synced store (the iCloud account changed or was signed out). What this device
    /// knows stays its own: every record it holds is written back, and goes up to whatever account is there now.
    private func restoreAfterPurge() {
        log.notice("synced store was emptied by the system; writing the device's records back")
        for record in state.ledger.records.values where record.cloudID != nil {
            pendingWrite.upserts.removeAll { $0.id == record.id }
            pendingWrite.upserts.append(record)
        }
        scheduleWrite()
    }

    /// Takes other devices' changes into the state: what the store's rows say now, folded, is what stands. A
    /// record this device changed and has not finished writing keeps its own value for now: the write lands
    /// after the import, and the store decides there which move was first.
    private func applyRemote(_ changes: [RemoteChange]) {
        commit()
        let busy = busyIDs
        var newOrphans = false
        var newlySeen: Set<String> = []
        for change in changes {
            switch change {
            case .updated(let cloudID, let value):
                if let localID = cloudToLocal[cloudID] {
                    guard !busy.contains(localID) else { continue }
                    if value.isBlank {
                        state.ledger.detach([localID])
                    } else {
                        if state.ledger.records[localID]?.seenAt == nil, value.seenAt != nil { newlySeen.insert(localID) }
                        state.ledger.adopt(PhotoRecord(id: localID, cloudID: cloudID, seenAt: value.seenAt, pendingSince: value.pendingSince))
                    }
                } else if !value.isBlank {
                    orphans[cloudID] = value
                    unmatchedOrphans.remove(cloudID)
                    newOrphans = true
                }
            case .deleted(let cloudID):
                orphans[cloudID] = nil
                if let localID = cloudToLocal[cloudID], !busy.contains(localID) {
                    state.ledger.detach([localID])
                }
            }
        }
        recountDerived()
        skipSeenElsewhere(newlySeen)
        if newOrphans { matchOrphans() }
    }

    /// Photos seen on another device since this batch was made leave what is still to come: the one on top, if
    /// it is one of them, fades out and the next comes up, so a device with the same order follows the other's
    /// progress. A batch left with nothing to come goes on to the next, while there are photos unseen.
    private func skipSeenElsewhere(_ ids: Set<String>) {
        let upcoming = Set(state.batch.ids.dropFirst(state.batch.cursor))
        let skipped = ids.intersection(upcoming)
        guard !skipped.isEmpty else {
            commit()
            return
        }
        let change = {
            self.state.batch.dropUpcoming(skipped)
            if self.state.batch.currentID == nil, self.unseenCount > 0 {
                self.state.startNextBatch(availableIDs: self.availableInOrder, order: self.order, count: self.batchSize)
            }
            self.commit()
        }
        if let changeTransaction {
            changeTransaction(change)
        } else {
            change()
        }
    }

    // MARK: Issues

    private func add(_ issue: ReviewIssue) {
        if !issues.contains(issue) { issues.append(issue) }
    }

    private func remove(_ issue: ReviewIssue) {
        issues.removeAll { $0 == issue }
    }
}
