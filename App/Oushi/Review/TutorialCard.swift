// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import SwiftUI

/// The three cards shown before the first review, each in the place of a photo: swipe sideways to go on, pull down
/// to queue for deletion, and the buttons around the deck. Plain system cards, each with one line and a footnote.
struct TutorialCard: View {
    let lesson: Lesson
    /// Size of the area the deck lays cards out in.
    let bounds: CGSize

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
        case .swipeSideways:
            Text("左滑或右滑以查看下一张")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
        case .pullDown:
            Text("向下拉，放进待删除")
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
        case .swipeSideways: String(localized: "往左或往右滑")
        case .pullDown: String(localized: "往下拉")
        case .buttons: String(localized: "随意划走，开始使用")
        }
    }
}
