// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import CoreGraphics

/// The pool's grid in either layout: four square cells across, sized from the width and the gap between cells.
/// One formula for the SwiftUI preview and the collection view, so their cells land on the same points.
struct PoolGridMetrics: Equatable {
    static let columns = 4
    /// Between cells in the card and on the screen.
    static let compactGap: CGFloat = 4
    static let expandedGap: CGFloat = 2

    let width: CGFloat
    let gap: CGFloat
    /// Pixels per point: every frame is snapped to this grid, so two drawings of the same cell land on the same
    /// pixels and nothing resamples differently when one takes over from the other.
    var scale: CGFloat = 1

    var side: CGFloat { max((width - gap * CGFloat(Self.columns - 1)) / CGFloat(Self.columns), 1) }

    /// From one row's top to the next.
    var pitch: CGFloat { side + gap }

    func frame(at index: Int) -> CGRect {
        let column = index % Self.columns
        let row = index / Self.columns
        let x = snapped(CGFloat(column) * pitch)
        let y = snapped(CGFloat(row) * pitch)
        return CGRect(x: x, y: y, width: snapped(CGFloat(column) * pitch + side) - x, height: snapped(CGFloat(row) * pitch + side) - y)
    }

    private func snapped(_ value: CGFloat) -> CGFloat {
        // A view not yet in a window reports no scale.
        let scale = max(scale, 1)
        return (value * scale).rounded() / scale
    }

    /// Rows needed to cover `height`, the last one allowed to run past it.
    func rows(toCover height: CGFloat) -> Int {
        max(Int((height / pitch).rounded(.up)), 0)
    }

    func height(forRows rows: Int) -> CGFloat {
        rows <= 0 ? 0 : CGFloat(rows) * pitch - gap
    }
}
