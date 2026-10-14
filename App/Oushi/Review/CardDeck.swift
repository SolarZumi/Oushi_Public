// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import Observation
import OushiCore
import SwiftUI

/// The card stack's state and behavior, apart from any view.
///
/// The top card follows the finger along one axis; sideways flings keep a photo, downward ones queue it for
/// deletion. On release the batch advances at once and the card leaves on its own animation, so the next card
/// can be swiped straight away and every card finishes its own motion. Undo brings a card back from the side it
/// left (saved with the history, so this survives relaunches); the card it covers shrinks and fades into the
/// next card's place on the same animation.
///
/// The deck shows whatever its phase calls for: the access card while the library cannot be read, the lessons and
/// the welcome while `OnboardingFlow` runs them, the batch's photos otherwise. The arithmetic of a swipe is
/// `SwipePhysics`; the lessons' meaning is the flow's; this moves the cards.
///
/// State that changes every frame of a drag lives here, so only the views that read it (the deck, the progress
/// capsule, the background) redraw while dragging.
@MainActor
@Observable
final class CardDeck {
    /// Size of the area the cards are laid out in, and the system's Reduce Motion; set by the deck view.
    var size: CGSize = .zero
    var reduceMotion = false
    /// The library can be read; otherwise the access card sits on top alone. Access arriving while a lesson is
    /// on top lets the lesson show its gesture.
    var hasLibraryAccess = true {
        didSet {
            guard hasLibraryAccess != oldValue else { return }
            if hasLibraryAccess, let lesson = phase.lesson { scheduleDemo(for: lesson) } else { stopDemo() }
        }
    }
    /// The deck is on screen, and not under the pool or the settings: a lesson's demo runs only then (the library
    /// may take seconds to read at launch, and a demo run behind the spinner would be over before the card is
    /// seen), and starts afresh once the deck is seen again.
    var isPresented = false {
        didSet {
            guard isPresented != oldValue else { return }
            if isPresented, let lesson = phase.lesson { scheduleDemo(for: lesson) } else { stopDemo() }
        }
    }

    /// Offset of the top card under the finger. Always along a single axis.
    private(set) var dragOffset: CGSize = .zero
    /// A finger is moving the top card.
    private(set) var isFollowingFinger = false
    /// The top card has been pulled down far enough to delete: it now follows the finger, and letting go deletes.
    /// Before that a downward pull only gives a little, as if the card were held in place.
    private(set) var isDeleteArmed = false
    /// Every card hides what it shows under the card color: the app is leaving or out of the foreground (the app
    /// switcher shows a snapshot). Read by the cards through the `cardsCovered` environment value.
    private(set) var isCovered = false
    /// Cards swiped away and still animating off screen, oldest first. Each runs its own animation.
    private(set) var flyingCards: [FlyingCard] = []
    /// Cards undo is bringing back from off screen, and the side each comes in from. Read by the insertion
    /// transition, so set before the undo itself.
    private(set) var returning: [DeckItem: ReturnRecord] = [:]
    /// Something just happened that calls for a haptic, or a shake: a pull arming or re-holding, a lesson passed
    /// or refused. A new value each time.
    private(set) var feedback: DeckFeedback?
    /// A lesson's card is showing its gesture by itself: its movement is not progress.
    private(set) var isDemonstrating = false

    let onboarding: OnboardingFlow
    @ObservationIgnored private let review: ReviewSession
    /// Where the drag stands: nothing, a finger moving the card along one axis, or a gesture something else
    /// (undo) took over, whose remaining events are ignored until the finger lifts.
    @ObservationIgnored private var drag: DragPhase = .idle
    /// Where the card stood when a finger took it over from the demo, and when: the drag carries on from there,
    /// the first moments on a spring so the card glides from where it was drawn to where the finger has it.
    @ObservationIgnored private var takeover: (offset: CGSize, pull: CGFloat, since: Date)?
    @ObservationIgnored private var demoTask: Task<Void, Never>?
    @ObservationIgnored private var phaseWatch: Task<Void, Never>?
    /// Bumped by each cover, so an uncover waiting its moment does not lift a cover put on since.
    @ObservationIgnored private var coverGeneration = 0

    private enum DragPhase {
        case idle
        case tracking(Axis)
        case interrupted
    }

    init(review: ReviewSession, onboarding: OnboardingFlow) {
        self.review = review
        self.onboarding = onboarding
        // A lesson coming on top (at launch, after a pass, an undo, or 重新查看教程) shows its gesture by itself.
        phaseWatch = Task { [weak self] in
            let lessons = Observations<Lesson??, Never> { [weak self] in
                guard let self else { return nil }
                return .some(self.onboarding.currentLesson)
            }
            for await lesson in lessons {
                guard let lesson, let self else { return }
                self.lessonChanged(to: lesson)
            }
        }
    }

    // MARK: What is on top

    var phase: DeckPhase {
        guard hasLibraryAccess else { return .needsAccess }
        switch onboarding.phase {
        case .lesson(let lesson): return .lesson(lesson)
        case .welcome(let stage): return .welcome(stage)
        case .finished: return .reviewing
        }
    }

    private var batch: ReviewBatch { review.batch }

    /// The photo on top; nil while a system card (access, a lesson) or the welcome is on top, so the bars that
    /// act on a photo stand down.
    var currentID: String? { phase.hidesPhotos ? nil : batch.currentID }

    /// What is on top to drag: the access card, a lesson, or a photo; nothing during the welcome or after the
    /// batch's last photo.
    var topItem: DeckItem? {
        switch phase {
        case .needsAccess: .access
        case .lesson(let lesson): .lesson(lesson)
        case .welcome: nil
        case .reviewing: batch.currentID.map(DeckItem.photo)
        }
    }

    /// The system card on top, if any: the access card or a lesson. The heart may be tapped on these for show.
    var systemCardID: String? {
        switch topItem {
        case .access, .lesson: topItem?.id
        default: nil
        }
    }

    var nextID: String? {
        guard currentID != nil, batch.ids.indices.contains(batch.cursor + 1) else { return nil }
        return batch.ids[batch.cursor + 1]
    }

    /// The two photos after the current one, worth decoding ahead of time.
    var upcomingIDs: [String] {
        guard currentID != nil else { return [] }
        return Array(batch.ids.dropFirst(batch.cursor + 1).prefix(2))
    }

    /// Undo has something to bring back: a lesson, or a photo.
    var canUndo: Bool {
        switch phase {
        case .needsAccess, .welcome: false
        case .lesson: onboarding.canUndo
        case .reviewing: batch.canUndo
        }
    }

    // MARK: Layout

    /// Bottom to top: the next card, the current card, then cards flying away (newest last). Keyed by item so a
    /// card keeps its view, and its loaded image, as it moves between roles. Under the last photo the summary
    /// waits and comes up like any next card; under each lesson waits the next, under the last lesson nothing.
    var cards: [DeckCard] {
        let flying = flyingCards.map { DeckCard(item: $0.item, role: .flying($0)) }
        let flyingItems = Set(flyingCards.map(\.item))
        var result: [DeckCard] = []
        switch phase {
        case .needsAccess:
            return [DeckCard(item: .access, role: .top)]
        case .welcome:
            // Only the last lesson's card, on its way out.
            return flying
        case .lesson(let lesson):
            if let next = lesson.next, !flyingItems.contains(.lesson(next)) { result.append(DeckCard(item: .lesson(next), role: .next)) }
            if !flyingItems.contains(.lesson(lesson)) { result.append(DeckCard(item: .lesson(lesson), role: .top)) }
        case .reviewing:
            if let current = batch.currentID {
                if let next = nextID {
                    if !flyingItems.contains(.photo(next)) { result.append(DeckCard(item: .photo(next), role: .next)) }
                } else {
                    result.append(DeckCard(item: .summary, role: .next))
                }
                if !flyingItems.contains(.photo(current)) { result.append(DeckCard(item: .photo(current), role: .top)) }
            } else if batch.isComplete {
                result.append(DeckCard(item: .summary, role: .top))
            }
        }
        return result + flying
    }

    func style(for role: DeckCard.Role) -> CardStyle {
        switch role {
        case .next:
            return CardStyle(offset: .zero, scale: SwipePhysics.nextCardScale + (1 - SwipePhysics.nextCardScale) * progress, opacity: progress)
        case .top:
            return CardStyle(offset: dragOffset, scale: 1, opacity: 1)
        case .flying(let card):
            let fades = card.direction == .down || reduceMotion
            return CardStyle(
                offset: card.offset,
                scale: card.direction == .down && !reduceMotion ? SwipePhysics.nextCardScale : 1,
                opacity: fades ? 0 : 1
            )
        }
    }

    /// A card undo brings back from off screen comes in from the side it left; any other new card, like the first
    /// of a new batch, grows in the way a next card comes up. Cards leave by fading, though by then they are
    /// either off screen or covered.
    func insertionTransition(for item: DeckItem) -> AnyTransition {
        guard let record = returning[item], let direction = record.direction, !reduceMotion else {
            return .asymmetric(insertion: .scale(scale: SwipePhysics.nextCardScale).combined(with: .opacity), removal: .opacity)
        }
        let move = AnyTransition.offset(SwipePhysics.exitOffset(direction, in: size))
        let insertion = direction == .down
            ? move.combined(with: .scale(scale: SwipePhysics.nextCardScale)).combined(with: .opacity)
            : move
        return .asymmetric(insertion: insertion, removal: .opacity)
    }

    /// 0...1, how far the top card has moved toward leaving, measured against the distance a fling sends it.
    /// Brings the next card up, so it is fully up exactly when the current one reaches its exit position.
    var progress: Double { SwipePhysics.progress(of: dragOffset, in: size) }

    /// Undo is bringing the card now on top back up from the deletion pool. Only the top card counts: undone
    /// again at once, a card returned from the side takes the top, and the green for the one before it ends with
    /// that, rather than lingering until its spring has settled.
    var isReturningFromBottom: Bool {
        guard let top = topItem else { return false }
        return returning[top]?.direction == .down
    }

    /// Photos in the batch not yet swiped past, the current one included.
    var remainingCount: Int { max(batch.ids.count - batch.cursor, 0) }

    /// The top photo's number in the batch, counted from one.
    var positionInBatch: Int { min(batch.cursor + 1, batch.ids.count) }

    /// Photos done plus how far the top one has moved out, as a share of the batch.
    var batchProgress: Double {
        guard !batch.ids.isEmpty else { return 0 }
        let moving = currentID == nil ? 0 : progress
        return min((Double(batch.cursor) + moving) / Double(batch.ids.count), 1)
    }

    /// What the progress capsule fills to: the batch's progress, or, while the lessons are on, theirs: lessons
    /// passed plus how far the one on top has moved, out of the three.
    var shownProgress: Double {
        switch phase {
        case .welcome: return 1
        case .lesson(let lesson):
            // The lessons are a batch of three, read like any batch: cards passed plus how far the one on top has
            // moved. Only the demo's own movement does not count. (Not "only while a finger drives": the finger
            // lifts a moment before the fling advances the lesson, and the fill would dip in between.)
            let moving = isDemonstrating ? 0 : progress
            return min((Double(lesson.rawValue) + moving) / Double(Lesson.count), 1)
        case .needsAccess, .reviewing: return batchProgress
        }
    }

    private var armDistance: CGFloat { SwipePhysics.armDistance(in: size) }

    // MARK: Dragging

    // The drag arrives as a pan recognizer reports one: a beginning, with the travel that carried the finger past
    // the threshold (the axis is read from it, as the first movement's direction); then translations measured
    // from that beginning, so the card starts from rest rather than jumping the threshold's distance; then an
    // end with the finger's velocity, or a cancellation when the system takes the touch away.

    func dragBegan(travel: CGSize) {
        // Not under the pool, which keeps its card-sized hit area while it shrinks back over the deck: a drag
        // beside it would move the hidden card on top.
        guard topItem != nil, isPresented, case .idle = drag else { return }
        let axis: Axis = abs(travel.width) >= abs(travel.height) ? .horizontal : .vertical
        if isDemonstrating {
            // Taking over from the demo: the drag counts from where the card is. A pull keeps the demo's arming;
            // a sideways drag drops it.
            stopDemo(disarming: axis == .horizontal, settling: false)
            takeover = (dragOffset, SwipePhysics.takeoverPull(offset: dragOffset, armed: isDeleteArmed, armDistance: armDistance), .now)
        } else {
            // A demo still waiting to start is simply called off.
            stopDemo()
            takeover = nil
        }
        drag = .tracking(axis)
        isFollowingFinger = true
    }

    func dragChanged(translation: CGSize) {
        guard case .tracking(let axis) = drag else { return }
        switch axis {
        case .horizontal:
            let offset = CGSize(width: (takeover?.offset.width ?? 0) + translation.width, height: 0)
            if let takeover, Date.now.timeIntervalSince(takeover.since) < 0.25 {
                withAnimation(Motion.catchUp) { dragOffset = offset }
            } else {
                dragOffset = offset
            }
        case .vertical:
            pullDown(by: (takeover?.pull ?? 0) + translation.height)
        }
    }

    func dragEnded(velocity: CGSize) {
        guard case .tracking(let axis) = drag else {
            drag = .idle
            return
        }
        let armed = isDeleteArmed
        endDrag()
        switch axis {
        case .horizontal:
            if let fling = SwipePhysics.sidewaysFling(offset: dragOffset.width, velocity: velocity.width, width: size.width) {
                self.fling(fling.direction, speed: fling.speed)
            } else {
                settle()
            }
        case .vertical:
            if armed {
                fling(.down, speed: max(0, velocity.height))
            } else {
                settle()
            }
        }
    }

    /// The system took the touch away (an incoming call, a system gesture): the card goes back.
    func dragCancelled() {
        guard case .tracking = drag else {
            drag = .idle
            return
        }
        endDrag()
        settle()
    }

    /// The card holds its place against a pull, giving only a little, until the pull reaches the arming distance;
    /// then it comes free and follows the finger, catching up to where the finger is on a quick spring. Letting
    /// the pull back well above the arming distance re-holds it.
    private func pullDown(by pull: CGFloat) {
        setArmed(SwipePhysics.isArmed(after: pull, wasArmed: isDeleteArmed, armDistance: armDistance))
        // An interactive spring so the moment it comes free is a quick catch-up, not a jump.
        withAnimation(Motion.catchUp) {
            dragOffset = CGSize(width: 0, height: SwipePhysics.pullOffset(pull, armed: isDeleteArmed))
        }
    }

    private func setArmed(_ armed: Bool) {
        guard armed != isDeleteArmed else { return }
        isDeleteArmed = armed
        feedback = DeckFeedback(kind: armed ? .armed : .disarmed)
    }

    private func endDrag() {
        drag = .idle
        isFollowingFinger = false
        isDeleteArmed = false
        takeover = nil
    }

    private func settle() {
        withAnimation(Motion.settle) { dragOffset = .zero }
    }

    #if targetEnvironment(simulator)
    /// Holds the top card where a finger would have it, without any animation, for screenshots.
    func hold(offset: CGSize, armed: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            dragOffset = offset
            isDeleteArmed = armed
            isFollowingFinger = true
        }
    }

    var holdDistance: CGFloat { armDistance }
    #endif

    // MARK: Actions

    /// Sends the top card off screen on its own animation and makes the next card interactive right away.
    /// `speed` is the finger's speed in points per second along the fling, so the card leaves at that speed.
    func fling(_ direction: SwipeDirection, speed: CGFloat) {
        stopDemo()
        switch phase {
        case .needsAccess:
            // Nowhere to go without the library: the card comes back.
            settle()
        case .lesson(let lesson):
            flingLesson(lesson, direction: direction, speed: speed)
        case .welcome:
            break
        case .reviewing:
            // The photo under the finger is gone (deleted elsewhere, or dropped from the batch by a change from
            // iCloud): nothing to fling, and the next card must not inherit the offset.
            guard let id = currentID else {
                settle()
                return
            }
            let card = FlyingCard(item: .photo(id), direction: direction, offset: flightTarget(direction))
            var advanced = false
            withAnimation(flightAnimation(to: card.offset, direction: direction, speed: speed), completionCriteria: .logicallyComplete) {
                advanced = review.advance(delete: direction == .down, direction: direction)
                if advanced {
                    flyingCards.append(card)
                    dragOffset = .zero
                }
            } completion: { [weak self] in
                self?.flyingCards.removeAll { $0.token == card.token }
            }
            if !advanced { settle() }
        }
    }

    /// A lesson's card leaves only the way the lesson teaches; the wrong way, it snaps back to be tried again.
    private func flingLesson(_ lesson: Lesson, direction: SwipeDirection, speed: CGFloat) {
        guard lesson.allows(direction) else {
            // Refused: straight back, not the easy return of a card let go, so the refusal is felt.
            withAnimation(reduceMotion ? Motion.settle : Motion.refuse) { dragOffset = .zero }
            onboarding.refuse()
            if let mark = onboarding.mark { feedback = DeckFeedback(kind: .lessonRefused(mark)) }
            return
        }
        let card = FlyingCard(item: .lesson(lesson), direction: direction, offset: flightTarget(direction))
        withAnimation(flightAnimation(to: card.offset, direction: direction, speed: speed), completionCriteria: .logicallyComplete) {
            flyingCards.append(card)
            dragOffset = .zero
            // The flow moves on in the same update as the card's flight: moved earlier, the deck would have
            // dropped the card before it was flying, and it would have vanished instead of leaving.
            onboarding.pass(lesson, direction: direction)
        } completion: { [weak self] in
            self?.flyingCards.removeAll { $0.token == card.token }
        }
        if lesson.next != nil { feedback = DeckFeedback(kind: .lessonPassed) }
    }

    private func flightTarget(_ direction: SwipeDirection) -> CGSize {
        reduceMotion ? dragOffset : SwipePhysics.exitOffset(direction, in: size)
    }

    private func flightAnimation(to target: CGSize, direction: SwipeDirection, speed: CGFloat) -> Animation {
        guard !reduceMotion else { return Motion.reducedFling }
        let distance = direction == .down ? abs(target.height - dragOffset.height) : abs(target.width - dragOffset.width)
        return Motion.fling(relativeVelocity: SwipePhysics.relativeVelocity(speed: speed, distance: distance))
    }

    /// 开始使用 on the welcome.
    func beginUse() {
        onboarding.beginUse()
    }

    /// Brings the last card back from the side it left. A card still flying turns around mid-flight; one already
    /// off screen comes in through `insertionTransition`. Takes over a drag in progress: the dragged card leaves
    /// the finger and eases from where it was into the next card's place.
    func undo() {
        stopDemo()
        let wasDragging: Bool
        if case .tracking = drag { wasDragging = true } else { wasDragging = false }
        endDrag()
        if wasDragging { drag = .interrupted }
        switch phase {
        case .needsAccess, .welcome:
            // Nothing to undo after all: a card taken from under a finger still goes back to its place.
            if wasDragging { settle() }
        case .lesson:
            guard let target = onboarding.undoTarget else {
                if wasDragging { settle() }
                return
            }
            if !bringBack(.lesson(target.lesson), from: target.direction, change: { onboarding.undo() != nil }), wasDragging { settle() }
        case .reviewing:
            guard let target = batch.undoTarget else {
                if wasDragging { settle() }
                return
            }
            if !bringBack(.photo(target.id), from: target.direction, change: { review.undo() }), wasDragging { settle() }
        }
    }

    /// Animates `item` back into the deck from `direction`, with `change` (which must make the deck show it, and
    /// says whether it did) inside the same animation. Returns whether anything came back.
    @discardableResult
    private func bringBack(_ item: DeckItem, from direction: SwipeDirection?, change: () -> Bool) -> Bool {
        let token = UUID()
        returning[item] = ReturnRecord(direction: direction, token: token)
        var changed = false
        withAnimation(Motion.undo) {
            changed = change()
            if changed {
                flyingCards.removeAll { $0.item == item }
                dragOffset = .zero
            }
        } completion: { [weak self] in
            if self?.returning[item]?.token == token { self?.returning[item] = nil }
        }
        if !changed { returning[item] = nil }
        return changed
    }

    func startNextBatch() {
        withAnimation(Motion.cardChange) {
            review.startNextBatch()
        }
    }

    /// In the background: in-flight cards are dropped, so nothing resumes mid-air on return.
    func reset() {
        stopDemo(settling: false)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            onboarding.settleForBackground()
            flyingCards.removeAll()
            returning.removeAll()
            dragOffset = .zero
            endDrag()
        }
    }

    // MARK: Cover

    /// Leaving the foreground (the swipe toward the app switcher begins): every card's content dissolves into blur
    /// under the app's dark card color, so the switcher's snapshot shows plain cards.
    func cover(animated: Bool = true) {
        coverGeneration += 1
        guard !isCovered else { return }
        if animated {
            withAnimation(Motion.cover) { isCovered = true }
        } else {
            // Already in the background: the snapshot is about to be taken, so the cover is on at once.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { isCovered = true }
        }
    }

    /// Back in the foreground: the cards come back into focus. The animation starts only after the first frame
    /// has been drawn again: started on the way back from the background, it would run out while the screen is
    /// not yet updating and the content would simply be there.
    func uncover() {
        guard isCovered else { return }
        let generation = coverGeneration
        Task { [weak self] in
            await FrameClock.nextFrame()
            guard let self, self.isCovered, self.coverGeneration == generation else { return }
            withAnimation(Motion.uncover) { self.isCovered = false }
            // The demo stopped on leaving; the lesson shows its gesture again.
            if let lesson = self.phase.lesson { self.scheduleDemo(for: lesson) }
        }
    }

    // MARK: Lesson demos

    private func lessonChanged(to lesson: Lesson?) {
        stopDemo()
        if let lesson { scheduleDemo(for: lesson) }
    }

    /// A lesson's card, once it is up, shows its gesture by itself: the first slides a little to one side (chosen
    /// at random), then to the other, then back; the second pulls down until the pull arms, then lets go. A
    /// finger on the deck ends the demo at once.
    private func scheduleDemo(for lesson: Lesson) {
        stopDemo()
        guard lesson.hasDemo, !reduceMotion, hasLibraryAccess, isPresented else { return }
        demoTask = Task { [weak self] in
            try? await Task.sleep(for: LessonDemo.lead)
            guard let self, !Task.isCancelled else { return }
            guard self.phase.lesson == lesson, !self.reduceMotion, case .idle = self.drag else {
                self.demoTask = nil
                return
            }
            self.isDemonstrating = true
            for step in LessonDemo.steps(for: lesson, armDistance: self.armDistance) {
                if let armed = step.armed { self.setArmed(armed) }
                withAnimation(step.animation) { self.dragOffset = step.offset }
                try? await Task.sleep(for: step.hold)
                // Cancelled (a finger, undo, leaving): whoever cancelled has put the deck right, and the handle is
                // theirs. Otherwise still the same card, no finger, or the demo gives the card back itself.
                guard !Task.isCancelled else { return }
                guard self.phase.lesson == lesson, !self.reduceMotion, case .idle = self.drag else {
                    self.isDemonstrating = false
                    self.demoTask = nil
                    self.setArmed(false)
                    self.settle()
                    return
                }
            }
            if !Task.isCancelled {
                self.isDemonstrating = false
                self.demoTask = nil
            }
        }
    }

    /// Ends a demo waiting to start or under way. A demo stopped mid-move puts the card back, unless a finger
    /// has taken it over or the caller puts the deck right itself.
    private func stopDemo(disarming: Bool = true, settling: Bool = true) {
        guard demoTask != nil else { return }
        demoTask?.cancel()
        demoTask = nil
        let wasMoving = isDemonstrating
        isDemonstrating = false
        if disarming, isDeleteArmed { isDeleteArmed = false }
        if settling, wasMoving, dragOffset != .zero { settle() }
    }
}

/// The scripted gestures of the lessons' cards: each a few moves, held for a moment each.
enum LessonDemo {
    struct Step {
        let offset: CGSize
        let animation: Animation
        let hold: Duration
        /// Arms or re-holds the pull before the move, with its haptic, as a finger's pull would.
        var armed: Bool? = nil
    }

    /// How long after the card comes up the demo starts.
    static let lead: Duration = .milliseconds(900)

    static func steps(for lesson: Lesson, armDistance: CGFloat) -> [Step] {
        switch lesson {
        case .swipeSideways:
            let side: CGFloat = Bool.random() ? 1 : -1
            return [
                Step(offset: CGSize(width: side * 72, height: 0), animation: Motion.demoSlide, hold: .milliseconds(600)),
                Step(offset: CGSize(width: -side * 72, height: 0), animation: Motion.demoSlide, hold: .milliseconds(600)),
                Step(offset: .zero, animation: Motion.demoReturn, hold: .zero),
            ]
        case .pullDown:
            // Held first, as under a finger, then free and armed, then let go.
            return [
                Step(offset: CGSize(width: 0, height: armDistance * SwipePhysics.heldGive), animation: Motion.demoHold, hold: .milliseconds(400)),
                Step(offset: CGSize(width: 0, height: armDistance + 24), animation: Motion.demoReturn, hold: .milliseconds(800), armed: true),
                Step(offset: .zero, animation: Motion.demoReturn, hold: .zero, armed: false),
            ]
        case .buttons:
            return []
        }
    }
}

/// Something the deck did that the view answers with a haptic or a shake.
struct DeckFeedback: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// A downward pull came free of its place, or re-held.
        case armed, disarmed
        case lessonPassed
        case lessonRefused(LessonMark)
    }

    let kind: Kind
    let id = UUID()
}

struct ReturnRecord {
    let direction: SwipeDirection?
    let token: UUID
}

struct FlyingCard: Equatable {
    let item: DeckItem
    let direction: SwipeDirection
    let offset: CGSize
    let token = UUID()
}

struct DeckCard: Identifiable {
    enum Role: Equatable {
        case next, top
        case flying(FlyingCard)
    }

    let item: DeckItem
    let role: Role
    var id: String { item.id }
}

struct CardStyle {
    let offset: CGSize
    let scale: CGFloat
    let opacity: Double
}
