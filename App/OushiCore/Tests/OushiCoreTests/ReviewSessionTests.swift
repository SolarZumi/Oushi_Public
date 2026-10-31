// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import Foundation
import Testing
@testable import OushiCore

/// PhotoKit stood in for by a table: local identifiers that start with "cloudless" have no iCloud identifier.
private struct TableResolver: PhotoIdentityResolving {
    func cloudIdentifiers(forLocalIdentifiers ids: [String]) async -> [String: String] {
        Dictionary(uniqueKeysWithValues: ids.filter { !$0.hasPrefix("cloudless") }.map { ($0, "cloud-\($0)") })
    }

    func localIdentifiers(forCloudIdentifiers ids: [String]) async -> [String: String] {
        Dictionary(uniqueKeysWithValues: ids.filter { $0.hasPrefix("cloud-") }.map { ($0, String($0.dropFirst(6))) })
    }
}

@MainActor
@Suite("Review session")
struct ReviewSessionTests {
    private let photos = (1...20).map { "photo-\($0)" }

    private func session(over repository: LedgerRepository, available: [String]? = nil, order: ReviewOrder = .random) async -> ReviewSession {
        let session = ReviewSession(repository: repository, resolver: TableResolver(), order: order)
        await session.whenLoaded()
        session.synchronize(availableIDs: available ?? photos, hasFullAccess: true)
        await session.settle()
        return session
    }

    @Test func movesArePersistedAndReadBack() async throws {
        let repository = try LedgerRepository.open(.inMemory())
        // In library order the two photos moved on are ones iCloud knows, and the batch also holds one it does not.
        let library = Array(photos.prefix(5)) + ["cloudless-1"] + photos.dropFirst(5)
        let first = await session(over: repository, available: library, order: .newest)
        #expect(first.batch.ids.count == 15 && first.unseenCount == 21 && first.batch.ids.contains("cloudless-1"))
        let kept = first.batch.ids[0]
        let queued = first.batch.ids[1]
        first.advance(delete: false, direction: .left)
        first.advance(delete: true, direction: .down)
        #expect(first.pendingIDs == [queued] && first.pendingCount == 1 && first.unseenCount == 19 && first.seenCount == 2)
        await first.flush()

        let snapshot = try await repository.load()
        #expect(snapshot.synced["cloud-\(kept)"]?.pendingSince == nil && snapshot.synced["cloud-\(kept)"]?.seenAt != nil, "A kept photo is written as seen under its iCloud identifier")
        #expect(snapshot.synced["cloud-\(queued)"]?.pendingSince != nil, "A queued photo is written as pending")
        #expect(snapshot.aliases[kept] == "cloud-\(kept)", "The identifier found on the way is kept as an alias")
        #expect(snapshot.batch == first.batch, "The batch is written with the records")

        let second = await session(over: repository, available: library, order: .newest)
        #expect(second.batch == first.batch, "A relaunch shows the same batch at the same position")
        #expect(second.pendingIDs == [queued] && second.pendingCount == 1 && second.unseenCount == 19)
        second.undo()
        #expect(second.pendingIDs.isEmpty && second.batch.currentID == queued, "Undo works across relaunches")
    }

    @Test func photosWithoutIdentifierStayLocal() async throws {
        let repository = try LedgerRepository.open(.inMemory())
        let session = await session(over: repository, available: ["cloudless-1", "cloudless-2"])
        session.advance(delete: true)
        await session.flush()
        let snapshot = try await repository.load()
        #expect(snapshot.synced.isEmpty && snapshot.local.count == 1, "A photo iCloud does not know is a local record")
        #expect(snapshot.local.first?.pendingSince != nil)
    }

    @Test func remoteChangesReachTheState() async throws {
        let repository = try LedgerRepository.open(.inMemory())
        let session = await session(over: repository)
        let photo = photos[3]
        // Another device queued the photo: a row arrives under its iCloud identifier.
        try await repository.insertRawSyncedRows([("cloud-\(photo)", .now, .now)], author: "NSCloudKitMirroringDelegate.import")
        await session.pullNow()
        await session.settle()
        #expect(session.pendingIDs == [photo], "The other device's queueing shows up here, matched to the photo")
        #expect(session.pendingCount == 1 && session.unseenCount == 19)

        // That device restored it from the pool.
        try await repository.updateRawSyncedRows(cloudID: "cloud-\(photo)", pendingSince: nil, author: "NSCloudKitMirroringDelegate.import")
        await session.pullNow()
        #expect(session.pendingIDs.isEmpty && session.pendingCount == 0 && session.seenCount == 1)

        // And then reset its progress: the row is gone.
        try await repository.deleteRawSyncedRows(cloudID: "cloud-\(photo)", author: "NSCloudKitMirroringDelegate.import")
        await session.pullNow()
        #expect(session.seenCount == 0 && session.unseenCount == 20, "A record deleted elsewhere is let go of here")
    }

    @Test func theFirstMoveOnAPhotoStands() async throws {
        let repository = try LedgerRepository.open(.inMemory())
        let resolver = SlowResolver(delay: .milliseconds(150))
        let session = ReviewSession(repository: repository, resolver: resolver)
        await session.whenLoaded()
        session.synchronize(availableIDs: photos, hasFullAccess: true)
        await session.settle()
        let photo = try #require(session.batch.currentID)
        // Kept here; before its first write lands (the resolver is slow), iCloud says another device queued it a
        // moment later, without knowing of the keep.
        session.advance(delete: false)
        try await repository.insertRawSyncedRows([("cloud-\(photo)", .now, .now)], author: "NSCloudKitMirroringDelegate.import")
        await session.pullNow()
        await session.settle()
        #expect(session.pendingIDs.isEmpty, "The keep was first: it stands")
        let snapshot = try await repository.load()
        #expect(snapshot.synced["cloud-\(photo)"]?.pendingSince == nil, "And is what the store holds, on every row")
        #expect(snapshot.aliases[photo] == "cloud-\(photo)")

        // The other way round: another device queued a photo before this one kept it.
        let next = try #require(session.batch.currentID)
        try await repository.insertRawSyncedRows([("cloud-\(next)", .now, .now)], author: "NSCloudKitMirroringDelegate.import")
        session.advance(delete: false)
        await session.pullNow()
        await session.settle()
        #expect(session.pendingIDs == [next], "The queueing was first: the keep gives way")
        #expect(try await repository.load().synced["cloud-\(next)"]?.pendingSince != nil)
    }

    @Test func undoDuringTheFirstWriteStillRemovesTheRow() async throws {
        let repository = try LedgerRepository.open(.inMemory())
        let session = ReviewSession(repository: repository, resolver: SlowResolver(delay: .milliseconds(150)))
        await session.whenLoaded()
        session.synchronize(availableIDs: photos, hasFullAccess: true)
        await session.settle()
        let photo = try #require(session.batch.currentID)
        session.advance(delete: true)
        try? await Task.sleep(for: .milliseconds(30))
        // The first write is still resolving the identifier when the swipe is undone.
        session.undo()
        await session.settle()
        let snapshot = try await repository.load()
        #expect(snapshot.synced["cloud-\(photo)"] == nil, "The undone swipe leaves no row behind")
        #expect(snapshot.aliases[photo] == "cloud-\(photo)", "PhotoKit's answer is kept: the photo is still here")
        #expect(snapshot.batch?.cursor == 0 && snapshot.batch == session.batch, "The batch on disk is the undone one")
    }

    @Test func unreadableBatchCostsOnlyTheBatch() async throws {
        let repository = try LedgerRepository.open(.inMemory())
        let first = await session(over: repository)
        first.advance(delete: true)
        await first.flush()
        try await repository.corruptBatchRow()
        let second = await session(over: repository)
        #expect(second.pendingIDs.count == 1, "The ledger is read")
        #expect(!second.batch.ids.isEmpty && second.batch.cursor == 0, "A fresh batch replaces the unreadable one")
        #expect(second.issues.isEmpty)
    }

    @Test func photosLeavingTheDeviceKeepTheirSyncedState() async throws {
        let repository = try LedgerRepository.open(.inMemory())
        let session = await session(over: repository)
        let queued = try #require(session.batch.currentID)
        session.advance(delete: true)
        await session.flush()

        // The photo is gone from this device (not downloaded, or deleted elsewhere).
        session.synchronize(availableIDs: photos.filter { $0 != queued }, hasFullAccess: true)
        await session.settle()
        #expect(!session.pendingIDs.contains(queued) && session.pendingCount == 0)
        var snapshot = try await repository.load()
        #expect(snapshot.synced["cloud-\(queued)"]?.pendingSince != nil, "Its state stays in the synced store")
        #expect(snapshot.aliases[queued] == nil, "Only the alias goes")

        // It comes back: the state finds it again.
        session.synchronize(availableIDs: photos, hasFullAccess: true)
        await session.settle()
        #expect(session.pendingIDs == [queued] && session.pendingCount == 1)
        snapshot = try await repository.load()
        #expect(snapshot.aliases[queued] == "cloud-\(queued)")

        // Under limited access a missing photo is merely hidden: nothing is let go of.
        session.synchronize(availableIDs: photos.filter { $0 != queued }, hasFullAccess: false)
        await session.settle()
        #expect(session.pendingIDs == [queued] && session.pendingCount == 0)
    }

    @Test func deletingFromTheLibraryForgetsEverywhere() async throws {
        let repository = try LedgerRepository.open(.inMemory())
        let session = await session(over: repository)
        let first = try #require(session.batch.currentID)
        session.advance(delete: true)
        let second = try #require(session.batch.currentID)
        session.advance(delete: true)
        await session.flush()

        let cancelled = await session.deleteFromLibrary(ids: [first]) { _ in nil }
        #expect(cancelled == nil && session.pendingIDs == [first, second], "A cancelled deletion changes nothing")

        let refused = await session.deleteFromLibrary(ids: [first]) { _ in [] }
        #expect(refused == [] && session.pendingIDs == [first, second], "A photo the library would not delete keeps its record")

        let deleted = await session.deleteFromLibrary(ids: [first]) { $0 }
        await session.flush()
        #expect(deleted == [first] && session.pendingIDs == [second] && session.pendingCount == 1)
        #expect(session.availableCount == 19, "The photo counts as gone before the library says so")
        let snapshot = try await repository.load()
        #expect(snapshot.synced["cloud-\(first)"] == nil, "The record is deleted, so every device forgets it")
        #expect(snapshot.aliases[first] == nil)
        #expect(snapshot.synced["cloud-\(second)"] != nil)
    }

    @Test func resetKeepsThePoolAndStartsOver() async throws {
        let repository = try LedgerRepository.open(.inMemory())
        let session = await session(over: repository)
        let seen = try #require(session.batch.currentID)
        session.advance(delete: false)
        let queued = try #require(session.batch.currentID)
        session.advance(delete: true)
        session.resetProgress()
        await session.flush()
        #expect(session.pendingIDs == [queued] && session.unseenCount == 19 && session.seenCount == 1)
        #expect(session.batch.cursor == 0 && !session.batch.ids.contains(queued))
        let snapshot = try await repository.load()
        #expect(snapshot.synced["cloud-\(seen)"] == nil, "A seen mark dropped is a row deleted")
        #expect(snapshot.synced["cloud-\(queued)"]?.pendingSince != nil)
    }

    @Test func changingTheOrderRefillsWhatIsToCome() async throws {
        let repository = try LedgerRepository.open(.inMemory())
        let session = await session(over: repository)
        session.advance(delete: false)
        session.advance(delete: false)
        let current = try #require(session.batch.currentID)
        session.setOrder(.newest)
        // Two reviewed and the current one stay; after them, the newest photos there are, not the batch's own rest.
        let kept = Set(session.batch.ids.prefix(3))
        let expected = Array(photos.filter { !kept.contains($0) }.prefix(12))
        #expect(Array(session.batch.ids.dropFirst(3)) == expected, "The next photo is the first there is in the new order")
        #expect(session.batch.ids.count == 15 && session.batch.currentID == current && session.batch.cursor == 2)
        session.setOrder(.oldest)
        #expect(Array(session.batch.ids.dropFirst(3)) == Array(photos.reversed().filter { !kept.contains($0) }.prefix(12)))
    }

    @Test func batchSizeAndOrderFollowTheSettings() async throws {
        let repository = try LedgerRepository.open(.inMemory())
        let session = await session(over: repository)
        session.setBatchSize(20)
        #expect(session.batch.ids.count == 20)
        session.setOrder(.newest)
        let rest = Array(session.batch.ids.dropFirst())
        #expect(rest == rest.sorted { photos.firstIndex(of: $0)! < photos.firstIndex(of: $1)! }, "The photos still to come follow the library's order")
        session.setBatchSize(ReviewSession.unlimitedBatchSize)
        #expect(session.isBatchUnlimited && session.batch.ids.count == 20, "Unlimited takes every photo there is")
        await session.flush()
        let snapshot = try await repository.load()
        #expect(snapshot.batch == session.batch)
    }

    @Test func aRecordResolvedLaterCanStillBeRemoved() async throws {
        let repository = try LedgerRepository.open(.inMemory())
        let resolver = SwitchingResolver()
        let session = ReviewSession(repository: repository, resolver: resolver)
        await session.whenLoaded()
        session.synchronize(availableIDs: ["photo-1", "photo-2"], hasFullAccess: true)
        await session.settle()
        let photo = try #require(session.batch.currentID)
        session.advance(delete: true)
        await session.flush()
        var snapshot = try await repository.load()
        #expect(snapshot.local.map(\.id) == [photo] && snapshot.synced.isEmpty, "Not known to iCloud yet: a local record")

        // iCloud learns of the photo (its upload done); the library's next change asks again.
        await resolver.learn(photo)
        session.synchronize(availableIDs: ["photo-1", "photo-2"], hasFullAccess: true)
        await session.settle()
        snapshot = try await repository.load()
        #expect(snapshot.synced["cloud-\(photo)"]?.pendingSince != nil && snapshot.local.isEmpty, "Moved to the synced store")
        #expect(snapshot.aliases[photo] == "cloud-\(photo)", "With the alias that later removals go by")

        session.undo()
        await session.settle()
        snapshot = try await repository.load()
        #expect(snapshot.synced["cloud-\(photo)"] == nil, "The undone swipe leaves no row behind")
    }

    @Test func aLocalRecordMeetingAnotherDevicesStateIsFolded() async throws {
        let repository = try LedgerRepository.open(.inMemory())
        let resolver = SwitchingResolver()
        let session = ReviewSession(repository: repository, resolver: resolver)
        await session.whenLoaded()
        session.synchronize(availableIDs: ["photo-1"], hasFullAccess: true)
        await session.settle()
        // Queued here before iCloud knew the photo.
        session.advance(delete: true)
        await session.flush()
        // Meanwhile another device, which had the photo from iCloud, kept it: seen later, not queued.
        let later = Date().addingTimeInterval(3600)
        try await repository.insertRawSyncedRows([("cloud-photo-1", later, nil)], author: "NSCloudKitMirroringDelegate.import")
        await session.pullNow()
        await session.settle()
        #expect(session.pendingIDs == ["photo-1"], "Not matched to the photo yet: the state waits as an orphan")

        await resolver.learn("photo-1")
        session.synchronize(availableIDs: ["photo-1"], hasFullAccess: true)
        await session.settle()
        #expect(session.pendingIDs == ["photo-1"], "The queueing here was the first move: it stands")
        let snapshot = try await repository.load()
        let value = try #require(snapshot.synced["cloud-photo-1"])
        #expect(value.pendingSince != nil && value.seenAt != later, "On every row")
        #expect(snapshot.local.isEmpty, "The local row went with it")
    }

    @Test func photosSeenElsewhereLeaveTheBatch() async throws {
        let repository = try LedgerRepository.open(.inMemory())
        let session = ReviewSession(repository: repository, resolver: TableResolver(), batchSize: 15, order: .newest)
        await session.whenLoaded()
        session.synchronize(availableIDs: photos, hasFullAccess: true)
        await session.settle()
        #expect(session.batch.ids == Array(photos.prefix(15)))
        var transactions = 0
        session.changeTransaction = { change in
            transactions += 1
            change()
        }
        // Another device saw the first and the third photo: the first fades out for the second, the third is skipped.
        try await repository.insertRawSyncedRows([("cloud-photo-1", .now, nil), ("cloud-photo-3", .now, nil)], author: "NSCloudKitMirroringDelegate.import")
        await session.pullNow()
        await session.settle()
        #expect(session.batch.currentID == "photo-2" && !session.batch.ids.contains("photo-3") && session.batch.ids.count == 13)
        #expect(session.seenCount == 2 && transactions == 1, "One animated change")
        // Everything still to come seen elsewhere: the next batch starts by itself, so the device keeps up.
        try await repository.insertRawSyncedRows(Array(photos[1..<15]).map { ("cloud-\($0)", Date.now, nil) }, author: "NSCloudKitMirroringDelegate.import")
        await session.pullNow()
        await session.settle()
        #expect(session.batch.ids == Array(photos[15...]) && session.batch.currentID == "photo-16")
        #expect(session.unseenCount == 5)
    }

    @Test func photosSeenElsewhereWhileClosedLeaveTheBatchAtLaunch() async throws {
        let repository = try LedgerRepository.open(.inMemory())
        let first = ReviewSession(repository: repository, resolver: TableResolver(), batchSize: 15, order: .newest)
        await first.whenLoaded()
        first.synchronize(availableIDs: photos, hasFullAccess: true)
        await first.settle()
        // Seen here once, then progress reset: the photo is known to iCloud and comes up again.
        first.advance(delete: false)
        await first.flush()
        first.resetProgress()
        await first.flush()
        #expect(first.batch.currentID == "photo-1")
        // Seen on another device while this app was closed.
        try await repository.insertRawSyncedRows([("cloud-photo-1", .now, nil)], author: "NSCloudKitMirroringDelegate.import")
        let second = ReviewSession(repository: repository, resolver: TableResolver(), batchSize: 15, order: .newest)
        await second.whenLoaded()
        #expect(second.batch.currentID == "photo-2" && !second.batch.ids.contains("photo-1"), "Gone from the batch before anything is shown")
    }

    @Test func aPurgedStoreIsWrittenBack() async throws {
        let repository = try LedgerRepository.open(.inMemory())
        let session = await session(over: repository)
        let photo = try #require(session.batch.currentID)
        session.advance(delete: true)
        await session.flush()
        await session.pullNow()
        // The system emptied the synced store (an account change): not another device's word.
        try await repository.deleteRawSyncedRows(cloudID: "cloud-\(photo)", author: "NSCloudKitMirroringDelegate.reset")
        await session.pullNow()
        await session.settle()
        #expect(session.pendingIDs == [photo], "What the device knew stays")
        let snapshot = try await repository.load()
        #expect(snapshot.synced["cloud-\(photo)"]?.pendingSince != nil, "And is written back, to go up to whatever account there is now")
    }

    @Test func anExpiredHistoryTokenResyncsTheWholeStore() async throws {
        let repository = try LedgerRepository.open(.inMemory())
        // In library order the photo kept here is not the one the other device queues.
        let session = await session(over: repository, order: .newest)
        session.advance(delete: false)
        await session.flush()
        await session.pullNow()
        try await repository.expireHistory()
        let other = photos[5]
        try await repository.insertRawSyncedRows([("cloud-\(other)", .now, .now)], author: "NSCloudKitMirroringDelegate.import")
        await session.pullNow()
        await session.settle()
        #expect(session.pendingIDs == [other], "The other device's queueing comes through the whole store")
        #expect(session.seenCount == 2)
    }

    @Test func hiddenPhotosKeepTheirLocalRecords() async throws {
        let repository = try LedgerRepository.open(.inMemory())
        let session = await session(over: repository, available: ["cloudless-1", "cloudless-2"])
        let queued = try #require(session.batch.currentID)
        session.advance(delete: true)
        await session.flush()
        // Hidden in Photos: gone from what the app can see, under full access.
        session.synchronize(availableIDs: ["cloudless-1", "cloudless-2"].filter { $0 != queued }, hasFullAccess: true)
        await session.settle()
        #expect(session.pendingIDs.isEmpty && session.pendingCount == 0)
        #expect(try await repository.load().local.map(\.id) == [queued], "The record stays in the store")
        // Shown again: the record is back.
        session.synchronize(availableIDs: ["cloudless-1", "cloudless-2"], hasFullAccess: true)
        await session.settle()
        #expect(session.pendingIDs == [queued] && session.pendingCount == 1)
    }

    @Test func legacyFilesAreImportedOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try LegacyStores.writeFixture(
            in: directory,
            records: [
                PhotoRecord(id: "photo-1", cloudID: "cloud-photo-1", seenAt: .now, pendingSince: nil),
                PhotoRecord(id: "photo-2", seenAt: .now, pendingSince: .now),
            ],
            batch: ReviewBatch(ids: ["photo-3", "photo-4"])
        )
        let session = ReviewSession(
            directory: directory, cloudContainerID: "iCloud.test", syncEnabled: false,
            batchSize: 15, order: .random, resolver: TableResolver(), accounts: NoAccounts()
        )
        await session.whenLoaded()
        session.synchronize(availableIDs: photos, hasFullAccess: true)
        await session.settle()
        #expect(session.batch.ids == ["photo-3", "photo-4"], "The old batch carries over")
        #expect(session.pendingIDs == ["photo-2"] && session.seenCount == 2, "The old records carry over")
        #expect(!LegacyStores.exist(in: directory), "The old files go once their contents are in the new store")
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("synced.store").path))
    }
}

private struct NoAccounts: CloudAccountChecking {
    func hasAccount() async -> Bool? { false }
}

/// PhotoKit learning of photos as time goes: it answers for a photo only once told to.
private actor SwitchingResolver: PhotoIdentityResolving {
    private var known: Set<String> = []

    func learn(_ id: String) {
        known.insert(id)
    }

    func cloudIdentifiers(forLocalIdentifiers ids: [String]) async -> [String: String] {
        Dictionary(uniqueKeysWithValues: ids.filter(known.contains).map { ($0, "cloud-\($0)") })
    }

    func localIdentifiers(forCloudIdentifiers ids: [String]) async -> [String: String] {
        Dictionary(uniqueKeysWithValues: ids.filter { $0.hasPrefix("cloud-") && known.contains(String($0.dropFirst(6))) }.map { ($0, String($0.dropFirst(6))) })
    }
}

/// The table resolver, taking its time, so a write is caught on its way.
private struct SlowResolver: PhotoIdentityResolving {
    let delay: Duration

    func cloudIdentifiers(forLocalIdentifiers ids: [String]) async -> [String: String] {
        try? await Task.sleep(for: delay)
        return await TableResolver().cloudIdentifiers(forLocalIdentifiers: ids)
    }

    func localIdentifiers(forCloudIdentifiers ids: [String]) async -> [String: String] {
        try? await Task.sleep(for: delay)
        return await TableResolver().localIdentifiers(forCloudIdentifiers: ids)
    }
}
