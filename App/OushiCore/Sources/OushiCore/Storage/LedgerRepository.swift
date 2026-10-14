// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import Foundation
import SwiftData

/// What a photo's synced rows say, folded into one. Two devices that both moved on a photo without knowing of
/// each other's move: the move made first stands.
public struct SyncedValue: Equatable, Sendable {
    public var seenAt: Date?
    public var pendingSince: Date?

    public init(seenAt: Date?, pendingSince: Date?) {
        self.seenAt = seenAt
        self.pendingSince = pendingSince
    }

    public init(_ record: PhotoRecord) {
        self.init(seenAt: record.seenAt, pendingSince: record.pendingSince)
    }

    public var isBlank: Bool { seenAt == nil && pendingSince == nil }

    /// When the move that made this state was made: a swipe marks the photo seen (and queued, swiped down); a
    /// reset drops the seen mark and leaves the queue.
    public var actionTime: Date? { seenAt ?? pendingSince }

    /// Of two states for one photo, the one made first, when there is one: a blank state is no move at all, and
    /// moves made at the very same time are one lineage (a device changing its own earlier move), which the
    /// callers settle their own way.
    public func first(against other: SyncedValue) -> SyncedValue? {
        switch (actionTime, other.actionTime) {
        case (let mine?, let theirs?) where mine < theirs: return self
        case (let mine?, let theirs?) where theirs < mine: return other
        case (nil, _?): return other
        case (_?, nil): return self
        default: return nil
        }
    }

    /// The two folded into one: the move made first; made at the same time, what either said holds (seen, and
    /// queued if either queued).
    public func merged(with other: SyncedValue) -> SyncedValue {
        first(against: other) ?? SyncedValue(
            seenAt: [seenAt, other.seenAt].compactMap { $0 }.max(),
            pendingSince: [pendingSince, other.pendingSince].compactMap { $0 }.min()
        )
    }
}

/// Everything in the store, as read at launch.
public struct LedgerSnapshot: Sendable {
    /// Every synced photo's folded state, by iCloud identifier.
    public var synced: [String: SyncedValue] = [:]
    /// States of photos iCloud has no identifier for, by local identifier.
    public var local: [PhotoRecord] = []
    /// Local identifier to iCloud identifier, as last answered by PhotoKit.
    public var aliases: [String: String] = [:]
    public var batch: ReviewBatch?
    /// When the batch was last written: a photo in it seen since was seen on another device.
    public var batchSavedAt: Date?
    /// Photos with more than one synced row: written back folded, so the rows converge.
    public var duplicated: Set<String> = []

    public init() {}

    public var isEmpty: Bool { synced.isEmpty && local.isEmpty && aliases.isEmpty && batch == nil }
}

/// One transaction's worth of changes. Records with an iCloud identifier go to the synced store, the others to the
/// local one; the batch, when given, is written in the same save.
public struct LedgerWrite: Equatable, Sendable {
    public struct Removal: Equatable, Hashable, Sendable {
        public var localID: String
        public var cloudID: String?

        public init(localID: String, cloudID: String?) {
            self.localID = localID
            self.cloudID = cloudID
        }
    }

    public var upserts: [PhotoRecord] = []
    public var removals: [Removal] = []
    /// What the device took the synced state to be before it moved on each photo written or removed here, by
    /// local identifier (blank when absent). Rows that say otherwise were changed by another device without the
    /// device knowing: then the move made first stands, not this one, and a removal (an undo, a reset) leaves
    /// them. A removal without an entry (the photo deleted from the library) takes the rows whatever they say.
    public var knownStates: [String: SyncedValue] = [:]
    public var aliases: [String: String] = [:]
    public var removedAliases: Set<String> = []
    public var batch: ReviewBatch?

    public init() {}

    public var isEmpty: Bool {
        upserts.isEmpty && removals.isEmpty && aliases.isEmpty && removedAliases.isEmpty && batch == nil
    }

    /// Folds a later write into this one: each record's later fate wins, the later batch stands. What the device
    /// knew before its first move on a record stays what it knew.
    public mutating func merge(_ later: LedgerWrite) {
        let laterUpserted = Set(later.upserts.map(\.id))
        let laterRemoved = Set(later.removals.map(\.localID))
        upserts.removeAll { laterUpserted.contains($0.id) || laterRemoved.contains($0.id) }
        removals.removeAll { laterUpserted.contains($0.localID) || laterRemoved.contains($0.localID) }
        upserts += later.upserts
        removals += later.removals
        knownStates.merge(later.knownStates) { mine, _ in mine }
        for localID in later.removedAliases { aliases[localID] = nil }
        for (localID, cloudID) in later.aliases { aliases[localID] = cloudID }
        removedAliases.subtract(later.aliases.keys)
        removedAliases.formUnion(later.removedAliases)
        if let batch = later.batch { self.batch = batch }
    }
}

/// A change another device made, as it arrived through iCloud.
public enum RemoteChange: Equatable, Sendable {
    case updated(cloudID: String, value: SyncedValue)
    case deleted(cloudID: String)
}

/// What the store's history held since the last read.
public struct RemoteChanges: Equatable, Sendable {
    public var changes: [RemoteChange] = []
    /// The system emptied the synced store (the iCloud account changed or was signed out): what the device knew
    /// is gone from the store, though not from memory.
    public var purged = false
    /// The history could not say what changed (its token's transaction was gone): the whole synced store, folded,
    /// for the session to compare with what it holds. `changes` is empty then.
    public var everything: [String: SyncedValue]?

    public init() {}
}

/// Where the store lives and whether its synced half is mirrored to CloudKit.
public struct LedgerLocation: Equatable, Sendable {
    public var directory: URL
    /// The CloudKit container to mirror the synced store to; nil keeps it on this device.
    public var cloudContainerID: String?
    public var isInMemory: Bool

    public init(directory: URL, cloudContainerID: String? = nil, isInMemory: Bool = false) {
        self.directory = directory
        self.cloudContainerID = cloudContainerID
        self.isInMemory = isInMemory
    }

    public static func inMemory() -> LedgerLocation {
        LedgerLocation(directory: FileManager.default.temporaryDirectory, cloudContainerID: nil, isInMemory: true)
    }
}

/// The ledger on disk: one container with the synced and the local store, read and written off the main thread.
/// The session keeps the review's state in memory and hands this actor the changes to persist; changes other
/// devices made come back out of the store's history, so no second copy of the ledger is kept anywhere.
@ModelActor
public actor LedgerRepository {
    /// Marks this app's own transactions in the history, so they are told apart from iCloud's imports.
    static let author = "oushi"
    /// How the mirroring signs what it brings down from iCloud.
    static let importAuthor = "NSCloudKitMirroringDelegate.import"
    private static let historyTokenKey = "historyToken"
    /// When the token's transaction was made: history is never pruned past it, or the token would expire.
    private static let historyTokenTimeKey = "historyTokenTime"
    private static let syncedStoreKey = "syncedStoreIdentifier"
    private static let batchKey = "batch"
    /// History older than this is dropped; the mirroring has long exported it by then.
    private static let historyRetention: TimeInterval = 7 * 86_400

    public static func open(_ location: LedgerLocation) throws -> LedgerRepository {
        let schema = Schema(versionedSchema: LedgerSchemaV1.self)
        let syncedSchema = Schema([SyncedPhotoState.self])
        let localSchema = Schema([LocalPhotoState.self, PhotoAlias.self, BatchRecord.self, LocalMetadata.self])
        let synced: ModelConfiguration
        let local: ModelConfiguration
        if location.isInMemory {
            synced = ModelConfiguration("synced", schema: syncedSchema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            local = ModelConfiguration("local", schema: localSchema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        } else {
            try FileManager.default.createDirectory(at: location.directory, withIntermediateDirectories: true)
            let database: ModelConfiguration.CloudKitDatabase = location.cloudContainerID.map { .private($0) } ?? .none
            synced = ModelConfiguration(
                "synced", schema: syncedSchema, url: location.directory.appendingPathComponent("synced.store"), cloudKitDatabase: database
            )
            local = ModelConfiguration(
                "local", schema: localSchema, url: location.directory.appendingPathComponent("local.store"), cloudKitDatabase: .none
            )
        }
        let container = try ModelContainer(for: schema, migrationPlan: LedgerMigrationPlan.self, configurations: synced, local)
        return LedgerRepository(modelContainer: container)
    }

    private func prepareContext() {
        if modelContext.author != Self.author {
            modelContext.author = Self.author
            modelContext.autosaveEnabled = false
        }
    }

    // MARK: Reading

    public func load() throws -> LedgerSnapshot {
        prepareContext()
        var snapshot = LedgerSnapshot()
        for row in try modelContext.fetch(FetchDescriptor<SyncedPhotoState>()) where !row.cloudID.isEmpty {
            let value = SyncedValue(seenAt: row.seenAt, pendingSince: row.pendingSince)
            if let existing = snapshot.synced[row.cloudID] {
                snapshot.synced[row.cloudID] = existing.merged(with: value)
                snapshot.duplicated.insert(row.cloudID)
            } else {
                snapshot.synced[row.cloudID] = value
            }
        }
        snapshot.local = try modelContext.fetch(FetchDescriptor<LocalPhotoState>()).map {
            PhotoRecord(id: $0.localID, seenAt: $0.seenAt, pendingSince: $0.pendingSince)
        }
        for alias in try modelContext.fetch(FetchDescriptor<PhotoAlias>()) {
            snapshot.aliases[alias.localID] = alias.cloudID
        }
        (snapshot.batch, snapshot.batchSavedAt) = try loadBatch()
        return snapshot
    }

    /// The synced state of these photos as the store holds it now, folded; absent when no row is left.
    public func syncedValues(for cloudIDs: [String]) throws -> [String: SyncedValue] {
        prepareContext()
        guard !cloudIDs.isEmpty else { return [:] }
        let rows = try modelContext.fetch(FetchDescriptor<SyncedPhotoState>(predicate: #Predicate { cloudIDs.contains($0.cloudID) }))
        var folded: [String: SyncedValue] = [:]
        for row in rows {
            let value = SyncedValue(seenAt: row.seenAt, pendingSince: row.pendingSince)
            folded[row.cloudID] = folded[row.cloudID].map { $0.merged(with: value) } ?? value
        }
        return folded
    }

    private func loadBatch() throws -> (ReviewBatch?, Date?) {
        let key = Self.batchKey
        var descriptor = FetchDescriptor<BatchRecord>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        guard let row = try modelContext.fetch(descriptor).first else { return (nil, nil) }
        do {
            return (try JSONDecoder().decode(ReviewBatch.self, from: row.payload), row.savedAt)
        } catch {
            // A batch that cannot be read is a batch lost, not a ledger lost: the review starts a fresh one.
            modelContext.delete(row)
            try modelContext.save()
            return (nil, nil)
        }
    }

    // MARK: Writing

    /// Writes the change. Returns, by local identifier, the records whose rows another device had changed without
    /// this device knowing (the rows say something other than the write's `knownStates`) and whose move was the
    /// later of the two, or whose removal (an undo, a reset) would take that other device's move away: those rows
    /// stand, and what they say is returned for the session to take over. A failed write leaves nothing of itself
    /// in the context.
    @discardableResult
    public func apply(_ write: LedgerWrite) throws -> [String: SyncedValue] {
        prepareContext()
        do {
            let write = try completed(write)
            try applyAliases(write)
            let overruled = try applySynced(write)
            try applyLocal(write)
            if let batch = write.batch { try save(batch) }
            if modelContext.hasChanges { try modelContext.save() }
            return overruled
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// A removal that came without an iCloud identifier was made while the photo's first write was still on its
    /// way; that write has landed by now (writes run one after another here) and left an alias, which says which
    /// synced rows the removal is for. The alias stays: the photo is still here, and PhotoKit's answer holds.
    private func completed(_ write: LedgerWrite) throws -> LedgerWrite {
        let unknown = write.removals.filter { $0.cloudID == nil }.map(\.localID)
        guard !unknown.isEmpty else { return write }
        let rows = try modelContext.fetch(FetchDescriptor<PhotoAlias>(predicate: #Predicate { unknown.contains($0.localID) }))
        guard !rows.isEmpty else { return write }
        var found: [String: String] = [:]
        for row in rows { found[row.localID] = row.cloudID }
        var completed = write
        completed.removals = write.removals.map { removal in
            guard removal.cloudID == nil, let cloudID = found[removal.localID] else { return removal }
            return LedgerWrite.Removal(localID: removal.localID, cloudID: cloudID)
        }
        return completed
    }

    private func applyAliases(_ write: LedgerWrite) throws {
        let localIDs = Array(Set(write.aliases.keys).union(write.removedAliases))
        guard !localIDs.isEmpty else { return }
        let rows = try modelContext.fetch(FetchDescriptor<PhotoAlias>(predicate: #Predicate { localIDs.contains($0.localID) }))
        var byLocal: [String: PhotoAlias] = [:]
        for row in rows { byLocal[row.localID] = row }
        for localID in write.removedAliases {
            if let row = byLocal.removeValue(forKey: localID) { modelContext.delete(row) }
        }
        for (localID, cloudID) in write.aliases {
            if let row = byLocal[localID] {
                if row.cloudID != cloudID { row.cloudID = cloudID }
            } else {
                modelContext.insert(PhotoAlias(localID: localID, cloudID: cloudID))
            }
        }
    }

    private func applySynced(_ write: LedgerWrite) throws -> [String: SyncedValue] {
        let upserts = write.upserts.filter { $0.cloudID != nil }
        let removed = write.removals.compactMap(\.cloudID)
        let cloudIDs = Array(Set(upserts.compactMap(\.cloudID)).union(removed))
        guard !cloudIDs.isEmpty else { return [:] }
        let rows = try modelContext.fetch(FetchDescriptor<SyncedPhotoState>(predicate: #Predicate { cloudIDs.contains($0.cloudID) }))
        var byCloud: [String: [SyncedPhotoState]] = [:]
        for row in rows { byCloud[row.cloudID, default: []].append(row) }
        var overruled: [String: SyncedValue] = [:]
        for removal in write.removals {
            guard let cloudID = removal.cloudID, let existing = byCloud[cloudID], !existing.isEmpty else { continue }
            // A removal undoing or resetting a move the device knew (its own) goes through; one that would take
            // away rows another device changed meanwhile does not: that device's move stands.
            if let known = write.knownStates[removal.localID] {
                let fold = folded(existing)[cloudID] ?? SyncedValue(seenAt: nil, pendingSince: nil)
                if fold != known {
                    overruled[removal.localID] = fold
                    continue
                }
            }
            for row in byCloud.removeValue(forKey: cloudID) ?? [] { modelContext.delete(row) }
        }
        for record in upserts {
            guard let cloudID = record.cloudID else { continue }
            if let existing = byCloud[cloudID], !existing.isEmpty {
                var value = SyncedValue(record)
                let fold = folded(existing)[cloudID] ?? SyncedValue(seenAt: nil, pendingSince: nil)
                let known = write.knownStates[record.id] ?? SyncedValue(seenAt: nil, pendingSince: nil)
                // Rows as the device knew them: its move is a decision over what it saw, and stands. Changed under
                // it by another device: the two moved without knowing of each other, and the first stands.
                if fold != known, let first = fold.first(against: value), first != value {
                    value = first
                    overruled[record.id] = value
                }
                // Every row for the photo gets the same values, so duplicates from two devices converge.
                for row in existing {
                    if row.seenAt != value.seenAt { row.seenAt = value.seenAt }
                    if row.pendingSince != value.pendingSince { row.pendingSince = value.pendingSince }
                }
            } else {
                let row = SyncedPhotoState(cloudID: cloudID, seenAt: record.seenAt, pendingSince: record.pendingSince)
                modelContext.insert(row)
                byCloud[cloudID] = [row]
            }
        }
        return overruled
    }

    private func applyLocal(_ write: LedgerWrite) throws {
        let localIDs = Array(Set(write.upserts.map(\.id)).union(write.removals.map(\.localID)))
        guard !localIDs.isEmpty else { return }
        let rows = try modelContext.fetch(FetchDescriptor<LocalPhotoState>(predicate: #Predicate { localIDs.contains($0.localID) }))
        var byLocal: [String: LocalPhotoState] = [:]
        for row in rows { byLocal[row.localID] = row }
        for removal in write.removals {
            if let row = byLocal.removeValue(forKey: removal.localID) { modelContext.delete(row) }
        }
        for record in write.upserts {
            if record.cloudID != nil {
                // Now known to iCloud: the synced store has it, a local row would be a stale second copy.
                if let row = byLocal.removeValue(forKey: record.id) { modelContext.delete(row) }
            } else if let row = byLocal[record.id] {
                if row.seenAt != record.seenAt { row.seenAt = record.seenAt }
                if row.pendingSince != record.pendingSince { row.pendingSince = record.pendingSince }
            } else {
                let row = LocalPhotoState(localID: record.id, seenAt: record.seenAt, pendingSince: record.pendingSince)
                modelContext.insert(row)
                byLocal[record.id] = row
            }
        }
    }

    private func save(_ batch: ReviewBatch) throws {
        let payload = try JSONEncoder().encode(batch)
        let key = Self.batchKey
        var descriptor = FetchDescriptor<BatchRecord>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        if let row = try modelContext.fetch(descriptor).first {
            guard row.payload != payload else { return }
            row.payload = payload
            row.savedAt = .now
        } else {
            modelContext.insert(BatchRecord(key: key, payload: payload, savedAt: .now))
        }
    }

    // MARK: Changes from other devices

    /// What other devices changed since the last call, read from the store's history: iCloud's imports are the
    /// transactions the mirroring signed as such. Each touched photo comes back with its rows' current fold, or as
    /// deleted when none is left. Deletions by anyone else (the system emptying the store on an account change)
    /// are not other devices' word: they are reported as a purge.
    public func remoteChanges() throws -> RemoteChanges {
        prepareContext()
        do {
            return try readRemoteChanges()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func readRemoteChanges() throws -> RemoteChanges {
        // History tokens belong to one store each: a token of the synced store compares only against that store's
        // transactions, which is the one wanted; the local store's history is of no interest here.
        var descriptor = HistoryDescriptor<DefaultHistoryTransaction>()
        if let token = try storedToken() {
            descriptor.predicate = #Predicate { $0.token > token }
        }
        var transactions: [DefaultHistoryTransaction]
        do {
            transactions = try modelContext.fetchHistory(descriptor)
        } catch {
            // The token's transaction is gone (pruned by an earlier build, or the store replaced under it): the
            // history cannot say what changed, and would never again. Everything the store holds instead.
            return try everythingResynced()
        }
        let knownStoreID = try metadata(forKey: Self.syncedStoreKey).flatMap { String(data: $0, encoding: .utf8) }
        guard let storeID = knownStoreID ?? transactions.first(where: { $0.changes.contains(where: Self.touchesSyncedState) })?.storeIdentifier else {
            return RemoteChanges()
        }
        if knownStoreID == nil { try setMetadata(Data(storeID.utf8), forKey: Self.syncedStoreKey) }
        transactions = transactions.filter { $0.storeIdentifier == storeID }.sorted { $0.transactionIdentifier < $1.transactionIdentifier }
        guard let last = transactions.last else { return RemoteChanges() }
        var touched: Set<PersistentIdentifier> = []
        var cloudIDs: Set<String> = []
        var result = RemoteChanges()
        for transaction in transactions where transaction.author != Self.author {
            let isImport = transaction.author == Self.importAuthor
            for change in transaction.changes {
                switch change {
                case .insert(let insert):
                    if isImport, insert is DefaultHistoryInsert<SyncedPhotoState> { touched.insert(insert.changedPersistentIdentifier) }
                case .update(let update):
                    if isImport, update is DefaultHistoryUpdate<SyncedPhotoState> { touched.insert(update.changedPersistentIdentifier) }
                case .delete(let delete):
                    guard let delete = delete as? DefaultHistoryDelete<SyncedPhotoState> else { break }
                    if !isImport {
                        result.purged = true
                    } else if let cloudID = delete.tombstone[\SyncedPhotoState.cloudID] as? String, !cloudID.isEmpty {
                        cloudIDs.insert(cloudID)
                    }
                @unknown default:
                    break
                }
            }
        }
        if !touched.isEmpty {
            let ids = Array(touched)
            let rows = try modelContext.fetch(FetchDescriptor<SyncedPhotoState>(predicate: #Predicate { ids.contains($0.persistentModelID) }))
            cloudIDs.formUnion(rows.map(\.cloudID).filter { !$0.isEmpty })
        }
        if !cloudIDs.isEmpty {
            let list = Array(cloudIDs)
            let rows = try modelContext.fetch(FetchDescriptor<SyncedPhotoState>(predicate: #Predicate { list.contains($0.cloudID) }))
            var folded: [String: SyncedValue] = [:]
            for row in rows {
                let value = SyncedValue(seenAt: row.seenAt, pendingSince: row.pendingSince)
                folded[row.cloudID] = folded[row.cloudID].map { $0.merged(with: value) } ?? value
            }
            for cloudID in list.sorted() {
                if let value = folded[cloudID] {
                    result.changes.append(.updated(cloudID: cloudID, value: value))
                } else {
                    result.changes.append(.deleted(cloudID: cloudID))
                }
            }
        }
        try store(token: last.token, at: last.timestamp)
        try pruneHistory(before: last.timestamp.addingTimeInterval(-Self.historyRetention))
        return result
    }

    /// The whole synced store, folded, in place of what changed, and a fresh token at the end of the history as
    /// it stands (none when there is no history at all: the next read then starts from the beginning).
    private func everythingResynced() throws -> RemoteChanges {
        var result = RemoteChanges()
        result.everything = folded(try modelContext.fetch(FetchDescriptor<SyncedPhotoState>()))
        // Tokens belong to one store each: the synced store's last transaction, not the local store's.
        let storeID = try metadata(forKey: Self.syncedStoreKey).flatMap { String(data: $0, encoding: .utf8) }
        let synced = try modelContext.fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>()).filter { transaction in
            storeID.map { transaction.storeIdentifier == $0 } ?? transaction.changes.contains(where: Self.touchesSyncedState)
        }
        if let last = synced.sorted(by: { $0.transactionIdentifier < $1.transactionIdentifier }).last {
            try store(token: last.token, at: last.timestamp)
        } else {
            try removeMetadata(forKey: Self.historyTokenKey)
            try removeMetadata(forKey: Self.historyTokenTimeKey)
            if modelContext.hasChanges { try modelContext.save() }
        }
        return result
    }

    private func folded(_ rows: [SyncedPhotoState]) -> [String: SyncedValue] {
        var folded: [String: SyncedValue] = [:]
        for row in rows where !row.cloudID.isEmpty {
            let value = SyncedValue(seenAt: row.seenAt, pendingSince: row.pendingSince)
            folded[row.cloudID] = folded[row.cloudID].map { $0.merged(with: value) } ?? value
        }
        return folded
    }

    /// Drops history older than the retention, whether or not anything reads it: with sync off nothing does, and
    /// every write would otherwise add to it for good. Never past the stored token's transaction, which the next
    /// read starts from.
    public func pruneHistory() throws {
        prepareContext()
        var before = Date().addingTimeInterval(-Self.historyRetention)
        if let tokenTime = try storedTokenTime() { before = min(before, tokenTime) }
        try pruneHistory(before: before)
    }

    private static func touchesSyncedState(_ change: HistoryChange) -> Bool {
        switch change {
        case .insert(let insert): insert is DefaultHistoryInsert<SyncedPhotoState>
        case .update(let update): update is DefaultHistoryUpdate<SyncedPhotoState>
        case .delete(let delete): delete is DefaultHistoryDelete<SyncedPhotoState>
        @unknown default: false
        }
    }

    private func storedToken() throws -> DefaultHistoryToken? {
        guard let value = try metadata(forKey: Self.historyTokenKey) else { return nil }
        return try JSONDecoder().decode(DefaultHistoryToken.self, from: value)
    }

    private func storedTokenTime() throws -> Date? {
        guard let value = try metadata(forKey: Self.historyTokenTimeKey) else { return nil }
        return try JSONDecoder().decode(Date.self, from: value)
    }

    private func store(token: DefaultHistoryToken, at time: Date) throws {
        try setMetadata(try JSONEncoder().encode(token), forKey: Self.historyTokenKey)
        try setMetadata(try JSONEncoder().encode(time), forKey: Self.historyTokenTimeKey)
        if modelContext.hasChanges { try modelContext.save() }
    }

    private func removeMetadata(forKey key: String) throws {
        var descriptor = FetchDescriptor<LocalMetadata>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        if let row = try modelContext.fetch(descriptor).first { modelContext.delete(row) }
    }

    private func metadata(forKey key: String) throws -> Data? {
        var descriptor = FetchDescriptor<LocalMetadata>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.value
    }

    private func setMetadata(_ value: Data, forKey key: String) throws {
        var descriptor = FetchDescriptor<LocalMetadata>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        if let row = try modelContext.fetch(descriptor).first {
            if row.value != value { row.value = value }
        } else {
            modelContext.insert(LocalMetadata(key: key, value: value))
        }
    }

    private func pruneHistory(before date: Date) throws {
        try modelContext.deleteHistory(HistoryDescriptor<DefaultHistoryTransaction>(predicate: #Predicate { $0.timestamp < date }))
    }
}
