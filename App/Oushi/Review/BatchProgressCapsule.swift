// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import SwiftUI

/// The batch's progress as a fill from left to right, like Control Center's volume slider turned sideways: a plain
/// rectangle from the left edge, clipped to the capsule, with how many photos are left written over it. When the
/// batch is done the words fade to 再来一组 (or 重置浏览进度) and the capsule is the button that acts on them.
///
/// A plain button that draws its own glass, the size the bar would give it (5 points out from the item's
/// content at the sides and 1 above and below): the capsule reports the inner size and draws the outer one, so
/// it stands in the bar exactly like the buttons beside it, with the fill reaching the glass's own edge. Its
/// glass is its own rather than the bar's so that the bar does not morph it out of its neighbors (ReviewScreen).
///
/// The fill tracks the top card exactly while a finger drives it. Otherwise it runs its own spring rather than
/// borrowing the fling's or undo's animation: those end in a long tail (a flung card is already off screen while its
/// spring finishes) and restart on every undo, so the fill fell behind fast swipes and repeated undos.
struct BatchProgressCapsule: View {
    /// What the capsule offers once the batch is done.
    enum Completion {
        /// Photos remain that are not in the pool: 再来一组.
        case nextBatch
        /// Everything has been seen: 重置浏览进度, which asks before resetting.
        case startOver
        /// Everything left is in the pool: nothing to offer.
        case nothing
        /// The welcome after the lessons: 开始使用.
        case begin
    }

    let deck: CardDeck
    /// Where the capsule's glass is reported to, for the welcome's halo.
    let layout: ReviewLayout
    /// nil while the batch is under way (or a photo-less card stands in); else what the capsule offers.
    let completion: Completion?
    /// Where the batch stands, in words, for assistive technology.
    let progress: String
    /// The batch has no end but the library's: no fill, and the count of the photo on top in place of what is left.
    let isUnlimited: Bool
    let startNextBatch: () -> Void
    let startOver: () -> Void

    @State private var fill = SpringValue(settleTime: 0.25)
    /// The check or cross for a passed or refused lesson, and the words: the words leave as the symbol draws on,
    /// and come back only once the symbol has drawn off, one after the other rather than over each other.
    @State private var shownMark: LessonMark?
    @State private var showsWords = true
    /// The symbol is drawing off: driven as an effect on the symbol while it stays in place, since a removal
    /// transition was not seen to animate, and only then is it taken out and the words brought back.
    @State private var isMarkLeaving = false

    /// The glass as the bar draws it around this item, and how far it stands out from the item's own frame
    /// (measured on the simulator: 5 points at the sides, 1 above and below). Drawn no bigger than that: a fill
    /// standing a point short of the glass's edge is lost in the rim's highlight, one standing a point past it
    /// is a white line outside the glass.
    static let width: CGFloat = 168
    static let height: CGFloat = 46
    static let glassInset = (horizontal: CGFloat(5), vertical: CGFloat(1))
    private let size = CGSize(width: width, height: height)
    /// How long a lesson's check or cross stays before drawing off, and how long the drawing off takes before
    /// the words come back.
    private static let markHold: Duration = .seconds(1.2)
    private static let markDrawOff: Duration = .milliseconds(650)

    private var text: String {
        switch deck.phase {
        case .needsAccess: return String(localized: "偶拾")
        case .lesson: return String(localized: "教程")
        case .welcome, .reviewing: break
        }
        switch completion {
        case .nextBatch: return String(localized: "再来一组")
        case .startOver: return String(localized: "重置浏览进度")
        case .nothing: return String(localized: "没有可翻的了")
        case .begin: return String(localized: "开始使用")
        case nil: break
        }
        if isUnlimited { return String(deck.positionInBatch) }
        return String(localized: "还剩 \(deck.remainingCount) 个")
    }

    private var isEnabled: Bool {
        switch completion {
        case .nextBatch, .startOver: true
        case .begin: deck.phase.isWelcomeShown
        case .nothing, nil: false
        }
    }

    /// The batch's standing, read out only while a photo batch is what the capsule shows.
    private var spokenProgress: String {
        completion == nil && deck.phase == .reviewing ? progress : ""
    }

    private func act() {
        switch completion {
        case .nextBatch: startNextBatch()
        case .startOver: startOver()
        case .begin: deck.beginUse()
        case .nothing, nil: break
        }
    }

    var body: some View {
        let target = completion == nil ? deck.shownProgress : 1
        // Always the spring's value: under a finger it is set straight to the target, except across a gap too big
        // for a finger's step, which it glides over.
        let shown = fill.value
        // An unlimited batch has no fill to show; the lessons, the welcome and the end of a batch still do.
        let showsFill = !isUnlimited || completion != nil || deck.phase.isLesson || deck.phase.isWelcome
        let fillWidth = showsFill ? size.width * min(max(shown, 0), 1) : 0
        let label = ZStack {
            if showsWords {
                Text(text)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    // Longer languages shrink a little rather than wrap inside the capsule.
                    .minimumScaleFactor(0.7)
                    .contentTransition(.opacity)
                    .transition(.opacity)
            }
            if let shownMark {
                Image(systemName: shownMark.kind == .passed ? "checkmark" : "xmark")
                    .font(.subheadline.weight(.bold))
                    .modifier(DrawingOff(isActive: isMarkLeaving))
                    .modifier(DrawnOn())
                    .id(shownMark.id)
            }
        }
        .padding(.horizontal, 14)
        .frame(width: size.width, height: size.height)
        .animation(.smooth(duration: 0.25), value: showsWords)
        .animation(.default, value: shownMark)
        Button(action: act) {
            // White words on the glass, black where the fill has reached: the same text twice, the dark copy cut
            // to the fill.
            label.foregroundStyle(.white)
                .overlay {
                    label.foregroundStyle(.black.opacity(0.8))
                        .mask(alignment: .leading) { Rectangle().frame(width: fillWidth) }
                }
                .background(alignment: .leading) {
                    Rectangle()
                        .fill(.white.opacity(0.85))
                        .frame(width: fillWidth)
                }
                // Its own glass, the bar's size (see ReviewScreen's toolbar for why it is not the bar's).
                .glassEffect(.regular.interactive(), in: .capsule)
                .clipShape(.capsule)
                .contentShape(.capsule)
                // Drawn at the glass's size, laid out at the content's: the bar adds the difference back.
                .frame(width: size.width - 2 * Self.glassInset.horizontal, height: size.height - 2 * Self.glassInset.vertical)
        }
        .buttonStyle(.plain)
        // Most of the time this is a gauge, not a button: with nothing to do it takes no touches, but it is not
        // dimmed as a disabled button would be, which read as broken and made the words hard to read.
        .allowsHitTesting(isEnabled)
        .accessibilityRemoveTraits(isEnabled ? [] : .isButton)
        .accessibilityRespondsToUserInteraction(isEnabled)
        .accessibilityLabel(text)
        .accessibilityValue(spokenProgress)
        .animation(.smooth(duration: 0.35), value: text)
        .onAppear { fill.jump(to: target) }
        // Where the capsule's glass is on screen (the content's frame plus the bar's margins), for the welcome's
        // halo to pulse out of.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            layout.capsuleFrame = frame.insetBy(dx: -Self.glassInset.horizontal, dy: -Self.glassInset.vertical)
        }
        // A lesson's outcome: the symbol draws on over the words, stays a moment, draws off, and only then do the
        // words come back. A new outcome meanwhile starts over with its own symbol.
        .task(id: deck.onboarding.mark) {
            guard let mark = deck.onboarding.mark, mark.id != deck.onboarding.shownMarkID else {
                // Nothing new to show (or a mark cut short before): the words stand.
                shownMark = nil
                isMarkLeaving = false
                showsWords = true
                return
            }
            deck.onboarding.shownMarkID = mark.id
            shownMark = mark
            isMarkLeaving = false
            showsWords = false
            try? await Task.sleep(for: Self.markHold)
            guard !Task.isCancelled else { return }
            isMarkLeaving = true
            try? await Task.sleep(for: Self.markDrawOff)
            guard !Task.isCancelled else { return }
            shownMark = nil
            isMarkLeaving = false
            showsWords = true
        }
        .onChange(of: target) { _, value in
            if deck.isFollowingFinger {
                fill.follow(value)
            } else {
                fill.animate(to: value)
            }
        }
        .onChange(of: deck.isFollowingFinger) { _, following in
            if !following { fill.animate(to: target) }
        }
    }
}

/// The system's draw-on transition for a symbol; the way out is `DrawingOff`, so the removal itself is plain.
private struct DrawnOn: ViewModifier {
    func body(content: Content) -> some View {
        content.transition(AsymmetricTransition(insertion: .symbolEffect(.drawOn), removal: .identity))
    }
}

/// The symbol drawing off in place.
private struct DrawingOff: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        content.symbolEffect(.drawOff, isActive: isActive)
    }
}
