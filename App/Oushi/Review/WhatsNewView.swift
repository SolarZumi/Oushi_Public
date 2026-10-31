// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import SwiftUI

/// What a release brings, shown once to someone who used the app before it, the way Apple's own apps greet an
/// update. A new user learns the app from the lessons instead and never sees it (`AppSettings`).
enum WhatsNew {
    /// The release these notes are for. The page shows once per value: an update that leaves it as it is shows
    /// nothing; one that changes it (with new features below) shows the page once more to everyone past the lessons.
    static let release = "1.0.1"

    struct Feature: Identifiable {
        let symbol: String
        let title: LocalizedStringResource
        let detail: LocalizedStringResource
        var id: String { symbol }
    }

    static let features = [
        Feature(
            symbol: "hand.draw",
            title: "自定义手势",
            detail: "在设置中自定义跳过和删除的滑动方向。"
        ),
        Feature(
            symbol: "livephoto",
            title: "实况照片",
            detail: "长按即可播放实况照片，也可以在设置中开启自动播放。"
        ),
    ]
}

/// The release's notes as Apple's apps show theirs: a large title, each feature with its symbol, a line and a
/// sentence, and 继续 at the bottom. Dismissing it, by the button or by pulling the sheet down, counts as seen.
struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss

    /// Kept to a readable measure on a wide screen.
    private let maxWidth: CGFloat = 520

    var body: some View {
        ScrollView {
            VStack(spacing: 44) {
                Text("偶拾的新功能")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                VStack(alignment: .leading, spacing: 28) {
                    ForEach(WhatsNew.features) { feature in
                        FeatureRow(feature: feature)
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 72)
            .padding(.bottom, 24)
            .frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            Button { dismiss() } label: {
                Text("继续")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .modifier(GlassPillButton())
            .controlSize(.large)
            .padding(.horizontal, 32)
            .padding(.bottom, 20)
            .frame(maxWidth: maxWidth)
        }
        .preferredColorScheme(.dark)
    }
}

/// One feature: its symbol in the app icon's yellow, the feature's name, and a sentence on it.
private struct FeatureRow: View {
    let feature: WhatsNew.Feature

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: feature.symbol)
                .font(.title)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.yellow)
                .frame(width: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(feature.title)
                    .font(.headline)
                Text(feature.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
