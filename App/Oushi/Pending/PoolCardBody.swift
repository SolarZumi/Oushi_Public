// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import Photos
import SwiftUI

/// The two frames the pool card lives in: the card's size, and the screen it grows to with the bars' room
/// inside it. Everything the card draws is placed from these two, never from what it contains.
struct PoolGeometry: Equatable {
    var card: CGSize
    var screen: CGSize
    var insets: EdgeInsets

    /// The room between the bars, in the screen's coordinates.
    var contentRect: CGRect {
        CGRect(
            x: insets.leading,
            y: insets.top,
            width: max(screen.width - insets.leading - insets.trailing, 0),
            height: max(screen.height - insets.top - insets.bottom, 0)
        )
    }

    /// Where the grid lives once expanded: from under the top bar down to the bottom edge of the screen, running
    /// beneath the bottom bar, whose glass buttons sit over the photos; the grid scrolls its last row clear of them.
    var expandedGridRect: CGRect {
        CGRect(
            x: insets.leading,
            y: insets.top,
            width: max(screen.width - insets.leading - insets.trailing, 0),
            height: max(screen.height - insets.top, 0)
        )
    }
}

/// The deletion pool as one view with two layouts: the card at the end of a batch (four columns of the queued
/// photos, newest first, running down behind a glass pill reading 检查 x 项媒体) and the screen it grows into,
/// filling the whole screen with every photo in a selectable grid that starts under the top bar (which sits on
/// the card's own gray) and runs to the bottom edge, beneath the bottom bar's glass buttons. The bars belong to
/// `ReviewScreen`, whose buttons turn into the pool's (选择, 完成, 全部恢复, 全部删除) as the card grows.
///
/// Because both layouts are the same view, switching `isExpanded` inside an animation morphs one into the other:
/// the frame and corner radius, each photo's place and size, the pill dissolving as the grid takes the room. The
/// card's size and every photo's place are computed from `geometry` alone, so nothing here can grow with its
/// content. Once expanded, the system collection view takes over the grid, laid out by the same metrics: two
/// drawings of the grid, because the preview can morph and the collection view can select, and neither can do
/// the other's job.
struct PoolCardBody<Ghost: View>: View {
    let ids: [String]
    let geometry: PoolGeometry
    let isExpanded: Bool
    /// What the card shows while compact: the summary card's grid and pill, a photo, or a copy of a system card.
    let source: TopCard
    let isLimitedAccess: Bool
    /// The one side every pool photo is requested at: a cell of the expanded grid between the bars. The card asks
    /// for the same, so the pictures are cached before the card grows and no new size is requested while it does.
    let imageSide: CGFloat
    /// The system grid is in (fading in over the preview, which stays beneath it).
    let showsLiveGrid: Bool
    let actions: PoolActions
    /// The live grid's selection and scrolling; nil for the card in the deck, which has no live grid.
    let grid: PoolGridBindings?
    /// Grown out of a system card (a lesson, the access card, a notice): a copy of that card, drawn in the
    /// compact card and dissolving as it grows, so the card itself appears to grow, as a photo card does.
    @ViewBuilder let ghost: () -> Ghost

    @Environment(\.displayScale) private var displayScale

    /// The card's padding around its grid, and the room its pill takes at the bottom.
    static var inset: CGFloat { 16 }
    static var pillRoom: CGFloat { 80 }
    /// A system card's corners at the pool's growth: the device's own display corners the system does not declare,
    /// so a current iPhone's. The card at full size shows this radius for the one frame before the live grid
    /// takes over with square corners.
    static var screenCornerRadius: CGFloat { 55 }
    /// The blur that dissolves a photo, a ghost, the pill and the preview's lower rows.
    static var dissolveBlur: CGFloat { 24 }

    // MARK: Layout

    private var size: CGSize { isExpanded ? geometry.screen : geometry.card }

    /// Where the grid sits in the card's coordinates: inset in the card and running to its bottom edge; from under
    /// the top bar to the bottom edge on the screen.
    private var gridRect: CGRect {
        if isExpanded { return geometry.expandedGridRect }
        return CGRect(
            x: Self.inset, y: Self.inset,
            width: max(geometry.card.width - Self.inset * 2, 0),
            height: max(geometry.card.height - Self.inset, 0)
        )
    }

    private var metrics: PoolGridMetrics {
        PoolGridMetrics(width: gridRect.width, gap: isExpanded ? PoolGridMetrics.expandedGap : PoolGridMetrics.compactGap, scale: displayScale)
    }

    /// Rows enough for either layout, so none appear or vanish while the card grows: the extra ones lie beyond the
    /// card's edge until it does.
    private var shown: [String] {
        let compact = PoolGridMetrics(width: max(geometry.card.width - Self.inset * 2, 1), gap: PoolGridMetrics.compactGap)
        let expanded = PoolGridMetrics(width: max(geometry.expandedGridRect.width, 1), gap: PoolGridMetrics.expandedGap)
        let rows = max(
            compact.rows(toCover: geometry.card.height - Self.inset) + 1,
            expanded.rows(toCover: geometry.expandedGridRect.height) + 1
        )
        return Array(ids.prefix(rows * PoolGridMetrics.columns))
    }

    /// Grows toward the screen's own corner radius, so at full size the card sits flush with the device's corners;
    /// once the grid is live the corners go square, so nothing shows in a screenshot. Shrinking starts from the
    /// screen radius again, which at full size looks the same.
    private var cornerRadius: CGFloat {
        guard isExpanded else {
            if case .photo = source { return CardShape.photoCornerRadius }
            return CardShape.systemCornerRadius
        }
        return showsLiveGrid ? 0 : Self.screenCornerRadius
    }

    private var isFromSummary: Bool { source == .summary }

    var body: some View {
        CardFrame(size: size, cornerRadius: cornerRadius, showsEdge: !isExpanded) {
            ZStack(alignment: .topLeading) {
                preview
                if case .photo(let id) = source {
                    photo(id)
                }
                if source.isSystemCard {
                    ghostCard
                }
                if isExpanded {
                    if let grid { liveGrid(grid) }
                    if ids.isEmpty {
                        emptyNote
                    }
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .overlay(alignment: .bottom) { pill }
        }
    }

    // MARK: Preview

    /// The photos at their places for the current layout, cut to the grid's rectangle. In the card they run down
    /// behind the pill, dissolving into blur as they enter its zone and gone by the bottom edge.
    private var preview: some View {
        let rect = gridRect
        let metrics = metrics
        let shown = shown
        let fadeHeight: CGFloat = isExpanded ? 0 : Self.pillRoom
        let fadeTop = rect.height - fadeHeight
        // The rows that reach the pill's zone, drawn again blurred and shown only through that zone.
        let firstFading = shown.indices.first { metrics.frame(at: $0).maxY > fadeTop } ?? shown.count
        return ZStack(alignment: .topLeading) {
            cells(shown, metrics: metrics)
                .mask(alignment: .top) {
                    VStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: fadeHeight)
                    }
                }
            if !isExpanded, isFromSummary {
                // Sharp above the zone, soft within it, gone below.
                cells(Array(shown[firstFading...]), metrics: metrics, startingAt: firstFading)
                    .blur(radius: 14)
                    .mask(alignment: .top) {
                        VStack(spacing: 0) {
                            Color.clear
                            LinearGradient(colors: [.clear, .black.opacity(0.9), .clear], startPoint: .top, endPoint: .bottom)
                                .frame(height: fadeHeight)
                        }
                    }
                    .transition(.opacity)
            }
        }
        .frame(width: rect.width, height: rect.height, alignment: .topLeading)
        .clipped()
        .position(x: rect.midX, y: rect.midY)
        // Out of a photo the grid comes into focus as the photo dissolves; out of a system card it fades in.
        .blur(radius: isExpanded || isFromSummary ? 0 : Self.dissolveBlur)
        .opacity(isFromSummary || isExpanded ? 1 : 0)
        .allowsHitTesting(false)
    }

    /// The photo the pool grew out of, dissolving into blur as the card grows and focusing again as it returns. It
    /// stretches to fill whatever size the card has at the moment, cropped rather than letterboxed, so the ground
    /// never shows around it while it dissolves.
    private func photo(_ id: String) -> some View {
        Color.clear
            .frame(width: size.width, height: size.height)
            .overlay {
                PhotoImage(id: id, size: geometry.card, contentMode: .fill)
            }
            .clipped()
            .blur(radius: isExpanded ? Self.dissolveBlur : 0)
            .opacity(isExpanded ? 0 : 1)
            .allowsHitTesting(false)
    }

    /// The system card the pool grew out of, at its own size in the middle of the growing card, dissolving into
    /// blur as the card grows and focusing again as it shrinks back. Looks only: it takes no touches.
    private var ghostCard: some View {
        Color.clear
            .frame(width: size.width, height: size.height)
            .overlay {
                ghost().frame(width: geometry.card.width, height: geometry.card.height)
            }
            .blur(radius: isExpanded ? Self.dissolveBlur : 0)
            .opacity(isExpanded ? 0 : 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// `items` at the grid's places from `start` on, each cell put where the metrics say.
    private func cells(_ items: [String], metrics: PoolGridMetrics, startingAt start: Int = 0) -> some View {
        let outerRadius = CardShape.systemCornerRadius - Self.inset
        return ZStack(alignment: .topLeading) {
            ForEach(Array(items.enumerated()), id: \.element) { offset, id in
                let index = start + offset
                let frame = metrics.frame(at: index)
                PoolCellImage(id: id, side: imageSide)
                    .clipShape(.rect(
                        topLeadingRadius: isExpanded ? 0 : index == 0 ? outerRadius : 6,
                        bottomLeadingRadius: isExpanded ? 0 : 6,
                        bottomTrailingRadius: isExpanded ? 0 : 6,
                        topTrailingRadius: isExpanded ? 0 : index == PoolGridMetrics.columns - 1 ? outerRadius : 6,
                        style: .continuous
                    ))
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
            }
        }
    }

    // MARK: Live grid

    /// The system grid from under the top bar to the bottom edge, present through the growth (a scroll view
    /// appearing later would make the bars restyle themselves in a flash) but unseen and untouchable until the
    /// growth has settled.
    private func liveGrid(_ grid: PoolGridBindings) -> some View {
        let rect = geometry.expandedGridRect
        return PhotoSelectionGrid(
            ids: ids,
            gap: PoolGridMetrics.expandedGap,
            cellSize: imageSide,
            bottomInset: geometry.insets.bottom,
            isInteractive: showsLiveGrid,
            isSelecting: grid.isSelecting,
            selection: grid.selection,
            restore: actions.restore,
            delete: actions.delete
        )
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        .opacity(showsLiveGrid ? 1 : 0)
    }

    /// The pool opened with nothing in it: the words come in with the growth and go with the shrink, on the same
    /// animation, rather than appearing once the card has grown.
    private var emptyNote: some View {
        let rect = geometry.contentRect
        return Text("没有待删除媒体")
            .font(.title3)
            .foregroundStyle(.white.opacity(0.35))
            .position(x: rect.midX, y: rect.midY)
            .opacity(isExpanded ? 1 : 0)
            .allowsHitTesting(false)
    }

    // MARK: Pill

    /// The card's button. It dissolves into blur as the card grows, the bars' buttons taking over, and comes back
    /// into focus as the card returns.
    private var pill: some View {
        VStack(spacing: 12) {
            if isLimitedAccess {
                Button("选择更多照片", action: actions.chooseMorePhotos)
                    .font(.subheadline)
            }
            Button(action: actions.check) {
                Text(ids.isEmpty ? String(localized: "没有待删除媒体") : String(localized: "检查 \(ids.count) 项媒体"))
                    .font(.headline)
                    .monospacedDigit()
                    .lineLimit(1)
                    // Longer languages shrink a little rather than wrap and stretch the pill.
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .modifier(GlassPillButton())
            .disabled(ids.isEmpty)
        }
        .frame(width: max(geometry.card.width - Self.inset * 2, 0))
        .padding(.bottom, Self.inset)
        .blur(radius: isExpanded ? Self.dissolveBlur : 0)
        .opacity(isExpanded || !isFromSummary ? 0 : 1)
        .allowsHitTesting(!isExpanded && isFromSummary)
    }
}

/// The live grid's state, held by the pool controller and bound here.
struct PoolGridBindings {
    var isSelecting: Binding<Bool>
    var selection: Binding<Set<String>>
}

/// What the pool's buttons do. The card in the deck has the check; the open pool has the rest.
struct PoolActions {
    var check: () -> Void = {}
    var restore: ([String]) -> Void = { _ in }
    var delete: ([String]) -> Void = { _ in }
    var chooseMorePhotos: () -> Void = {}
}

/// One pool photo filling its square: the one drawing of a cell, in the preview and in the collection view alike.
struct PoolCellImage: View {
    let id: String
    let side: CGFloat

    var body: some View {
        // The square is the cell's; the photo is laid over it and cut to it, so a filled image cannot stretch the
        // cell to its own proportions.
        Color.clear
            .overlay {
                PhotoImage(id: id, size: CGSize(width: side, height: side), contentMode: .fill)
            }
            .clipped()
    }
}
