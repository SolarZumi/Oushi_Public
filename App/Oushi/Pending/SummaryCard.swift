// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import Photos
import SwiftUI

/// The card as it sits in the deck: a system card's size, with the pool's preview and its button.
struct SummaryCard: View {
    /// Size of the area the deck lays cards out in.
    let bounds: CGSize
    let pendingIDs: [String]
    let isLimitedAccess: Bool
    /// The side the pool's grid will request its photos at, so the card asks for the same.
    let imageSide: CGFloat
    let check: () -> Void
    let chooseMorePhotos: () -> Void

    var body: some View {
        let size = CardShape.systemSize(in: bounds)
        PoolCardBody(
            ids: pendingIDs,
            geometry: PoolGeometry(card: size, screen: size, insets: EdgeInsets()),
            isExpanded: false,
            source: .summary,
            isLimitedAccess: isLimitedAccess,
            imageSide: imageSide,
            showsLiveGrid: false,
            actions: PoolActions(check: check, chooseMorePhotos: chooseMorePhotos),
            grid: nil
        ) { EmptyView() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "这一组翻完了，待删除 \(pendingIDs.count) 个"))
    }
}
