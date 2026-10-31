// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import Photos
import SwiftUI

/// The layer over the screen's content, under its bars, that hosts the open pool. It covers the whole screen when
/// expanded; the grid keeps to the room between the bars. The card the pool grew out of says where it is through
/// an anchor, resolved here in this layer's own coordinates: the overlay follows it (the phone turned) and shrinks
/// back to wherever the card is now.
struct PoolOverlay<Ghost: View>: View {
    let pool: PoolController
    let origin: Anchor<CGRect>?
    /// The room between the bars, in screen coordinates: the layer runs under the bars, and must know them.
    let contentFrame: CGRect
    let isLimitedAccess: Bool
    let imageSide: CGFloat
    let actions: PoolActions
    /// The system card the pool grows out of, if one (see `PoolCardBody.ghost`).
    @ViewBuilder let ghost: () -> Ghost

    var body: some View {
        GeometryReader { proxy in
            let screen = proxy.frame(in: .global)
            let insets = EdgeInsets(
                top: max(contentFrame.minY - screen.minY, 0),
                leading: max(contentFrame.minX - screen.minX, 0),
                bottom: max(screen.maxY - contentFrame.maxY, 0),
                trailing: max(screen.maxX - contentFrame.maxX, 0)
            )
            // No card reporting (the welcome, the first read): a system card's size in the middle of the room.
            let origin = origin.map { proxy[$0] } ?? (pool.lastOrigin == .zero ? Self.centredCard(in: screen.size, insets: insets) : pool.lastOrigin)
            let geometry = PoolGeometry(card: origin.size, screen: screen.size, insets: insets)
            let frame = pool.isExpanded ? CGRect(origin: .zero, size: screen.size) : origin
            @Bindable var pool = pool
            PoolCardBody(
                ids: pool.pendingIDs,
                geometry: geometry,
                isExpanded: pool.isExpanded,
                source: pool.source,
                isLimitedAccess: isLimitedAccess,
                imageSide: imageSide,
                showsLiveGrid: pool.showsLiveGrid,
                actions: actions,
                grid: PoolGridBindings(isSelecting: $pool.isSelecting, selection: $pool.selection),
                ghost: ghost
            )
            .position(x: frame.midX, y: frame.midY)
            .onChange(of: origin, initial: true) { _, origin in pool.lastOrigin = origin }
        }
        .ignoresSafeArea()
        .onAppear { pool.overlayAppeared() }
        // Open, the pool is the screen: a modal for assistive technology, closed by its escape gesture.
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(pool.isExpanded ? .isModal : [])
        .accessibilityAction(.escape) { pool.dismiss() }
    }

    /// Where a system card would stand: the deck's room is the content less its margins, as `ReviewScreen` lays
    /// it out, and a system card sits in the middle of it.
    private static func centredCard(in screen: CGSize, insets: EdgeInsets) -> CGRect {
        let content = CGRect(
            x: insets.leading, y: insets.top,
            width: max(screen.width - insets.leading - insets.trailing, 0),
            height: max(screen.height - insets.top - insets.bottom, 0)
        )
        let room = CGSize(width: max(content.width - 24, 0), height: max(content.height - 16, 0))
        let size = CardShape.systemSize(in: room)
        return CGRect(x: content.midX - size.width / 2, y: content.midY - size.height / 2, width: size.width, height: size.height)
    }
}
