// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import Photos
import SwiftUI
import UIKit

/// The pool's photos as a collection view, for the system's own selection: in select mode a tap toggles a photo
/// and a finger dragged across photos selects them as it goes. SwiftUI's grids have no such gesture. Cells draw
/// SwiftUI content. Laid out by `PoolGridMetrics`, the same as the preview it takes over from.
struct PhotoSelectionGrid: UIViewRepresentable {
    let ids: [String]
    let gap: CGFloat
    /// Each cell's side in points as the preview requested it, so cells show the pictures already cached rather
    /// than a placeholder first. It changes with the room's width (the phone turned); the cells then ask again.
    let cellSize: CGFloat
    /// The bottom bar's room, which the grid runs beneath: the last row scrolls up clear of the bar's buttons.
    let bottomInset: CGFloat
    /// Whether touches reach the grid. Set on the UIKit view itself, which is reliable where SwiftUI's hit-testing
    /// switch on a UIKit view is not.
    let isInteractive: Bool
    @Binding var isSelecting: Bool
    @Binding var selection: Set<String>
    let restore: ([String]) -> Void
    let delete: ([String]) -> Void

    @Environment(PhotoLibrary.self) private var library
    @Environment(PhotoImageLoader.self) private var images
    @Environment(AppSettings.self) private var settings

    func makeUIView(context: Context) -> GridContainer {
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: PoolGridLayout(gap: gap))
        // The grid starts under the top bar and runs beneath the bottom bar's glass buttons: its one inset, for
        // the bottom bar, is set here rather than taken from the safe area, and no edge is shaded.
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.topEdgeEffect.isHidden = true
        collectionView.bottomEdgeEffect.isHidden = true
        // Opaque, the card's gray: once faded in it covers the preview completely, gaps included.
        collectionView.backgroundColor = .secondarySystemBackground
        collectionView.alwaysBounceVertical = true
        // Selection exists only while selecting; outside it, touches (one finger or two) select nothing.
        collectionView.allowsSelection = false
        collectionView.allowsMultipleSelection = false
        collectionView.allowsSelectionDuringEditing = true
        collectionView.allowsMultipleSelectionDuringEditing = true
        collectionView.delegate = context.coordinator
        collectionView.prefetchDataSource = context.coordinator
        context.coordinator.attach(to: collectionView)
        return GridContainer(collectionView: collectionView)
    }

    func updateUIView(_ container: GridContainer, context: Context) {
        let collectionView = container.collectionView
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.apply(ids)
        if collectionView.isEditing != isSelecting {
            collectionView.isEditing = isSelecting
            collectionView.allowsSelection = isSelecting
            collectionView.allowsMultipleSelection = isSelecting
        }
        coordinator.syncSelection(to: selection)
        if collectionView.contentInset.bottom != bottomInset {
            collectionView.contentInset.bottom = bottomInset
            collectionView.verticalScrollIndicatorInsets.bottom = bottomInset
        }
        if coordinator.cellSize != cellSize {
            // What was decoded at the old size is of no use at the new one.
            coordinator.stopPrefetching()
            coordinator.cellSize = cellSize
            coordinator.reconfigureAll()
        }
        collectionView.isUserInteractionEnabled = isInteractive
    }

    static func dismantleUIView(_ container: GridContainer, coordinator: Coordinator) {
        coordinator.stopPrefetching()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    /// A plain box around the collection view with no size of its own, so SwiftUI sizes it only by what it is
    /// offered: a collection view handed over directly can be sized by its content, every row at once, and then
    /// scrolls nothing. The collection view fills the box.
    final class GridContainer: UIView {
        let collectionView: UICollectionView

        init(collectionView: UICollectionView) {
            self.collectionView = collectionView
            super.init(frame: .zero)
            collectionView.frame = bounds
            collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(collectionView)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override var intrinsicContentSize: CGSize {
            CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
        }

        override func sizeThatFits(_ size: CGSize) -> CGSize { size }
    }

    /// Lays cells out by `PoolGridMetrics`, the same frames the SwiftUI preview draws, so the two coincide to the
    /// pixel.
    final class PoolGridLayout: UICollectionViewLayout {
        private let gap: CGFloat
        private var metrics = PoolGridMetrics(width: 1, gap: 0)
        private var count = 0

        init(gap: CGFloat) {
            self.gap = gap
            super.init()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func prepare() {
            guard let collectionView else { return }
            metrics = PoolGridMetrics(width: collectionView.bounds.width, gap: gap, scale: collectionView.traitCollection.displayScale)
            count = collectionView.numberOfSections > 0 ? collectionView.numberOfItems(inSection: 0) : 0
        }

        override var collectionViewContentSize: CGSize {
            let rows = (count + PoolGridMetrics.columns - 1) / PoolGridMetrics.columns
            return CGSize(width: metrics.width, height: metrics.height(forRows: rows))
        }

        override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
            let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
            attributes.frame = metrics.frame(at: indexPath.item)
            return attributes
        }

        override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
            guard count > 0, metrics.pitch > 0 else { return [] }
            let firstRow = max(Int(rect.minY / metrics.pitch), 0)
            let lastRow = Int(rect.maxY / metrics.pitch)
            let first = firstRow * PoolGridMetrics.columns
            let last = min((lastRow + 1) * PoolGridMetrics.columns, count)
            guard first < last else { return [] }
            return (first..<last).compactMap { layoutAttributesForItem(at: IndexPath(item: $0, section: 0)) }
        }

        override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
            newBounds.width != collectionView?.bounds.width
        }
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
        var parent: PhotoSelectionGrid
        private var dataSource: UICollectionViewDiffableDataSource<Int, String>?
        private weak var collectionView: UICollectionView?
        /// The side the cells were last configured to request; cells read the current one when configured.
        var cellSize: CGFloat
        /// Photos PhotoKit was asked to decode ahead of the scroll, by pixel side.
        private var prefetched: [String: CGFloat] = [:]
        /// Set while this coordinator itself selects or deselects, so the delegate calls it causes are ignored.
        private var isSyncing = false

        init(parent: PhotoSelectionGrid) {
            self.parent = parent
            cellSize = parent.cellSize
        }

        func attach(to collectionView: UICollectionView) {
            self.collectionView = collectionView
            let registration = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, id in
                guard let self else { return }
                let library = parent.library
                let images = parent.images
                let settings = parent.settings
                cell.configurationUpdateHandler = { [weak self] cell, state in
                    guard let self else { return }
                    cell.contentConfiguration = UIHostingConfiguration {
                        // The whole cell, not its safe area: a cell partly under a bar is handed the bar's inset,
                        // and content that honored it would squeeze into the part still clear of the bar.
                        PendingPhotoCell(id: id, size: self.cellSize, isEditing: state.isEditing, isSelected: state.isSelected)
                            .environment(library)
                            .environment(images)
                            .environment(settings)
                            .ignoresSafeArea()
                    }
                    .margins(.all, 0)
                }
                cell.isAccessibilityElement = true
                cell.accessibilityLabel = library.asset(for: id)?.accessibilityName ?? String(localized: "照片")
                cell.accessibilityCustomActions = [
                    UIAccessibilityCustomAction(name: String(localized: "恢复")) { [weak self] _ in
                        self?.parent.restore([id])
                        return true
                    },
                    UIAccessibilityCustomAction(name: String(localized: "删除")) { [weak self] _ in
                        self?.parent.delete([id])
                        return true
                    },
                ]
            }
            dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, id in
                collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
            }
        }

        func apply(_ ids: [String]) {
            guard let dataSource, dataSource.snapshot().itemIdentifiers != ids else { return }
            var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
            snapshot.appendSections([0])
            snapshot.appendItems(ids)
            dataSource.apply(snapshot, animatingDifferences: collectionView?.window != nil)
        }

        /// Every cell configured again, for a new cell size.
        func reconfigureAll() {
            guard let dataSource else { return }
            var snapshot = dataSource.snapshot()
            snapshot.reconfigureItems(snapshot.itemIdentifiers)
            dataSource.apply(snapshot, animatingDifferences: false)
        }

        /// Makes the collection view's selection match the binding, without echoing back through the delegate.
        func syncSelection(to selection: Set<String>) {
            guard let collectionView, let dataSource else { return }
            isSyncing = true
            defer { isSyncing = false }
            let selectedPaths = collectionView.indexPathsForSelectedItems ?? []
            let selectedIDs = Set(selectedPaths.compactMap(dataSource.itemIdentifier(for:)))
            for path in selectedPaths where !selection.contains(dataSource.itemIdentifier(for: path) ?? "") {
                collectionView.deselectItem(at: path, animated: false)
            }
            for id in selection.subtracting(selectedIDs) {
                if let path = dataSource.indexPath(for: id) {
                    collectionView.selectItem(at: path, animated: false, scrollPosition: [])
                }
            }
        }

        // MARK: Prefetching

        /// PhotoKit decodes the photos the scroll is about to reach, at the cells' size, and lets them go when
        /// the scroll turns away or the grid is taken down.
        func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
            let side = cellSize * collectionView.traitCollection.displayScale
            let ids = indexPaths.compactMap { dataSource?.itemIdentifier(for: $0) }
            for id in ids { prefetched[id] = side }
            parent.images.cacheAhead(ids, targetSize: CGSize(width: side, height: side))
        }

        func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
            let ids = indexPaths.compactMap { dataSource?.itemIdentifier(for: $0) }
            stopPrefetching(ids)
        }

        /// A cell that was shown is not cancelled: it is let go of here, once it has scrolled away, or PhotoKit
        /// would keep every photo ever scrolled past decoded until the grid is taken down.
        func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
            guard let id = dataSource?.itemIdentifier(for: indexPath) else { return }
            stopPrefetching([id])
        }

        func stopPrefetching(_ ids: [String]? = nil) {
            var bySide: [CGFloat: [String]] = [:]
            for id in ids ?? Array(prefetched.keys) {
                guard let side = prefetched.removeValue(forKey: id) else { continue }
                bySide[side, default: []].append(id)
            }
            for (side, ids) in bySide {
                parent.images.stopCachingAhead(ids, targetSize: CGSize(width: side, height: side))
            }
        }

        // MARK: Selection

        func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
            collectionView.isEditing
        }

        func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
            collectionView.isEditing
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            guard !isSyncing, let id = dataSource?.itemIdentifier(for: indexPath) else { return }
            parent.selection.insert(id)
        }

        func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
            guard !isSyncing, let id = dataSource?.itemIdentifier(for: indexPath) else { return }
            parent.selection.remove(id)
        }

        /// No two-finger drag to start selecting: that gesture belongs to lists, not a grid. Selecting starts from
        /// the bar button; the finger dragged across photos while selecting is this same interaction, and stays.
        func collectionView(_ collectionView: UICollectionView, shouldBeginMultipleSelectionInteractionAt indexPath: IndexPath) -> Bool {
            collectionView.isEditing
        }

        // MARK: Context menu

        func collectionView(
            _ collectionView: UICollectionView,
            contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
            point: CGPoint
        ) -> UIContextMenuConfiguration? {
            guard !collectionView.isEditing, indexPaths.count == 1, let indexPath = indexPaths.first,
                  let id = dataSource?.itemIdentifier(for: indexPath) else { return nil }
            let parent = parent
            return UIContextMenuConfiguration(identifier: id as NSString, previewProvider: {
                let size = fittedPhotoSize(parent.library.asset(for: id), in: CGSize(width: 360, height: 480))
                let controller = UIHostingController(rootView: PhotoImage(id: id, size: size)
                    .frame(width: size.width, height: size.height)
                    .environment(parent.library)
                    .environment(parent.images)
                    .environment(parent.settings))
                controller.preferredContentSize = size
                controller.view.backgroundColor = .clear
                return controller
            }, actionProvider: { _ in
                UIMenu(children: [
                    UIAction(title: String(localized: "恢复"), image: UIImage(systemName: "arrow.uturn.backward")) { _ in parent.restore([id]) },
                    UIAction(title: String(localized: "删除"), image: UIImage(systemName: "trash"), attributes: .destructive) { _ in parent.delete([id]) },
                ])
            })
        }
    }
}

/// One pool photo, filling its square; in select mode, the system-style check at its corner.
private struct PendingPhotoCell: View {
    let id: String
    let size: CGFloat
    let isEditing: Bool
    let isSelected: Bool

    var body: some View {
        PoolCellImage(id: id, side: size)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if isSelected { Color.black.opacity(0.25) }
            }
            .overlay(alignment: .bottomTrailing) {
                if isEditing {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, isSelected ? Color.accentColor : .black.opacity(0.2))
                        .shadow(radius: 2)
                        .padding(6)
                        .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.2), value: isSelected)
            .animation(.smooth(duration: 0.2), value: isEditing)
    }
}
