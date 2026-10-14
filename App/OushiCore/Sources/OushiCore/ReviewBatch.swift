// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import Foundation

/// The batch on screen: its photos in order, the position, and the steps taken through it, each with the photo's
/// record from before the step so undo can put it back. Short-lived and small; saved whole.
public struct ReviewBatch: Codable, Equatable, Sendable {
    public private(set) var ids: [String] = []
    public private(set) var cursor = 0
    public private(set) var steps: [Step] = []

    public struct Step: Codable, Equatable, Sendable {
        public let id: String
        /// The photo's record before this step.
        public var previous: PhotoRecord
        public let direction: SwipeDirection?
        /// The photo's record as this step left it (nil for steps saved before this was kept): undo puts the
        /// record back only while it is still this, not once another device's earlier move has replaced it.
        public var produced: PhotoRecord?

        public init(id: String, previous: PhotoRecord, direction: SwipeDirection?, produced: PhotoRecord? = nil) {
            self.id = id
            self.previous = previous
            self.direction = direction
            self.produced = produced
        }
    }

    public init() {}

    public init(ids: [String]) {
        self.ids = ids
    }

    public var currentID: String? {
        guard ids.indices.contains(cursor) else { return nil }
        return ids[cursor]
    }

    public var isComplete: Bool {
        !ids.isEmpty && cursor >= ids.count
    }

    public var canUndo: Bool { !steps.isEmpty }

    /// The photo `undo()` would bring back, and the way it left (nil for steps saved before directions were).
    public var undoTarget: (id: String, direction: SwipeDirection?)? {
        steps.last.map { ($0.id, $0.direction) }
    }

    /// Moves past the current photo. `step.id` must be the current photo.
    public mutating func advance(_ step: Step) {
        guard step.id == currentID else { return }
        steps.append(step)
        cursor += 1
    }

    /// Steps back to the last photo swiped and returns that step, or nil when there is none.
    public mutating func undo() -> Step? {
        guard let step = steps.popLast(), let index = ids.firstIndex(of: step.id) else { return nil }
        cursor = index
        return step
    }

    /// Adds photos to the end of the batch, skipping any it already has.
    public mutating func append(_ newIDs: [String]) {
        let present = Set(ids)
        ids += newIDs.filter { !present.contains($0) }
    }

    /// Ends the batch at the current photo: whatever was still to come is dropped.
    public mutating func endAfterCurrent() {
        guard !isComplete, !ids.isEmpty else { return }
        ids = Array(ids.prefix(cursor + 1))
    }

    /// Replaces the photos still to come, after the current one, with `newIDs` (less any already in the batch).
    /// What has been reviewed, and the current photo, stay as they are.
    public mutating func replaceRemaining(with newIDs: [String]) {
        guard currentID != nil else { return }
        let kept = Array(ids.prefix(cursor + 1))
        let present = Set(kept)
        ids = kept + newIDs.filter { !present.contains($0) }
    }

    /// Drops photos that are no longer available, keeping the position on the same photo.
    public mutating func fit(to available: Set<String>) {
        let reviewed = ids.prefix(cursor).filter { available.contains($0) }
        cursor = reviewed.count
        ids.removeAll { !available.contains($0) }
        let retained = Set(reviewed)
        steps.removeAll { !retained.contains($0.id) }
    }

    /// Takes photos out of what is still to come, the current one included: seen on another device meanwhile,
    /// they are not shown here. The position stays, so the next photo comes up in the place of one taken out.
    /// Returns whether anything was taken out.
    @discardableResult
    public mutating func dropUpcoming(_ dropped: Set<String>) -> Bool {
        guard !dropped.isEmpty, cursor < ids.count else { return false }
        let kept = ids[cursor...].filter { !dropped.contains($0) }
        guard kept.count != ids.count - cursor else { return false }
        ids = Array(ids.prefix(cursor)) + kept
        return true
    }

    /// A photo taken out of the deletion pool by hand must not be put back by an older undo.
    public mutating func forgetPendingState(of id: String) {
        for index in steps.indices where steps[index].id == id {
            steps[index].previous.pendingSince = nil
            steps[index].produced?.pendingSince = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case ids, cursor, steps
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        ids = try values.decode([String].self, forKey: .ids)
        cursor = try values.decode(Int.self, forKey: .cursor)
        steps = try values.decodeIfPresent([Step].self, forKey: .steps) ?? []
        guard cursor >= 0, cursor <= ids.count, Set(ids).count == ids.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .ids,
                in: values,
                debugDescription: "Invalid batch or cursor."
            )
        }
        let reviewed = Set(ids.prefix(cursor))
        steps.removeAll { !reviewed.contains($0.id) }
    }
}
