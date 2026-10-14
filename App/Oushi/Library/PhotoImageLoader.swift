// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import Observation
import os
import Photos
import UIKit

/// Loads photo images through PhotoKit, keeps recent ones in memory, and preheats the photos about to be shown.
/// Observable only so it can travel through the SwiftUI environment; it has no observed state.
@MainActor
@Observable
final class PhotoImageLoader {
    @ObservationIgnored private let library: PhotoLibrary
    @ObservationIgnored private let manager = PHCachingImageManager()
    @ObservationIgnored private let cache = NSCache<NSString, UIImage>()
    /// The pool's photos, warmed ahead of the pool and kept apart from `cache`: there, the deck's few large images
    /// would push them out between the warming and the pool's opening, and the card growing into the pool would
    /// show gray cells that fill in once it has grown.
    @ObservationIgnored private let warmed = NSCache<NSString, UIImage>()
    @ObservationIgnored private var preheated: [String: (asset: PHAsset, size: CGSize)] = [:]
    @ObservationIgnored private var memoryWarningObserver: (any NSObjectProtocol)?

    init(library: PhotoLibrary) {
        self.library = library
        // Budgets from what the process may use: a share for the deck's few large images, a smaller one for the
        // pool's cells, each capped where more would be waste.
        let available = Int(clamping: os_proc_available_memory())
        cache.countLimit = 120
        cache.totalCostLimit = min(96 << 20, max(available / 8, 24 << 20))
        warmed.countLimit = 96
        warmed.totalCostLimit = min(64 << 20, max(available / 12, 16 << 20))
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dropEverything() }
        }
    }

    /// Memory is short: everything held here goes, PhotoKit's preheated decodes included. What is on screen is
    /// loaded again as it is asked for.
    private func dropEverything() {
        Log.images.notice("memory warning: dropping cached images")
        cache.removeAllObjects()
        warmed.removeAllObjects()
        manager.stopCachingImagesForAllAssets()
        preheated = [:]
    }

    /// Which store a loaded image goes into: the deck's, for its few large images, or the pool's, for its many
    /// small cells, so neither pushes the other's out.
    enum Store {
        case deck, pool
    }

    /// The image at `targetSize` (in pixels, as PhotoKit expects), fitted inside it or filling it, or nil when it
    /// could not be loaded. A quick low-quality version, when PhotoKit has one before the real image, is handed
    /// to `preview` on the way.
    func image(
        for id: String, targetSize: CGSize, contentMode: PHImageContentMode = .aspectFit, store: Store = .deck,
        preview: @escaping @MainActor @Sendable (UIImage) -> Void = { _ in }
    ) async -> UIImage? {
        guard let (image, key, fresh) = await load(id, targetSize: targetSize, contentMode: contentMode, preview: preview) else { return nil }
        // Only a fresh image is stored, and where its caller says: one already in either store stays there.
        if fresh {
            let target = store == .pool ? warmed : cache
            target.setObject(image, forKey: key, cost: Self.cost(of: image))
        }
        return image
    }

    /// The image from either store, or freshly from PhotoKit (`fresh`), with its key; stored by the caller where
    /// it belongs.
    private func load(_ id: String, targetSize: CGSize, contentMode: PHImageContentMode, preview: @escaping @MainActor @Sendable (UIImage) -> Void) async -> (UIImage, NSString, fresh: Bool)? {
        guard !Task.isCancelled, library.hasAccess, let asset = library.asset(for: id) else { return nil }
        let size = Self.clamped(targetSize)
        let key = Self.cacheKey(asset: asset, size: size, contentMode: contentMode)
        if let cached = cached(forKey: key) { return (cached, key, false) }
        let result = await request(asset: asset, targetSize: size, contentMode: contentMode, options: Self.options, preview: preview)
        guard !Task.isCancelled, case .image(let image) = result else { return nil }
        return (image, key, true)
    }

    /// Loads the pool's photos ahead of their first appearance, one after another, skipping any already warmed,
    /// and keeps them in the pool's store, so the card that grows into the pool shows them at once instead of
    /// gray cells that fill in during or after the growth. Filling their squares, as the cells show them.
    func warm(_ ids: [String], targetSize: CGSize) async {
        let size = Self.clamped(targetSize)
        for id in ids {
            guard !Task.isCancelled else { return }
            guard let asset = library.asset(for: id) else { continue }
            guard warmed.object(forKey: Self.cacheKey(asset: asset, size: size, contentMode: .aspectFill)) == nil else { continue }
            if let (image, key, _) = await load(id, targetSize: size, contentMode: .aspectFill, preview: { _ in }) {
                warmed.setObject(image, forKey: key, cost: Self.cost(of: image))
            }
        }
    }

    /// Warms `ids` as `warm(_:targetSize:)` does, returning once they are all in or once `limit` has passed,
    /// whichever comes first; the warming goes on after the wait ends. For the moment before the pool opens.
    func warm(_ ids: [String], targetSize: CGSize, waitingUpTo limit: Duration) async {
        let warming = Task { await warm(ids, targetSize: targetSize) }
        // Whichever ends first resumes the wait; the warming itself is not cancelled, the timer is.
        let gate = ResumeOnce()
        let timer = Task { try? await Task.sleep(for: limit) }
        await withCheckedContinuation { continuation in
            gate.continuation = continuation
            Task {
                await warming.value
                gate.resume()
                timer.cancel()
            }
            Task {
                await timer.value
                gate.resume()
            }
        }
    }

    /// A continuation resumed by the first of several to finish.
    @MainActor
    private final class ResumeOnce {
        var continuation: CheckedContinuation<Void, Never>?

        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }

    /// A small image as fast as PhotoKit can give one (the embedded thumbnail; a quick version from iCloud at most,
    /// never the full photo): for a few colors, not for looking at. Not cached here; PhotoKit's own thumbnails are
    /// quick enough.
    func quickImage(for id: String, targetSize: CGSize) async -> UIImage? {
        guard !Task.isCancelled, library.hasAccess, let asset = library.asset(for: id) else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        let result = await request(asset: asset, targetSize: Self.clamped(targetSize), contentMode: .aspectFit, options: options, preview: { _ in })
        guard case .image(let image) = result else { return nil }
        return image
    }

    /// An image already loaded, without waiting, so a card shown again starts with its picture.
    func cachedImage(for id: String, targetSize: CGSize, contentMode: PHImageContentMode = .aspectFit) -> UIImage? {
        guard library.hasAccess, let asset = library.asset(for: id) else { return nil }
        return cached(forKey: Self.cacheKey(asset: asset, size: Self.clamped(targetSize), contentMode: contentMode))
    }

    private func cached(forKey key: NSString) -> UIImage? {
        cache.object(forKey: key) ?? warmed.object(forKey: key)
    }

    private static func cost(of image: UIImage) -> Int {
        (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0)
    }

    /// Lets PhotoKit start decoding the next cards before they are shown. Each request is a photo ID and the pixel
    /// size its card will ask for, since PhotoKit's cache only helps a request of the same size.
    func preheat(_ requests: [(id: String, pixelSize: CGSize)]) {
        var next: [String: (asset: PHAsset, size: CGSize)] = [:]
        for request in requests {
            guard let asset = library.asset(for: request.id), request.pixelSize.width > 0 else { continue }
            next[request.id] = (asset, Self.clamped(request.pixelSize))
        }
        for (id, old) in preheated where next[id]?.size != old.size {
            manager.stopCachingImages(for: [old.asset], targetSize: old.size, contentMode: .aspectFit, options: Self.options)
        }
        for (id, new) in next where preheated[id]?.size != new.size {
            manager.startCachingImages(for: [new.asset], targetSize: new.size, contentMode: .aspectFit, options: Self.options)
        }
        preheated = next
    }

    /// Lets PhotoKit decode photos the pool's grid is about to show, and stops when they scroll out of reach.
    /// The same size, content mode (the cells fill their squares) and options as the requests, or PhotoKit's
    /// cache would never serve them.
    func cacheAhead(_ ids: [String], targetSize: CGSize) {
        let assets = ids.compactMap(library.asset(for:))
        guard !assets.isEmpty else { return }
        manager.startCachingImages(for: assets, targetSize: Self.clamped(targetSize), contentMode: .aspectFill, options: Self.options)
    }

    func stopCachingAhead(_ ids: [String], targetSize: CGSize) {
        let assets = ids.compactMap(library.asset(for:))
        guard !assets.isEmpty else { return }
        manager.stopCachingImages(for: assets, targetSize: Self.clamped(targetSize), contentMode: .aspectFill, options: Self.options)
    }

    private static var options: PHImageRequestOptions {
        let options = PHImageRequestOptions()
        // A quick version first when there is one, the real image after: a photo still in iCloud shows something
        // while it downloads.
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.version = .current
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        return options
    }

    private static func clamped(_ size: CGSize) -> CGSize {
        CGSize(width: max(1, size.width.rounded()), height: max(1, size.height.rounded()))
    }

    private static func cacheKey(asset: PHAsset, size: CGSize, contentMode: PHImageContentMode) -> NSString {
        let modification = asset.modificationDate?.timeIntervalSince1970 ?? 0
        let mode = contentMode == .aspectFill ? "fill" : "fit"
        return "\(asset.localIdentifier):\(Int(size.width))x\(Int(size.height)):\(mode):\(modification)" as NSString
    }

    private func request(asset: PHAsset, targetSize: CGSize, contentMode: PHImageContentMode, options: PHImageRequestOptions, preview: @escaping @MainActor @Sendable (UIImage) -> Void) async -> ImageResult {
        let state = ImageRequestState(manager: manager)
        options.progressHandler = { @Sendable _, error, _, _ in
            if let error {
                Log.images.error("image request failed: \(error, privacy: .public)")
                state.finish(.failed)
            }
        }
        // Previews arrive on PhotoKit's thread; they are lined up for the main actor and handed over there.
        let previews = AsyncStream.makeStream(of: UIImage.self)
        let delivering = Task { @MainActor in
            for await image in previews.stream {
                // Over since (the real image came, or the request was given up): a preview still queued is dropped.
                guard !Task.isCancelled else { return }
                preview(image)
            }
        }
        defer {
            previews.continuation.finish()
            delivering.cancel()
        }
        // The handler runs on PhotoKit's thread: it takes only what it may (the options are read here, once).
        let isQuick = options.deliveryMode == .fastFormat
        let previewSink = previews.continuation
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard state.install(continuation) else { return }
                let requestID = manager.requestImage(
                    for: asset,
                    targetSize: targetSize,
                    contentMode: contentMode,
                    options: options
                ) { @Sendable image, info in
                    if (info?[PHImageCancelledKey] as? Bool) == true {
                        state.finish(.cancelled)
                    } else if let error = info?[PHImageErrorKey] as? NSError {
                        if !isQuick { Log.images.error("image request failed: \(error, privacy: .public)") }
                        state.finish(.failed)
                    } else if (info?[PHImageResultIsDegradedKey] as? Bool) == true, !isQuick {
                        if let image { previewSink.yield(image) }
                    } else {
                        state.finish(image.map(ImageResult.image) ?? .unavailable)
                    }
                }
                state.setRequestID(requestID)
            }
        } onCancel: {
            state.cancel()
        }
    }
}

private enum ImageResult: Sendable {
    case image(UIImage)
    case unavailable
    case failed
    case cancelled
}

/// PhotoKit may call back before requestImage returns, or more than once. This gate also resumes cancelled
/// requests even if PhotoKit sends no callback.
private final class ImageRequestState: Sendable {
    private struct State {
        var continuation: CheckedContinuation<ImageResult, Never>?
        var requestID: PHImageRequestID?
        var result: ImageResult?
        var wasCancelled = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let manager: PHImageManager

    init(manager: PHImageManager) {
        self.manager = manager
    }

    func install(_ continuation: CheckedContinuation<ImageResult, Never>) -> Bool {
        let settled = state.withLock { state -> ImageResult? in
            if let result = state.result { return result }
            state.continuation = continuation
            return nil
        }
        if let settled {
            continuation.resume(returning: settled)
            return false
        }
        return true
    }

    func setRequestID(_ id: PHImageRequestID) {
        let shouldCancel = state.withLock { state -> Bool in
            state.requestID = id
            return state.wasCancelled
        }
        if shouldCancel { manager.cancelImageRequest(id) }
    }

    func finish(_ newResult: ImageResult) {
        let pending = state.withLock { state -> CheckedContinuation<ImageResult, Never>? in
            guard state.result == nil else { return nil }
            state.result = newResult
            defer { state.continuation = nil }
            return state.continuation
        }
        pending?.resume(returning: newResult)
    }

    func cancel() {
        let id = state.withLock { state -> PHImageRequestID? in
            state.wasCancelled = true
            return state.requestID
        }
        finish(.cancelled)
        if let id { manager.cancelImageRequest(id) }
    }
}
