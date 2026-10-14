// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import SwiftUI

/// The words in the middle of the navigation bar, in a fixed box, each kind at its own fixed spot and only ever
/// faded in or out: a photo's date on the upper line with its time below; the sentence for the end of a batch on
/// the middle line; the pool's name on the middle line, giving way to how many are selected while any are; the
/// app's name during the lessons.
///
/// Nothing is laid out from its neighbors and no text ever changes into another kind's words, so no line moves
/// or flickers when the card on top changes. The photo lines keep the last photo's date while they fade, so the
/// last card's words go out as themselves.
struct ReviewTitleBar: View {
    enum Mode: Equatable {
        case photo, summary, pool, tutorial
    }

    let mode: Mode
    /// The current photo's date; nil with no photo on top.
    let photoDate: Date?
    /// Shown when there is a photo but no date for it.
    let isVideo: Bool
    /// For the end-of-batch sentence.
    let seenCount: Int
    /// Photos selected in the pool; while any are, the count stands in for the pool's name.
    let selectedCount: Int
    /// The app is leaving the foreground: the photo's date and time go with the photo, so the app switcher's
    /// snapshot says nothing about it. The other lines name no photo and stay.
    let isCovered: Bool

    /// The last date shown, kept so the photo lines fade out with their own words.
    @State private var shownDate: Date?

    private let width: CGFloat = 220
    private let height: CGFloat = 44

    var body: some View {
        ZStack {
            Text(dateLine)
                .font(.headline)
                .position(x: width / 2, y: 13)
                .opacity(mode == .photo && !isCovered ? 1 : 0)
            Text(timeLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .position(x: width / 2, y: 32)
                .opacity(mode == .photo && !isCovered ? 1 : 0)
            Text("您已查看 \(seenCount) 个内容")
                .font(.headline)
                .monospacedDigit()
                // Longer languages shrink a little rather than cut off.
                .minimumScaleFactor(0.75)
                .frame(width: width - 8)
                .position(x: width / 2, y: height / 2)
                .opacity(mode == .summary ? 1 : 0)
            Text("检查媒体")
                .font(.headline)
                .minimumScaleFactor(0.75)
                .frame(width: width - 8)
                .position(x: width / 2, y: height / 2)
                .opacity(mode == .pool && selectedCount == 0 ? 1 : 0)
            Text("已选择 \(selectedCount) 项")
                .font(.headline)
                .monospacedDigit()
                .minimumScaleFactor(0.75)
                .frame(width: width - 8)
                .contentTransition(.numericText(value: Double(selectedCount)))
                .position(x: width / 2, y: height / 2)
                .opacity(mode == .pool && selectedCount > 0 ? 1 : 0)
            Text("偶拾")
                .font(.headline)
                .position(x: width / 2, y: height / 2)
                .opacity(mode == .tutorial ? 1 : 0)
        }
        .frame(width: width, height: height)
        .lineLimit(1)
        // The box is fixed; the largest type sizes would not fit two lines in it.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .animation(.smooth(duration: 0.3), value: mode)
        .animation(.smooth(duration: 0.3), value: selectedCount)
        .animation(.smooth(duration: 0.3), value: isCovered)
        .onChange(of: photoDate, initial: true) { _, date in
            if let date { shownDate = date }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// The date to show: the current photo's, or none for a photo without one; the last one only while fading out.
    private var dateShown: Date? {
        mode == .photo ? photoDate : shownDate
    }

    private var dateLine: String {
        if let dateShown { return dateShown.formatted(.dateTime.year().month().day()) }
        return isVideo ? String(localized: "视频") : String(localized: "照片")
    }

    private var timeLine: String {
        dateShown?.formatted(date: .omitted, time: .shortened) ?? " "
    }

    private var accessibilityText: String {
        switch mode {
        case .photo: "\(dateLine) \(timeLine)"
        case .summary: String(localized: "您已查看 \(seenCount) 个内容")
        case .pool: selectedCount > 0 ? String(localized: "已选择 \(selectedCount) 项") : String(localized: "检查媒体")
        case .tutorial: String(localized: "偶拾")
        }
    }
}
