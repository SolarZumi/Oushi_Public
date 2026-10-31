// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import OushiCore
import SwiftUI

/// The three cards shown before the first review, each in the place of a photo: the swipe that goes on, the pull
/// that queues for deletion (each the ways the user has set), and the buttons around the deck. Plain system cards,
/// each with one line and a footnote.
struct TutorialCard: View {
    let lesson: Lesson
    /// Size of the area the deck lays cards out in.
    let bounds: CGSize

    @Environment(AppSettings.self) private var settings

    var body: some View {
        let compact = CardShape.isCompact(bounds)
        SystemCard(bounds: bounds) {
            VStack(spacing: compact ? 10 : 20) {
                Spacer(minLength: 0)
                content
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                Text(footnote)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var content: some View {
        switch lesson {
        case .keep:
            Text(GestureWords.line(for: .keep, settings.gestures))
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
        case .queue:
            Text(GestureWords.line(for: .queue, settings.gestures))
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
        case .buttons:
            VStack(alignment: .leading, spacing: CardShape.isCompact(bounds) ? 10 : 18) {
                Text("\(Image(systemName: "photo.stack")) 查看待删除照片")
                Text("\(Image(systemName: "heart")) 收藏照片")
                Text("\(Image(systemName: "arrow.uturn.backward")) 撤回操作")
                Text("\(Image(systemName: "gearshape")) 更多设置…")
            }
            .font(.title3.weight(.semibold))
        }
    }

    private var footnote: String {
        switch lesson {
        case .keep: GestureWords.footnote(for: .keep, settings.gestures)
        case .queue: GestureWords.footnote(for: .queue, settings.gestures)
        case .buttons: String(localized: "随意划走，开始使用")
        }
    }
}

/// What to say about the deck's gestures as the user has set them: the line a lesson teaches one by, and its
/// footnote. A swipe goes on (滑); a pull, which holds before it comes free, queues for deletion (拉).
enum GestureWords {
    static func line(for action: SwipeAction, _ gestures: SwipeGestures) -> String {
        switch (action, gestures.isSideways(action)) {
        case (.keep, true):
            switch gestures.sideways {
            case .left: String(localized: "左滑以查看下一张")
            case .either: String(localized: "左滑或右滑以查看下一张")
            case .right: String(localized: "右滑以查看下一张")
            }
        case (.keep, false):
            switch gestures.upDown {
            case .down: String(localized: "下滑以查看下一张")
            case .either: String(localized: "上滑或下滑以查看下一张")
            case .up: String(localized: "上滑以查看下一张")
            }
        case (.queue, true):
            switch gestures.sideways {
            case .left: String(localized: "向左拉，放进待删除")
            case .either: String(localized: "向左或向右拉，放进待删除")
            case .right: String(localized: "向右拉，放进待删除")
            }
        case (.queue, false):
            switch gestures.upDown {
            case .down: String(localized: "向下拉，放进待删除")
            case .either: String(localized: "向上或向下拉，放进待删除")
            case .up: String(localized: "向上拉，放进待删除")
            }
        }
    }

    static func footnote(for action: SwipeAction, _ gestures: SwipeGestures) -> String {
        switch (action, gestures.isSideways(action)) {
        case (.keep, true):
            switch gestures.sideways {
            case .left: String(localized: "往左滑")
            case .either: String(localized: "往左或往右滑")
            case .right: String(localized: "往右滑")
            }
        case (.keep, false):
            switch gestures.upDown {
            case .down: String(localized: "往下滑")
            case .either: String(localized: "往上或往下滑")
            case .up: String(localized: "往上滑")
            }
        case (.queue, true):
            switch gestures.sideways {
            case .left: String(localized: "往左拉")
            case .either: String(localized: "往左或往右拉")
            case .right: String(localized: "往右拉")
            }
        case (.queue, false):
            switch gestures.upDown {
            case .down: String(localized: "往下拉")
            case .either: String(localized: "往上或往下拉")
            case .up: String(localized: "往上拉")
            }
        }
    }

    /// For a photo card's VoiceOver hint: both lines, one after the other.
    static func hint(_ gestures: SwipeGestures) -> String {
        line(for: .keep, gestures) + "\n" + line(for: .queue, gestures)
    }
}
