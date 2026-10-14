// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import Foundation
import Testing
@testable import OushiCore

/// Deterministic shuffles, so batch contents can be reasoned about.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

@Suite("Review state")
struct ReviewStateTests {
    private let assets = (1...40).map { "photo-\($0)" }
    private let day: TimeInterval = 86_400

    private func state(available: [String]? = nil) -> ReviewState {
        var state = ReviewState()
        state.fit(availableIDs: available ?? assets)
        return state
    }

    @Test func batchAndResume() throws {
        var state = state(available: assets + assets)
        #expect(state.batch.ids.count == 15, "A batch should contain 15 unique photos")
        #expect(Set(state.batch.ids).count == 15, "Duplicate library IDs must not repeat")
        let order = state.batch.ids
        state.advance(delete: false, at: Date(timeIntervalSince1970: 1))
        state.advance(delete: true, at: Date(timeIntervalSince1970: 2))

        // The batch and the ledger are saved apart and come back together on relaunch.
        let batchData = try JSONEncoder().encode(state.batch)
        let records = Array(state.ledger.records.values)
        var resumed = ReviewState(
            ledger: ReviewLedger(records: records),
            batch: try JSONDecoder().decode(ReviewBatch.self, from: batchData)
        )
        resumed.fit(availableIDs: assets.reversed())
        #expect(resumed.batch.ids == order, "Relaunch must preserve the exact order")
        #expect(resumed.batch.cursor == 2, "Relaunch must preserve progress")
        #expect(resumed.batch.currentID == order[2], "Relaunch must show the same next photo")
        #expect(resumed.ledger.pendingIDs == [order[1]], "Deletion pool must survive relaunch")
        #expect(resumed.ledger[order[1]].pendingSince == Date(timeIntervalSince1970: 2), "The time a photo was queued must survive")
        resumed.undo()
        #expect(resumed.batch.currentID == order[1], "Undo history must survive relaunch")
        #expect(resumed.ledger.pendingIDs.isEmpty, "Undo must remove the restored photo from the pool")
        #expect(!resumed.ledger.journal.isEmpty, "Undo must journal the record it changed")
    }

    @Test func keepDeleteAndUndo() {
        var state = state()
        let first = state.batch.ids[0]
        let second = state.batch.ids[1]
        state.advance(delete: false)
        #expect(state.ledger.seenIDs == [first], "Horizontal swipes must mark a photo as seen")
        #expect(state.ledger.pendingIDs.isEmpty, "Horizontal swipes must not queue deletion")
        state.advance(delete: true)
        #expect(state.ledger.seenIDs == [first, second], "Downward swipes must mark a photo as seen")
        #expect(state.ledger.pendingIDs == [second], "Downward swipes must queue deletion")
        state.undo()
        #expect(state.batch.currentID == second && state.ledger.seenIDs == [first], "Undo must restore the previous card and seen state")
        state.undo()
        #expect(state.batch.currentID == first && state.ledger.seenIDs.isEmpty, "Repeated undo must restore the start")
        #expect(state.ledger.records.isEmpty, "A record undone to blank must leave the ledger")
        #expect(!state.batch.canUndo, "Undo should stop at the start of the batch")
        #expect(state.undo() == nil && state.batch.cursor == 0, "Extra undo must be harmless")
    }

    @Test func completeAndContinue() {
        var state = state()
        let firstBatch = Set(state.batch.ids)
        for _ in 0..<15 { state.advance(delete: false) }
        #expect(state.batch.isComplete && state.batch.currentID == nil, "The final swipe must complete the batch")
        state.fit(availableIDs: assets)
        #expect(state.batch.isComplete, "Library refresh must not advance a completed batch")
        state.undo()
        #expect(!state.batch.isComplete && state.batch.cursor == 14, "Undo must work after the final swipe")
        state.advance(delete: false)
        state.startNextBatch(availableIDs: assets)
        #expect(Set(state.batch.ids).isDisjoint(with: firstBatch), "New batches must exclude seen photos while unseen ones remain")
        #expect(!state.batch.canUndo, "Undo history must not cross batch boundaries")
        for _ in 0..<15 { state.advance(delete: false) }
        state.startNextBatch(availableIDs: assets)
        #expect(state.batch.ids.count == 10, "The last first-round batch should use the remaining photos")
        for _ in 0..<10 { state.advance(delete: true) }
        state.startNextBatch(availableIDs: assets)
        #expect(state.batch.ids.count == 15 && Set(state.batch.ids).isDisjoint(with: state.ledger.pendingIDs),
                "Once every photo is seen, the next batch comes from the seen photos, never the pool")
        state.fit(availableIDs: assets + ["new-photo"])
        state.startNextBatch(availableIDs: assets + ["new-photo"])
        #expect(state.batch.ids == ["new-photo"], "Newly added photos come first, before any second look")
    }

    @Test func secondRoundStartsFromOldest() {
        var state = ReviewState()
        var generator = SeededGenerator(state: 7)
        let photos = (1...20).map { "photo-\($0)" }
        for (index, id) in photos.enumerated() {
            state.ledger.markSeen(id, at: Date(timeIntervalSince1970: Double(index) * day))
        }
        state.startNextBatch(availableIDs: photos.shuffled(), using: &generator)
        #expect(Set(state.batch.ids) == Set(photos.prefix(15)), "A second round must pick the photos seen longest ago")
        #expect(state.batch.ids != Array(photos.prefix(15)), "Within the pick, the order is shuffled")
        state.ledger.setPending("photo-1", true, at: .now)
        state.startNextBatch(availableIDs: photos, using: &generator)
        #expect(!state.batch.ids.contains("photo-1") && state.batch.ids.contains("photo-16"), "Queued photos make room for the next oldest")
    }

    @Test func permissionChanges() {
        var state = state()
        let order = state.batch.ids
        state.advance(delete: true)
        state.advance(delete: false)
        let available = assets.filter { $0 != order[0] && $0 != order[3] }
        state.fit(availableIDs: available)
        #expect(state.batch.cursor == 1, "Removing an earlier card must adjust progress")
        #expect(state.batch.currentID == order[2], "Library changes must preserve the current card when possible")
        #expect(!state.batch.ids.contains(order[3]), "Unavailable future cards must be removed")
        #expect(state.ledger.pendingIDs.contains(order[0]), "Fitting must not erase deletion intent")
        #expect(state.ledger.seenIDs.contains(order[0]), "Fitting must not erase viewed history")
        state.undo()
        #expect(state.batch.currentID == order[1], "Undo should still work after a library change")
        #expect(!state.batch.canUndo, "Unavailable undo entries must be removed")
    }

    @Test func pendingRestoration() throws {
        var state = state()
        let id = try #require(state.batch.currentID)
        state.advance(delete: true)
        #expect(state.restoreFromPool(id) != nil, "Restoring a queued photo is a change")
        #expect(state.restoreFromPool(id) == nil, "Restoring a photo not in the pool is not")
        #expect(state.ledger.pendingIDs.isEmpty, "Restoring from the pool must cancel deletion")
        #expect(state.ledger.seenIDs.contains(id), "Restoring from the pool must preserve viewed history")
        state.undo()
        #expect(state.batch.currentID == id && state.ledger.pendingIDs.isEmpty, "Undo after pool restoration must remain consistent")
    }

    @Test func edgeCases() {
        var state = state(available: [])
        #expect(!state.batch.isComplete && !state.batch.canUndo && state.batch.currentID == nil, "An empty library is not a completed batch")
        #expect(state.advance(delete: true) == nil, "Swiping an empty batch must be harmless")
        #expect(state.ledger.records.isEmpty, "Swiping an empty batch must not write records")
        state.fit(availableIDs: ["only"])
        state.advance(delete: true)
        #expect(state.advance(delete: true) == nil, "Extra advances must not corrupt a completed batch")
        #expect(state.batch.cursor == 1 && state.ledger.pendingIDs == ["only"], "The single photo stays queued")
        #expect(state.ledger.nextBatch(from: assets, count: -1).isEmpty, "A negative batch size must not crash")
    }

    @Test func journalTracksChanges() {
        var ledger = ReviewLedger()
        ledger.markSeen("a", at: .now)
        ledger.markSeen("b", at: .now)
        ledger.setPending("b", true, at: .now)
        var journal = ledger.takeJournal()
        #expect(journal.upserted == ["a", "b"] && journal.removed.isEmpty, "New records are journaled as upserts")
        #expect(ledger.journal.isEmpty, "Taking the journal empties it")
        ledger.forget(["a"])
        ledger.restore(PhotoRecord(id: "b"))
        journal = ledger.takeJournal()
        #expect(journal.removed == ["a", "b"] && journal.upserted.isEmpty, "Forgotten and blanked records are journaled as removals")
        ledger.markSeen("c", at: .now)
        ledger.forget(["c"])
        let forgotten = ledger.takeJournal()
        #expect(forgotten.upserted.isEmpty && forgotten.removed == ["c"], "A record added then forgotten is only a removal")
        #expect(forgotten.before["c"] == PhotoRecord(id: "c"), "What the record was before its first change is kept: nothing")

        var merged = ReviewLedger.Journal(upserted: ["x"], removed: ["y"])
        merged.merge(ReviewLedger.Journal(upserted: ["y"], removed: ["x"]))
        #expect(merged == ReviewLedger.Journal(upserted: ["y"], removed: ["x"]), "Merging keeps the later fate of each record")
    }

    @Test func relinkFollowsPhotos() {
        var ledger = ReviewLedger(records: [
            PhotoRecord(id: "old", cloudID: "cloud-1", seenAt: .now, pendingSince: .now),
            PhotoRecord(id: "kept", seenAt: .now),
        ])
        #expect(ledger.ids(missingFrom: ["kept"]) == ["old"], "Records whose photo is gone are reported missing")
        ledger.relink("old", to: "new")
        #expect(ledger.records["old"] == nil && ledger.records["new"]?.cloudID == "cloud-1", "Relinking moves the record to the new identifier")
        #expect(ledger.pendingIDs == ["new"] && ledger.seenIDs == ["new", "kept"], "Indexes follow the relinked record")
        let relinked = ledger.takeJournal()
        #expect(relinked.upserted == ["new"] && relinked.removed == ["old"], "Relinking journals a removal and an upsert")
        ledger.relink("new", to: "new")
        #expect(ledger.journal.isEmpty, "Relinking to the same identifier changes nothing")
    }

    @Test func swipeDirectionsSurviveRelaunch() throws {
        var state = state()
        let first = state.batch.ids[0]
        let second = state.batch.ids[1]
        state.advance(delete: false, direction: .left)
        state.advance(delete: true, direction: .down)
        var resumed = try JSONDecoder().decode(ReviewBatch.self, from: JSONEncoder().encode(state.batch))
        #expect(resumed.undoTarget?.id == second && resumed.undoTarget?.direction == .down,
                "The way a photo left must survive relaunch for undo")
        _ = resumed.undo()
        #expect(resumed.undoTarget?.id == first && resumed.undoTarget?.direction == .left,
                "Each step keeps its own direction")
    }

    @Test func chosenFirstPhoto() throws {
        var state = ReviewState()
        state.startNextBatch(availableIDs: assets, first: "photo-7")
        #expect(state.batch.ids.first == "photo-7" && state.batch.ids.count == 15, "The chosen photo leads a new batch")
        #expect(Set(state.batch.ids).count == 15, "The chosen photo is not repeated in its batch")
        state.advance(delete: false)
        let reviewed = Array(state.batch.ids.prefix(state.batch.cursor + 1))
        state.refillRemaining(availableIDs: assets, order: .newest, count: 15)
        #expect(Array(state.batch.ids.prefix(reviewed.count)) == reviewed, "A new order leaves what came before, and the current photo, alone")
        let rest = Array(state.batch.ids.dropFirst(reviewed.count))
        #expect(rest == Array(assets.filter { !reviewed.contains($0) }.prefix(13)), "Newest first: the newest photos there are, the batch filled to its size")
        state.refillRemaining(availableIDs: assets, order: .oldest, count: 15)
        #expect(Array(state.batch.ids.dropFirst(reviewed.count)) == Array(assets.reversed().filter { !reviewed.contains($0) }.prefix(13)), "Oldest first: the oldest")
        state.startNextBatch(availableIDs: assets, first: "not-there")
        #expect(!state.batch.ids.contains("not-there") && state.batch.ids.count == 15, "A chosen photo the library lacks is ignored")
    }

    @Test func batchResizes() {
        var state = state()
        state.advance(delete: false)
        state.advance(delete: false)
        let before = state.batch.ids
        state.resizeBatch(to: 20, availableIDs: assets, order: .random)
        #expect(state.batch.ids.count == 20 && Array(state.batch.ids.prefix(15)) == before, "A larger size adds photos after the ones already there")
        #expect(Set(state.batch.ids).count == 20, "Added photos do not repeat any in the batch")
        #expect(state.batch.cursor == 2, "Resizing keeps the position")
        state.resizeBatch(to: 15, availableIDs: assets, order: .random)
        #expect(state.batch.ids.count == 3 && state.batch.currentID == before[2], "A smaller size ends the batch at the current photo")
        state.advance(delete: false)
        #expect(state.batch.isComplete, "After that the current photo was the last")
        state.resizeBatch(to: 2, availableIDs: assets, order: .random)
        #expect(state.batch.ids.count == 3 && state.batch.isComplete, "A finished batch is left alone when shrunk")
        state.resizeBatch(to: 10, availableIDs: assets, order: .random)
        #expect(state.batch.ids.count == 10 && !state.batch.isComplete && state.batch.cursor == 3, "A finished batch goes on when grown")
    }

    @Test func progressResets() {
        var state = state()
        let seen = state.batch.ids[0]
        let queued = state.batch.ids[1]
        state.advance(delete: false)
        state.advance(delete: true)
        _ = state.ledger.takeJournal()
        state.ledger.forgetSeen()
        #expect(state.ledger.seenIDs == [queued], "Resetting clears every seen mark but the pool's, which stays seen")
        #expect(state.ledger.pendingIDs == [queued], "Resetting keeps the deletion pool")
        let journal = state.ledger.takeJournal()
        #expect(journal.removed.contains(seen), "A record with nothing left in it is forgotten")
        #expect(!journal.upserted.contains(queued) && !journal.removed.contains(queued), "The pool's record is left as it is")
    }

    @Test func batchDecodingRejectsCorruptPositions() {
        let bad = Data(#"{"ids":["a","b"],"cursor":5,"steps":[]}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ReviewBatch.self, from: bad) }
        let duplicate = Data(#"{"ids":["a","a"],"cursor":0,"steps":[]}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ReviewBatch.self, from: duplicate) }
        let staleStep = Data(#"{"ids":["a","b"],"cursor":1,"steps":[{"id":"b","previous":{"id":"b"},"direction":"left"}]}"#.utf8)
        let batch = try? JSONDecoder().decode(ReviewBatch.self, from: staleStep)
        #expect(batch?.steps.isEmpty == true, "Steps for photos not yet reviewed are dropped on decoding")
    }
}
