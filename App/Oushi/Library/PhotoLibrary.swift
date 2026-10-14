// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import Observation
import Photos
import UIKit

/// Photos access and the app's view of the library: the photos and videos, newest first.
///
/// The library is read in full once, off the main thread; after that PhotoKit's change details are applied as
/// they come, in order: photos added or removed move in and out of the list in place, and an edited or favorited
/// photo's object is swapped for the new one. Only a change that moves photos around (or one PhotoKit cannot
/// describe step by step) reads the library again.
@MainActor
@Observable
final class PhotoLibrary: NSObject, PHPhotoLibraryChangeObserver {
    private(set) var authorizationStatus: PHAuthorizationStatus
    /// False until the first read finishes; until then an empty `availableIDs` means "not known yet", not "no photos".
    private(set) var hasLoaded = false
    /// The photos and videos the app can see, newest first.
    private(set) var availableIDs: [String] = []
    var errorMessage: String?

    /// Bumped when photos are added or removed, so lookups of IDs that were missing are redone.
    private(set) var structureRevision = 0
    /// Bumped on every change the library reports, structural or not (a favorite flag, a new version).
    private(set) var changeRevision = 0
    /// A read of the whole library is under way; what `availableIDs` says is about to be replaced.
    private(set) var isReading = false
    @ObservationIgnored private var assets: [String: PHAsset] = [:]
    @ObservationIgnored private var fetchResult: PHFetchResult<PHAsset>?
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var readGeneration = 0
    @ObservationIgnored private var changingFavoriteIDs: Set<String> = []
    /// Photos changed (favorited, edited) while a read was under way, by identifier: newer than the read's
    /// snapshot, they go over it when it lands.
    @ObservationIgnored private var changedDuringRead: [String: PHAsset] = [:]
    /// PhotoKit's changes, delivered on its own thread, lined up for the main actor in the order they came.
    @ObservationIgnored nonisolated private let changes: AsyncStream<PHChange>.Continuation
    /// Registered for library changes. Only once access is granted: registering before the user has answered
    /// makes the system ask on its own, and the ask should come from the access card's button.
    @ObservationIgnored private var isObserving = false

    var hasAccess: Bool {
        authorizationStatus == .authorized || authorizationStatus == .limited
    }

    var hasFullAccess: Bool { authorizationStatus == .authorized }

    override init() {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let (stream, continuation) = AsyncStream.makeStream(of: PHChange.self)
        changes = continuation
        super.init()
        // Ends on its own once the stream is finished in deinit.
        Task { [weak self] in
            for await change in stream {
                guard let self else { return }
                self.apply(change)
            }
        }
        refresh()
    }

    deinit {
        // Harmless when never registered.
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
        changes.finish()
    }

    func requestAccess() async {
        errorMessage = nil
        authorizationStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        refresh()
    }

    /// Reads the authorization, and the library the first time or when access changed (for example from limited
    /// to full in Settings). Later changes arrive through `photoLibraryDidChange`.
    func refresh() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status != authorizationStatus { fetchResult = nil }
        authorizationStatus = status
        guard hasAccess else {
            readTask?.cancel()
            readGeneration += 1
            isReading = false
            fetchResult = nil
            assets = [:]
            availableIDs = []
            structureRevision += 1
            hasLoaded = true
            return
        }
        if !isObserving {
            PHPhotoLibrary.shared().register(self)
            isObserving = true
        }
        guard fetchResult == nil else { return }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(
            format: "mediaType == %d OR mediaType == %d",
            PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue
        )
        read(PHAsset.fetchAssets(with: options))
    }

    /// The photo's object as the library last reported it: tracked by whoever reads it, so a swapped object (a new
    /// favorite flag, a new version) is read again.
    func asset(for id: String) -> PHAsset? {
        _ = changeRevision
        return assets[id]
    }

    /// Saves the favorite flag; returns whether it was saved. The change comes back through the library observer.
    func setFavorite(_ favorite: Bool, id: String) async -> Bool {
        guard hasAccess, let asset = assets[id], !changingFavoriteIDs.contains(id) else { return false }
        guard asset.canPerform(.properties) else {
            errorMessage = String(localized: "这一项暂时无法修改收藏状态。")
            return false
        }
        changingFavoriteIDs.insert(id)
        defer { changingFavoriteIDs.remove(id) }
        do {
            try await PHPhotoLibrary.shared().performChanges { @Sendable in
                PHAssetChangeRequest(for: asset).isFavorite = favorite
            }
            return true
        } catch {
            Log.library.error("favorite could not be saved: \(error, privacy: .public)")
            errorMessage = String(localized: "收藏状态未能保存，请重试。")
            return false
        }
    }

    /// PhotoKit asks the user to confirm, then moves the photos to Recently Deleted. Returns the identifiers of
    /// the photos deleted: those the app may delete (one synced from a computer cannot be; the user is told how
    /// many were left), or nil when the user declined or the deletion failed.
    func deleteAssets(ids: [String]) async -> [String]? {
        guard hasAccess else { return nil }
        let targets = ids.compactMap { assets[$0] }
        let deletable = targets.filter { $0.canPerform(.delete) }
        let undeletable = targets.count - deletable.count
        guard !deletable.isEmpty else {
            if undeletable > 0 { errorMessage = String(localized: "有 \(undeletable) 项无法从相册删除。") }
            return []
        }
        do {
            try await PHPhotoLibrary.shared().performChanges { @Sendable in
                PHAssetChangeRequest.deleteAssets(deletable as NSArray)
            }
            if undeletable > 0 { errorMessage = String(localized: "有 \(undeletable) 项无法从相册删除。") }
            return deletable.map(\.localIdentifier)
        } catch let error as PHPhotosError where error.code == .userCancelled {
            return nil
        } catch {
            Log.library.error("deletion failed: \(error, privacy: .public)")
            errorMessage = String(localized: "照片未能删除，请重试。")
            return nil
        }
    }

    func clearError() {
        errorMessage = nil
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        changes.yield(changeInstance)
    }

    // MARK: Reading

    /// Enumerates `result` off the main thread, then installs it. A newer read supersedes an older one, which
    /// stops where it is.
    private func read(_ result: PHFetchResult<PHAsset>) {
        fetchResult = result
        // Until this read lands, a sync against the old list would let go of records it cannot see.
        isReading = true
        // This snapshot is newer than anything swapped in during the read before it.
        changedDuringRead = [:]
        readTask?.cancel()
        readGeneration += 1
        let generation = readGeneration
        readTask = Task.detached(priority: .userInitiated) { [weak self] in
            var assets: [PHAsset] = []
            assets.reserveCapacity(result.count)
            result.enumerateObjects { asset, _, stop in
                if Task.isCancelled { stop.pointee = true } else { assets.append(asset) }
            }
            guard !Task.isCancelled else { return }
            await self?.install(assets, generation: generation)
        }
    }

    private func install(_ assets: [PHAsset], generation: Int) {
        guard generation == readGeneration else { return }
        var installed: [String: PHAsset] = [:]
        installed.reserveCapacity(assets.count)
        var ids: [String] = []
        ids.reserveCapacity(assets.count)
        for asset in assets where installed[asset.localIdentifier] == nil {
            installed[asset.localIdentifier] = asset
            ids.append(asset.localIdentifier)
        }
        for (id, asset) in changedDuringRead where installed[id] != nil { installed[id] = asset }
        changedDuringRead = [:]
        self.assets = installed
        structureRevision += 1
        if ids != availableIDs { availableIDs = ids }
        changeRevision += 1
        isReading = false
        hasLoaded = true
        Log.library.info("library read: \(ids.count, privacy: .public) items")
    }

    /// Applies one PhotoKit change in place: photos removed and added at their positions, changed photos swapped
    /// for their new objects. A change with moves, or one without step-by-step details, reads the library again,
    /// as does one that adds or removes photos while a read is still under way (the read's snapshot would not
    /// have them). A photo merely changed during a read (favorited, edited) is swapped in now, and again over the
    /// snapshot's older object once the read lands, rather than starting the read over.
    private func apply(_ change: PHChange) {
        guard let fetchResult, let details = change.changeDetails(for: fetchResult) else { return }
        self.fetchResult = details.fetchResultAfterChanges
        guard details.hasIncrementalChanges, !details.hasMoves else {
            read(details.fetchResultAfterChanges)
            return
        }
        let removed = details.removedIndexes ?? IndexSet()
        let inserted = details.insertedIndexes ?? IndexSet()
        if isReading {
            guard removed.isEmpty, inserted.isEmpty else {
                read(details.fetchResultAfterChanges)
                return
            }
            for asset in details.changedObjects {
                changedDuringRead[asset.localIdentifier] = asset
                if assets[asset.localIdentifier] != nil { assets[asset.localIdentifier] = asset }
            }
            changeRevision += 1
            return
        }
        var ids = availableIDs
        var structural = false
        if !removed.isEmpty {
            for index in removed.reversed() where ids.indices.contains(index) {
                assets[ids[index]] = nil
                ids.remove(at: index)
            }
            structural = true
        }
        if !inserted.isEmpty {
            let objects = details.insertedObjects
            var next = 0
            for index in inserted where next < objects.count {
                let asset = objects[next]
                next += 1
                ids.insert(asset.localIdentifier, at: min(index, ids.count))
                assets[asset.localIdentifier] = asset
            }
            structural = true
        }
        for asset in details.changedObjects where assets[asset.localIdentifier] != nil {
            assets[asset.localIdentifier] = asset
        }
        if structural {
            availableIDs = ids
            structureRevision += 1
        }
        changeRevision += 1
    }
}

extension PHAsset {
    var accessibilityName: String {
        let isVideo = mediaType == .video
        guard let creationDate else { return isVideo ? String(localized: "视频") : String(localized: "照片") }
        let date = creationDate.formatted(date: .abbreviated, time: .omitted)
        return isVideo ? String(localized: "\(date)的视频") : String(localized: "\(date)的照片")
    }
}
