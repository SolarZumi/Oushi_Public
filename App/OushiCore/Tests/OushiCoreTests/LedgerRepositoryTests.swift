// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import Foundation
import SwiftData
import Testing
@testable import OushiCore

@Suite("Ledger repository")
struct LedgerRepositoryTests {
    private let day: TimeInterval = 86_400

    @Test func writesComeBackFolded() async throws {
        let repository = try LedgerRepository.open(.inMemory())
        var write = LedgerWrite()
        write.upserts = [
            PhotoRecord(id: "local-1", cloudID: "cloud-1", seenAt: Date(timeIntervalSince1970: day), pendingSince: nil),
            PhotoRecord(id: "local-2", seenAt: Date(timeIntervalSince1970: 2 * day), pendingSince: Date(timeIntervalSince1970: 2 * day)),
        ]
        write.aliases = ["local-1": "cloud-1"]
        write.batch = ReviewBatch(ids: ["local-1", "local-2"])
        try await repository.apply(write)

        let snapshot = try await repository.load()
        #expect(snapshot.synced["cloud-1"] == SyncedValue(seenAt: Date(timeIntervalSince1970: day), pendingSince: nil))
        #expect(snapshot.local == [PhotoRecord(id: "local-2", seenAt: Date(timeIntervalSince1970: 2 * day), pendingSince: Date(timeIntervalSince1970: 2 * day))])
        #expect(snapshot.aliases == ["local-1": "cloud-1"])
        #expect(snapshot.batch == ReviewBatch(ids: ["local-1", "local-2"]))
        #expect(snapshot.duplicated.isEmpty)

        // A photo iCloud learns the identifier of moves from the local store to the synced one.
        var move = LedgerWrite()
        move.upserts = [PhotoRecord(id: "local-2", cloudID: "cloud-2", seenAt: Date(timeIntervalSince1970: 2 * day), pendingSince: nil)]
        move.aliases = ["local-2": "cloud-2"]
        try await repository.apply(move)
        let moved = try await repository.load()
        #expect(moved.local.isEmpty, "The local row goes once the synced one exists")
        #expect(moved.synced["cloud-2"]?.pendingSince == nil)

        // Removal by cloud identifier deletes the synced rows; by local identifier the local one.
        var removal = LedgerWrite()
        removal.removals = [LedgerWrite.Removal(localID: "local-1", cloudID: "cloud-1")]
        removal.removedAliases = ["local-1"]
        try await repository.apply(removal)
        let afterRemoval = try await repository.load()
        #expect(afterRemoval.synced["cloud-1"] == nil)
        #expect(afterRemoval.aliases["local-1"] == nil)
        #expect(afterRemoval.synced["cloud-2"] != nil)
    }

    @Test func duplicateRowsFoldAndConverge() async throws {
        let repository = try LedgerRepository.open(.inMemory())
        // Two devices wrote the same photo before syncing: two rows under one identifier.
        try await repository.insertRawSyncedRows([
            ("cloud-1", Date(timeIntervalSince1970: day), nil),
            ("cloud-1", Date(timeIntervalSince1970: 3 * day), Date(timeIntervalSince1970: 2 * day)),
        ], author: "other-device")
        let snapshot = try await repository.load()
        let fold = SyncedValue(seenAt: Date(timeIntervalSince1970: day), pendingSince: nil)
        #expect(snapshot.synced["cloud-1"] == fold, "The move made first stands")
        #expect(snapshot.duplicated == ["cloud-1"])

        // A move made without knowing of the rows (the device knew no state) is the later one: it is overruled.
        var unknowing = LedgerWrite()
        unknowing.upserts = [PhotoRecord(id: "local-1", cloudID: "cloud-1", seenAt: Date(timeIntervalSince1970: 4 * day), pendingSince: Date(timeIntervalSince1970: 4 * day))]
        #expect(try await repository.apply(unknowing) == ["local-1": fold])
        #expect(try await repository.rawSyncedRows(cloudID: "cloud-1").allSatisfy { $0 == fold })

        // A move over the rows as the device knew them is a decision, and stands on every row.
        var write = LedgerWrite()
        write.upserts = [PhotoRecord(id: "local-1", cloudID: "cloud-1", seenAt: Date(timeIntervalSince1970: 4 * day), pendingSince: nil)]
        write.knownStates = ["local-1": fold]
        #expect(try await repository.apply(write).isEmpty)
        let rows = try await repository.rawSyncedRows(cloudID: "cloud-1")
        #expect(rows.count == 2, "Writing does not delete duplicate rows")
        #expect(rows.allSatisfy { $0.seenAt == Date(timeIntervalSince1970: 4 * day) && $0.pendingSince == nil }, "Every row gets the written value")
    }

    @Test func remoteChangesComeOutOfTheHistory() async throws {
        let repository = try LedgerRepository.open(.inMemory())
        var own = LedgerWrite()
        own.upserts = [PhotoRecord(id: "local-1", cloudID: "cloud-1", seenAt: Date(timeIntervalSince1970: day), pendingSince: nil)]
        try await repository.apply(own)
        #expect(try await repository.remoteChanges().changes.isEmpty, "The app's own writes are not remote changes")

        // Another device's row arrives through the mirroring: a transaction with another author.
        try await repository.insertRawSyncedRows([("cloud-2", Date(timeIntervalSince1970: 2 * day), nil)], author: "NSCloudKitMirroringDelegate.import")
        let arrived = try await repository.remoteChanges()
        #expect(arrived.changes == [.updated(cloudID: "cloud-2", value: SyncedValue(seenAt: Date(timeIntervalSince1970: 2 * day), pendingSince: nil))])
        #expect(try await repository.remoteChanges().changes.isEmpty, "Each change is reported once")

        // An update to the app's own row, and the deletion of another, both from elsewhere.
        try await repository.updateRawSyncedRows(cloudID: "cloud-1", pendingSince: Date(timeIntervalSince1970: 3 * day), author: "NSCloudKitMirroringDelegate.import")
        try await repository.deleteRawSyncedRows(cloudID: "cloud-2", author: "NSCloudKitMirroringDelegate.import")
        let later = try await repository.remoteChanges()
        #expect(later.changes.contains(.updated(cloudID: "cloud-1", value: SyncedValue(seenAt: Date(timeIntervalSince1970: day), pendingSince: Date(timeIntervalSince1970: 3 * day)))))
        #expect(later.changes.contains(.deleted(cloudID: "cloud-2")), "A deletion is reported with the identifier kept in the history")
        #expect(later.changes.count == 2 && !later.purged)

        // The system emptying the store (an account change) is not another device's word: a purge, not deletions.
        try await repository.deleteRawSyncedRows(cloudID: "cloud-1", author: "NSCloudKitMirroringDelegate.reset")
        let purge = try await repository.remoteChanges()
        #expect(purge.purged && purge.changes.isEmpty)
    }

    @Test func anExpiredHistoryTokenIsRecoveredFrom() async throws {
        let repository = try LedgerRepository.open(.inMemory())
        var own = LedgerWrite()
        own.upserts = [PhotoRecord(id: "local-1", cloudID: "cloud-1", seenAt: Date(timeIntervalSince1970: day), pendingSince: nil)]
        try await repository.apply(own)
        _ = try await repository.remoteChanges()
        // The history the token points into is gone (pruned past it by an earlier build).
        try await repository.expireHistory()
        try await repository.insertRawSyncedRows([("cloud-2", Date(timeIntervalSince1970: 2 * day), nil)], author: "NSCloudKitMirroringDelegate.import")
        let resynced = try await repository.remoteChanges()
        #expect(resynced.everything?.keys.sorted() == ["cloud-1", "cloud-2"], "What changed cannot be told: everything the store holds is reported instead")
        #expect(resynced.changes.isEmpty && !resynced.purged)
        // And from there the history is read as usual again.
        try await repository.updateRawSyncedRows(cloudID: "cloud-2", pendingSince: Date(timeIntervalSince1970: 3 * day), author: "NSCloudKitMirroringDelegate.import")
        let later = try await repository.remoteChanges()
        #expect(later.everything == nil)
        #expect(later.changes == [.updated(cloudID: "cloud-2", value: SyncedValue(seenAt: Date(timeIntervalSince1970: 2 * day), pendingSince: Date(timeIntervalSince1970: 3 * day)))])
    }

    @Test func twoDevicesMovingUnknowingOfEachOtherKeepTheFirstMove() async throws {
        let repository = try LedgerRepository.open(.inMemory())
        // Another device kept cloud-1 later than this one queued it, and kept cloud-2 earlier than this one queued
        // it; neither knew of the other.
        try await repository.insertRawSyncedRows([
            ("cloud-1", Date(timeIntervalSince1970: 5 * day), nil),
            ("cloud-2", Date(timeIntervalSince1970: day), nil),
        ], author: "NSCloudKitMirroringDelegate.import")
        var write = LedgerWrite()
        write.upserts = [
            PhotoRecord(id: "local-1", cloudID: "cloud-1", seenAt: Date(timeIntervalSince1970: day), pendingSince: Date(timeIntervalSince1970: day)),
            PhotoRecord(id: "local-2", cloudID: "cloud-2", seenAt: Date(timeIntervalSince1970: 5 * day), pendingSince: Date(timeIntervalSince1970: 5 * day)),
        ]
        write.aliases = ["local-1": "cloud-1", "local-2": "cloud-2"]
        let overruled = try await repository.apply(write)
        let theirs = SyncedValue(seenAt: Date(timeIntervalSince1970: day), pendingSince: nil)
        #expect(overruled == ["local-2": theirs], "This device's later move on cloud-2 gives way")
        let snapshot = try await repository.load()
        #expect(snapshot.synced["cloud-1"] == SyncedValue(seenAt: Date(timeIntervalSince1970: day), pendingSince: Date(timeIntervalSince1970: day)), "This device's earlier move on cloud-1 stands")
        #expect(snapshot.synced["cloud-2"] == theirs)
    }

    @Test func removalsLearnTheirIdentifierFromTheAlias() async throws {
        let repository = try LedgerRepository.open(.inMemory())
        var first = LedgerWrite()
        first.upserts = [PhotoRecord(id: "local-1", cloudID: "cloud-1", seenAt: .now, pendingSince: .now)]
        first.aliases = ["local-1": "cloud-1"]
        try await repository.apply(first)
        // A removal made while that write was on its way knows no identifier.
        var removal = LedgerWrite()
        removal.removals = [LedgerWrite.Removal(localID: "local-1", cloudID: nil)]
        try await repository.apply(removal)
        let snapshot = try await repository.load()
        #expect(snapshot.synced.isEmpty, "The alias said which rows the removal was for")
        #expect(snapshot.aliases["local-1"] == "cloud-1", "And it stays: the photo is still here")
    }

    @Test func legacyFilesAreReadAndRemoved() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try LegacyStores.writeFixture(
            in: directory,
            records: [
                PhotoRecord(id: "old-1", cloudID: "cloud-1", seenAt: Date(timeIntervalSince1970: day), pendingSince: nil),
                PhotoRecord(id: "old-2", seenAt: Date(timeIntervalSince1970: 2 * day), pendingSince: Date(timeIntervalSince1970: 2 * day)),
            ],
            batch: ReviewBatch(ids: ["old-1", "old-2", "old-3"])
        )
        #expect(LegacyStores.exist(in: directory))
        let contents = try LegacyStores.read(in: directory)
        #expect(contents.records.count == 2)
        #expect(contents.records.first { $0.id == "old-1" }?.cloudID == "cloud-1")
        #expect(contents.batch?.ids == ["old-1", "old-2", "old-3"])
        LegacyStores.remove(in: directory)
        #expect(!LegacyStores.exist(in: directory))
    }

    @Test func writesMergeLaterFateWins() {
        var first = LedgerWrite()
        first.upserts = [PhotoRecord(id: "a", seenAt: .now, pendingSince: nil), PhotoRecord(id: "b", seenAt: .now, pendingSince: nil)]
        first.aliases = ["a": "cloud-a"]
        first.batch = ReviewBatch(ids: ["a"])
        var later = LedgerWrite()
        later.removals = [LedgerWrite.Removal(localID: "a", cloudID: "cloud-a")]
        later.removedAliases = ["a"]
        later.upserts = [PhotoRecord(id: "b", seenAt: .now, pendingSince: .now)]
        first.merge(later)
        #expect(first.upserts.map(\.id) == ["b"], "A record removed later is no longer written")
        #expect(first.upserts.first?.pendingSince != nil, "The later value of a record stands")
        #expect(first.removals.map(\.localID) == ["a"])
        #expect(first.aliases.isEmpty && first.removedAliases == ["a"])
        #expect(first.batch == ReviewBatch(ids: ["a"]), "The batch stays when the later write has none")
    }
}

// Test seams: rows written as the mirroring would write them, under another author, outside the repository's API.
extension LedgerRepository {
    func insertRawSyncedRows(_ rows: [(cloudID: String, seenAt: Date?, pendingSince: Date?)], author: String) throws {
        let context = ModelContext(modelContainer)
        context.author = author
        for row in rows {
            context.insert(SyncedPhotoState(cloudID: row.cloudID, seenAt: row.seenAt, pendingSince: row.pendingSince))
        }
        try context.save()
    }

    func updateRawSyncedRows(cloudID: String, pendingSince: Date?, author: String) throws {
        let context = ModelContext(modelContainer)
        context.author = author
        for row in try context.fetch(FetchDescriptor<SyncedPhotoState>(predicate: #Predicate { $0.cloudID == cloudID })) {
            row.pendingSince = pendingSince
        }
        try context.save()
    }

    func deleteRawSyncedRows(cloudID: String, author: String) throws {
        let context = ModelContext(modelContainer)
        context.author = author
        for row in try context.fetch(FetchDescriptor<SyncedPhotoState>(predicate: #Predicate { $0.cloudID == cloudID })) {
            context.delete(row)
        }
        try context.save()
    }

    /// The whole history gone, as if pruned past the stored token.
    func expireHistory() throws {
        try modelContext.deleteHistory(HistoryDescriptor<DefaultHistoryTransaction>())
    }

    func corruptBatchRow() throws {
        let context = ModelContext(modelContainer)
        for row in try context.fetch(FetchDescriptor<BatchRecord>()) { row.payload = Data("not a batch".utf8) }
        try context.save()
    }

    func rawSyncedRows(cloudID: String) throws -> [SyncedValue] {
        let context = ModelContext(modelContainer)
        return try context.fetch(FetchDescriptor<SyncedPhotoState>(predicate: #Predicate { $0.cloudID == cloudID }))
            .map { SyncedValue(seenAt: $0.seenAt, pendingSince: $0.pendingSince) }
    }
}

extension LegacyStores {
    /// Writes files as a 1.0 build left them.
    static func writeFixture(in directory: URL, records: [PhotoRecord], batch: ReviewBatch) throws {
        let schema = Schema([PhotoRecordEntity.self])
        let configuration = ModelConfiguration("legacy", schema: schema, url: ledgerURL(in: directory), cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = ModelContext(container)
        for record in records {
            context.insert(PhotoRecordEntity(id: record.id, cloudID: record.cloudID, seenAt: record.seenAt, pendingSince: record.pendingSince))
        }
        try context.save()
        try JSONEncoder().encode(batch).write(to: batchURL(in: directory))
    }
}
