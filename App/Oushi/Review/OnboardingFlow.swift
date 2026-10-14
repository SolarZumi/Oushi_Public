// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import Observation
import OushiCore
import SwiftUI

/// Where the lessons are kept between launches.
@MainActor
protocol OnboardingStore: AnyObject {
    var onboarding: OnboardingProgress { get set }
}

/// A lesson's outcome, for the capsule's check or cross and the haptic. A new value each time, so a second
/// outcome of the same kind is a new event.
struct LessonMark: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case passed
        /// Refused, with which way the card's shake first jerks (chance, as a real shake's is).
        case refused(firstJerk: CGFloat)
    }

    let kind: Kind
    let id = UUID()
}

/// The lessons before the first review and the welcome after them: which is on, what has been passed (and may
/// be undone), and how far that is, kept in the store across launches. The deck shows the lesson's card and reports
/// the gestures; this decides what they mean.
@MainActor
@Observable
final class OnboardingFlow {
    enum Phase: Equatable, Sendable {
        case lesson(Lesson)
        case welcome(DeckPhase.WelcomeStage)
        case finished
    }

    private(set) var phase: Phase
    /// The last outcome, for the moment it is shown.
    private(set) var mark: LessonMark?
    /// The outcome the progress capsule has drawn: kept here, not in the capsule, because the capsule leaves the
    /// bar while the pool is open and is built anew when it returns, which must not draw the mark again.
    @ObservationIgnored var shownMarkID: UUID?
    /// The way each lesson's card left, so undo can bring the previous lesson back from that side. Not kept
    /// across launches.
    private(set) var history: [SwipeDirection] = []

    @ObservationIgnored private let store: any OnboardingStore
    @ObservationIgnored private var arrival: Task<Void, Never>?

    /// Over `store`, starting where it says, or at `progress` when given (the simulator's screenshot poses skip
    /// the lessons without writing that into the store).
    init(store: any OnboardingStore, startingAt progress: OnboardingProgress? = nil) {
        self.store = store
        switch progress ?? store.onboarding {
        case .lesson(let lesson): phase = .lesson(lesson)
        case .welcome: phase = .welcome(.arriving)
        case .finished: phase = .finished
        }
        if case .welcome = phase { arrive() }
    }

    var currentLesson: Lesson? {
        if case .lesson(let lesson) = phase { return lesson }
        return nil
    }

    var isActive: Bool { phase != .finished }

    var isWelcoming: Bool {
        if case .welcome = phase { return true }
        return false
    }

    var isWelcomeShown: Bool { phase == .welcome(.shown) }

    var canUndo: Bool { currentLesson != nil && !history.isEmpty }

    /// The lesson undo would bring back, and the way its card left, without bringing it back yet.
    var undoTarget: (lesson: Lesson, direction: SwipeDirection)? {
        guard let lesson = currentLesson, let previous = lesson.previous, let direction = history.last else { return nil }
        return (previous, direction)
    }

    /// 重新查看教程: the lessons come back from the first.
    func restart() {
        history = []
        mark = nil
        phase = .lesson(.swipeSideways)
        store.onboarding = .lesson(.swipeSideways)
    }

    /// The right gesture on a lesson's card: on to the next lesson, or, after the last, to the welcome. The
    /// welcome's words come into focus a moment later, after the card has left.
    func pass(_ lesson: Lesson, direction: SwipeDirection) {
        history.append(direction)
        if let next = lesson.next {
            mark = LessonMark(kind: .passed)
            phase = .lesson(next)
            store.onboarding = .lesson(next)
        } else {
            phase = .welcome(.arriving)
            store.onboarding = .welcome
            arrive()
        }
    }

    /// The wrong gesture: the card is refused and shakes its head.
    func refuse() {
        mark = LessonMark(kind: .refused(firstJerk: Bool.random() ? 1 : -1))
    }

    /// Brings the previous lesson back; returns it, and the way its card left, or nil when there is none.
    func undo() -> (lesson: Lesson, direction: SwipeDirection)? {
        guard let lesson = currentLesson, let previous = lesson.previous, let direction = history.popLast() else { return nil }
        phase = .lesson(previous)
        store.onboarding = .lesson(previous)
        return (previous, direction)
    }

    /// 开始使用: the welcome goes out of focus, and once it has, the first photo comes up. The lessons count as
    /// finished from the tap, so a relaunch during the fade goes straight to the photos.
    func beginUse() {
        guard phase == .welcome(.shown) else { return }
        store.onboarding = .finished
        arrival?.cancel()
        withAnimation(Motion.welcomeFade, completionCriteria: .logicallyComplete) {
            phase = .welcome(.leaving)
        } completion: { [weak self] in
            guard let self, self.phase == .welcome(.leaving) else { return }
            withAnimation(Motion.welcomeEnd) { self.phase = .finished }
        }
    }

    /// In the background: a welcome still waiting for 开始使用 is shown at once on return; one already on its way
    /// out is simply over.
    func settleForBackground() {
        arrival?.cancel()
        switch phase {
        case .welcome(.arriving): phase = .welcome(.shown)
        case .welcome(.leaving): phase = .finished
        default: break
        }
    }

    /// The words come into focus a moment after the last card has gone, whether that card is leaving now or the
    /// app was relaunched on the welcome.
    private func arrive() {
        arrival?.cancel()
        arrival = Task { [weak self] in
            try? await Task.sleep(for: Motion.welcomeDelay)
            guard let self, !Task.isCancelled, self.phase == .welcome(.arriving) else { return }
            withAnimation(Motion.welcomeFade) { self.phase = .welcome(.shown) }
        }
    }
}
