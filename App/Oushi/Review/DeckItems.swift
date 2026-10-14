// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import OushiCore

/// The three lessons before the first review, in order: swipe sideways, pull down, the buttons around the deck.
enum Lesson: Int, CaseIterable, Hashable, Codable, Sendable {
    case swipeSideways, pullDown, buttons

    static let count = allCases.count

    var next: Lesson? { Lesson(rawValue: rawValue + 1) }
    var previous: Lesson? { Lesson(rawValue: rawValue - 1) }

    /// A lesson's card leaves only the way the lesson teaches: sideways for the first, down for the second, any
    /// way for the last.
    func allows(_ direction: SwipeDirection) -> Bool {
        switch self {
        case .swipeSideways: direction != .down
        case .pullDown: direction == .down
        case .buttons: true
        }
    }

    /// The first two lessons show their gesture by themselves until a finger takes over.
    var hasDemo: Bool { self != .buttons }
}

/// How far the lessons have got, kept across launches.
enum OnboardingProgress: Equatable, Sendable {
    case lesson(Lesson)
    /// The lessons are done; the welcome waits for 开始使用.
    case welcome
    case finished
}

/// What a card in the deck shows: a photo from the batch, a lesson, the access card, or the end-of-batch summary.
enum DeckItem: Hashable, Identifiable, Sendable {
    case photo(String)
    case lesson(Lesson)
    case access
    case summary

    /// A stable identity for SwiftUI, so a card keeps its view (and a photo its loaded image) across roles.
    var id: String {
        switch self {
        case .photo(let photoID): "photo:\(photoID)"
        case .lesson(let lesson): "lesson:\(lesson.rawValue)"
        case .access: "access"
        case .summary: "summary"
        }
    }

    var photoID: String? {
        if case .photo(let id) = self { return id }
        return nil
    }

    var lesson: Lesson? {
        if case .lesson(let lesson) = self { return lesson }
        return nil
    }
}

/// The deck's mode: what sits on top and what the bars around it offer.
enum DeckPhase: Equatable, Sendable {
    /// The library cannot be read: the access card sits on top alone and cannot be swiped away.
    case needsAccess
    case lesson(Lesson)
    /// The last lesson has been swiped away: a word of welcome has the deck to itself before the first photo.
    case welcome(WelcomeStage)
    case reviewing

    enum WelcomeStage: Equatable, Sendable {
        /// The last lesson's card is still leaving; the words come into focus after it.
        case arriving
        case shown
        /// 开始使用 was tapped: the words go out of focus, then the first photo comes up.
        case leaving
    }

    var lesson: Lesson? {
        if case .lesson(let lesson) = self { return lesson }
        return nil
    }

    var isLesson: Bool { lesson != nil }

    var isWelcome: Bool {
        if case .welcome = self { return true }
        return false
    }

    var isWelcomeShown: Bool { self == .welcome(.shown) }

    /// A system card (the access card, a lesson) or the welcome is on top: the bars that act on a photo stand down.
    var hidesPhotos: Bool { self != .reviewing }
}
