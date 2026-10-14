// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import Foundation
import Observation
import OushiCore

/// The user's settings, kept in UserDefaults under typed keys. Observable, so the views that show a setting
/// redraw when it changes.
@MainActor
@Observable
final class AppSettings: OnboardingStore {
    private enum Key: String {
        case hapticsEnabled, photoHDR, videoHDR, iCloudSync, batchSize, reviewOrder, onboarding
        /// Earlier builds kept the lessons' progress in two values; read once and folded into `onboarding`.
        case hasFinishedTutorial, tutorialProgress
    }

    /// A soft tap when a downward pull comes free, and again when it re-holds.
    var hapticsEnabled: Bool {
        didSet { defaults.set(hapticsEnabled, forKey: Key.hapticsEnabled.rawValue) }
    }

    /// Photos with a gain map shown in high dynamic range; off, as standard images.
    var photoHDR: Bool {
        didSet { defaults.set(photoHDR, forKey: Key.photoHDR.rawValue) }
    }

    /// HDR videos played as such; off, tone-mapped down to standard range.
    var videoHDR: Bool {
        didSet { defaults.set(videoHDR, forKey: Key.videoHDR.rawValue) }
    }

    /// How many photos and videos a batch holds: one of `ReviewSession.batchSizes`, or `unlimitedBatchSize`.
    var batchSize: Int {
        didSet { defaults.set(batchSize, forKey: Key.batchSize.rawValue) }
    }

    /// The order photos and videos come up in.
    var order: ReviewOrder {
        didSet { defaults.set(order.rawValue, forKey: Key.reviewOrder.rawValue) }
    }

    /// The ledger of what was seen and queued follows the user to their other devices through iCloud.
    var iCloudSync: Bool {
        didSet { defaults.set(iCloudSync, forKey: Key.iCloudSync.rawValue) }
    }

    /// How far the lessons before the first review have got.
    var onboarding: OnboardingProgress {
        didSet { defaults.set(onboarding.stored, forKey: Key.onboarding.rawValue) }
    }

    #if DEBUG
    /// Debug builds: the review screen shown in one of its end states, for checking them without a library in
    /// that state. Not saved; a relaunch leaves it.
    var stateTest: StateTest?
    #endif

    /// The end states the review screen can be shown in on demand (debug builds; the type exists in every build
    /// so the screen's code does not).
    enum StateTest: String, CaseIterable, Identifiable {
        case emptyLibrary, batchDone, everythingSeenWithPool, everythingSeenEmptyPool

        var id: String { rawValue }

        /// Debug-only wording, shown as is.
        var title: String {
            switch self {
            case .emptyLibrary: "空相册"
            case .batchDone: "这一组看完了"
            case .everythingSeenWithPool: "所有内容都看过了（有待删除）"
            case .everythingSeenEmptyPool: "所有内容都看过了（无待删除）"
            }
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hapticsEnabled = defaults.object(forKey: Key.hapticsEnabled.rawValue) as? Bool ?? true
        photoHDR = defaults.object(forKey: Key.photoHDR.rawValue) as? Bool ?? true
        videoHDR = defaults.object(forKey: Key.videoHDR.rawValue) as? Bool ?? true
        let savedSize = defaults.integer(forKey: Key.batchSize.rawValue)
        batchSize = ReviewSession.batchSizes.contains(savedSize) || savedSize == ReviewSession.unlimitedBatchSize ? savedSize : ReviewState.batchSize
        order = ReviewOrder(rawValue: defaults.string(forKey: Key.reviewOrder.rawValue) ?? "") ?? .random
        iCloudSync = defaults.bool(forKey: Key.iCloudSync.rawValue)
        if let stored = defaults.string(forKey: Key.onboarding.rawValue), let progress = OnboardingProgress(stored: stored) {
            onboarding = progress
        } else {
            // The earlier keys, read once: written under the new key now, so a build without this reading keeps it.
            if defaults.bool(forKey: Key.hasFinishedTutorial.rawValue) {
                onboarding = .finished
            } else {
                let step = defaults.integer(forKey: Key.tutorialProgress.rawValue)
                onboarding = step >= Lesson.count ? .welcome : .lesson(Lesson(rawValue: max(step, 0)) ?? .swipeSideways)
            }
            defaults.set(onboarding.stored, forKey: Key.onboarding.rawValue)
            defaults.removeObject(forKey: Key.hasFinishedTutorial.rawValue)
            defaults.removeObject(forKey: Key.tutorialProgress.rawValue)
        }
    }
}

extension OnboardingProgress {
    /// The progress as one stored string.
    var stored: String {
        switch self {
        case .lesson(let lesson): "lesson:\(lesson.rawValue)"
        case .welcome: "welcome"
        case .finished: "finished"
        }
    }

    init?(stored: String) {
        switch stored {
        case "welcome": self = .welcome
        case "finished": self = .finished
        default:
            guard stored.hasPrefix("lesson:"), let raw = Int(stored.dropFirst(7)), let lesson = Lesson(rawValue: raw) else { return nil }
            self = .lesson(lesson)
        }
    }
}
