// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import AVFoundation
import Observation
import Photos
import os

/// The video on top of the deck: one player for the app's lifetime, the item of the video on top, the next video's
/// item loading ahead of its turn, and what the user asked of it (playing, sound). The card hosts the player's
/// layer; the scrubber reads the time and sends the seeks; the deck view says which video is on top, which comes
/// next, and whether the card can be seen.
@MainActor
@Observable
final class VideoPlaybackController {
    enum Status: Equatable {
        /// No video on top.
        case idle
        /// The item is being fetched (from iCloud, perhaps) and readied.
        case loading
        case ready
        /// Playing was asked for but the player waits for data.
        case buffering
        /// The item could not be fetched or played.
        case failed
    }

    /// Made once, and again only after a media services reset, when the old one is no longer usable.
    private(set) var player = AVQueuePlayer()
    /// The video whose item the player holds (or is loading), by photo identifier, and the version of it (an
    /// edit in Photos makes a new one).
    private(set) var videoID: String?
    @ObservationIgnored private var videoVersion: Date?
    private(set) var status: Status = .idle
    /// Seconds into the video, as the player reports it, and its length.
    private(set) var time: Double = 0
    private(set) var duration: Double = 0
    /// The user's choices for this video; reset for each video that comes on top.
    var wantsPlaying = true {
        didSet {
            // Pressed either way, the button is the user's word: an interruption's resumption is no longer owed.
            resumesAfterInterruption = false
            applyPlayback()
        }
    }
    var soundOn = false {
        didSet { if soundOn != oldValue, !isApplyingSound { applySound() } }
    }
    /// A finger is on the scrubber, or its throw is still running: the video holds still meanwhile. Set through
    /// `setScrubbing(_:video:)` by the scrubber of the video on top.
    private(set) var isScrubbing = false {
        didSet { applyPlayback() }
    }
    /// The card can be seen: not covered, not under the pool or the settings.
    var isVisible = false {
        didSet { applyPlayback() }
    }

    @ObservationIgnored private var hdr = true
    @ObservationIgnored private var looper: AVPlayerLooper?
    @ObservationIgnored private var current: ItemLoad?
    @ObservationIgnored private var prepared: ItemLoad?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var failureObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var isSeeking = false
    @ObservationIgnored private var pendingSeek: (seconds: Double, precise: Bool)?
    /// Where the same video goes on from after its item was made anew (the HDR switch): seeked to once ready.
    @ObservationIgnored private var resumeTime: Double?
    /// An interruption (a call, another app's audio) paused a playing video: it plays again by itself if the
    /// system says so when the interruption ends. There may be no end to it, so the button shows the pause now.
    @ObservationIgnored private var resumesAfterInterruption = false
    @ObservationIgnored private var isApplyingSound = false
    @ObservationIgnored private let audio = AudioSessionController()

    /// Lives as long as the app.
    init() {
        attach(player)
        audio.onInterruption = { [weak self] interruption in
            guard let self else { return }
            switch interruption {
            case .began:
                if wantsPlaying {
                    wantsPlaying = false
                    resumesAfterInterruption = true
                }
            case .ended(let resumes):
                if resumes, resumesAfterInterruption { wantsPlaying = true }
                resumesAfterInterruption = false
            }
        }
        audio.onRouteLost = { [weak self] in
            // Headphones unplugged: a video heard through them pauses, as music does.
            if self?.soundOn == true { self?.wantsPlaying = false }
        }
        audio.onMediaServicesReset = { [weak self] in self?.rebuildPlayer() }
    }

    /// The player's settings and its time observer, for the one made at the start and any made after a reset.
    private func attach(_ player: AVQueuePlayer) {
        player.isMuted = !soundOn
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.actionAtItemEnd = .advance
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            // On the main queue by request, so the main actor's state may be touched here.
            MainActor.assumeIsolated { self?.report(time) }
        }
    }

    /// The media services were reset (rare): players made before it are dead. A new one takes over, and the
    /// video on top is loaded into it afresh.
    private func rebuildPlayer() {
        Log.media.notice("media services were reset: the player is made anew")
        // What is on top, taken before the teardown lets go of its load.
        let onTop = videoID.flatMap { id in current.map { (id: id, asset: $0.asset, version: videoVersion) } }
        tearDown()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player = AVQueuePlayer()
        attach(player)
        guard let onTop else {
            status = .idle
            return
        }
        videoID = nil
        show(onTop.id, asset: onTop.asset, version: onTop.version, hdr: hdr)
    }

    // MARK: Which video

    /// The video on top changed (nil: no video on top), or the one on top has a new version (edited in Photos),
    /// or the HDR choice changed. Its item is taken from the one prepared ahead when it is that video; otherwise
    /// it is fetched now. The user's choices start over, except across the HDR switch for the same video, which
    /// goes on from where it was.
    func show(_ id: String?, asset: PHAsset?, version: Date?, hdr: Bool) {
        guard id != videoID || version != videoVersion || hdr != self.hdr else { return }
        let carriesOn = id != nil && id == videoID && version == videoVersion
        let carried = (time: time, playing: wantsPlaying)
        tearDown()
        videoID = id
        videoVersion = version
        self.hdr = hdr
        resumesAfterInterruption = false
        isScrubbing = false
        if carriesOn {
            resumeTime = carried.time
            wantsPlaying = carried.playing
        } else {
            wantsPlaying = true
            if soundOn { soundOn = false }
        }
        guard let id, let asset else {
            status = .idle
            return
        }
        status = .loading
        let load: ItemLoad
        if let prepared, prepared.id == id, prepared.version == version, prepared.hdr == hdr {
            // Readied ahead; a readying that failed is tried afresh, in case the fault was a passing one.
            self.prepared = nil
            load = prepared.hasFailed ? ItemLoad(id: id, asset: asset, version: version, hdr: hdr) : prepared
        } else {
            load = ItemLoad(id: id, asset: asset, version: version, hdr: hdr)
        }
        current = load
        Task { [weak self] in
            await load.wait()
            guard let self, self.current === load else { return }
            if let loaded = load.loaded {
                self.install(loaded)
            } else if !load.isCancelled {
                self.status = .failed
            }
        }
    }

    /// Fetches and readies the next video's item ahead of its turn, so it starts the moment it comes on top.
    func prepare(next id: String?, asset: PHAsset?, version: Date?, hdr: Bool) {
        if let prepared, prepared.id == id, prepared.version == version, prepared.hdr == hdr { return }
        prepared?.cancel()
        prepared = nil
        guard let id, let asset, id != videoID else { return }
        prepared = ItemLoad(id: id, asset: asset, version: version, hdr: hdr)
    }

    /// Fetches the video on top again, after a failure.
    func retry() {
        guard let id = videoID, let asset = current?.asset else { return }
        let hdr = self.hdr
        let version = videoVersion
        videoID = nil
        show(id, asset: asset, version: version, hdr: hdr)
    }

    private func install(_ loaded: ItemLoad.Loaded) {
        Log.media.info("video \(self.videoID ?? "?", privacy: .public) ready, \(loaded.duration, privacy: .public) s")
        duration = loaded.duration
        time = resumeTime ?? 0
        if let resumeTime {
            // The same video made anew: back to where it was, once the item can be seeked.
            pendingSeek = (resumeTime, true)
            self.resumeTime = nil
        }
        let looper = AVPlayerLooper(player: player, templateItem: loaded.item)
        self.looper = looper
        status = .ready
        // The handlers run wherever AVFoundation changed the value: only the new value crosses to the main actor.
        observations = [
            // Seeks wait for the item to be ready (one in the player's queue is a copy the looper made; its
            // readiness is its own): asked of an item that is not, a seek with a completion handler raises.
            player.observe(\.currentItem?.status, options: [.new]) { [weak self] _, change in
                guard change.newValue == .readyToPlay else { return }
                Task { @MainActor [weak self] in self?.runSeeks() }
            },
            looper.observe(\.status, options: [.new]) { [weak self] _, change in
                guard change.newValue == .failed else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.looper === looper else { return }
                    Log.media.error("video looper failed: \(self.looper?.error?.localizedDescription ?? "no error", privacy: .public)")
                    self.status = .failed
                }
            },
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, change in
                let waiting = change.newValue == .waitingToPlayAtSpecifiedRate
                Task { @MainActor [weak self] in
                    guard let self, self.status == .ready || self.status == .buffering else { return }
                    self.status = waiting ? .buffering : .ready
                }
            },
        ]
        failureObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            // Only what is needed crosses to the main actor: which item, and what went wrong.
            let error = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
            let failedItem = (notification.object as? AVPlayerItem).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let failedItem, self.player.items().contains(where: { ObjectIdentifier($0) == failedItem }) else { return }
                Log.media.error("video failed to play to its end: \(error ?? "no error", privacy: .public)")
                self.status = .failed
            }
        }
        applyPlayback()
    }

    private func tearDown() {
        current?.cancel()
        current = nil
        pendingSeek = nil
        resumeTime = nil
        player.pause()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        observations = []
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        failureObserver = nil
        time = 0
        duration = 0
    }

    // MARK: Playing

    private var shouldPlay: Bool {
        looper != nil && status != .failed && isVisible && wantsPlaying && !isScrubbing
    }

    private func applyPlayback() {
        if shouldPlay {
            if player.rate == 0 {
                Log.media.info("video \(self.videoID ?? "?", privacy: .public) plays")
                player.play()
            }
        } else if player.rate != 0 {
            player.pause()
        }
    }

    private func applySound() {
        isApplyingSound = true
        defer { isApplyingSound = false }
        // The session cannot be given back while audio runs: the player pauses around the switch.
        let wasPlaying = player.rate != 0
        if wasPlaying { player.pause() }
        // Not taken (a call holds the audio): the switch goes back and the picture stays silent, rather than
        // sound under the ambient session, silenced by the ring switch and mixed into whatever else plays.
        if soundOn, !audio.setSoundOn(true) { soundOn = false }
        if !soundOn { audio.setSoundOn(false) }
        player.isMuted = !soundOn
        if wasPlaying { applyPlayback() }
    }

    private func report(_ time: CMTime) {
        // An indefinite or invalid time (between items, mid-seek) has no seconds to show.
        guard duration > 0, time.isNumeric else { return }
        let seconds = min(max(time.seconds, 0), duration)
        if self.time != seconds { self.time = seconds }
    }

    /// Jumps to `seconds` into the video. While a finger scrubs, seeks come faster than frames can be decoded, and
    /// every new seek cancels the one before it, so the picture could freeze: one seek runs at a time, to the
    /// nearest frame or so, and the latest target asked for in the meantime follows it. A `precise` seek, on
    /// release, lands exactly. From the scrubber of `video`: a scrubber on its way out (its video swiped away)
    /// must not move the next one.
    func seek(to seconds: Double, precise: Bool = false, video id: String) {
        guard id == videoID, duration > 0, status != .failed else { return }
        pendingSeek = (min(max(seconds, 0), duration), precise)
        runSeeks()
    }

    /// Runs the seeks waiting, one at a time, while the item can take them; a seek that must wait for the item
    /// to be ready is run by the readiness observer.
    private func runSeeks() {
        guard !isSeeking, pendingSeek != nil, status != .failed, player.currentItem?.status == .readyToPlay else { return }
        isSeeking = true
        Task { [weak self] in
            while let self, let next = self.pendingSeek, self.player.currentItem?.status == .readyToPlay {
                self.pendingSeek = nil
                let tolerance = next.precise ? CMTime.zero : CMTime(value: 1, timescale: 30)
                await self.player.seek(to: CMTime(seconds: next.seconds, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance)
            }
            self?.isSeeking = false
        }
    }

    /// The scrubber of `video` has a finger on it (or its throw runs), or has let go.
    func setScrubbing(_ scrubbing: Bool, video id: String) {
        guard id == videoID else { return }
        isScrubbing = scrubbing
    }
}

/// One video's item on its way: fetched from PhotoKit, given its standard-range composition when HDR is off, and
/// its length read, all ahead of the moment it is needed.
@MainActor
final class ItemLoad {
    struct Loaded {
        let item: AVPlayerItem
        let duration: Double
    }

    let id: String
    let asset: PHAsset
    let version: Date?
    let hdr: Bool
    private(set) var loaded: Loaded?
    private(set) var isCancelled = false
    /// The readying ended without an item, and not by cancellation.
    private(set) var hasFailed = false
    private let request = PlayerItemRequest()
    private var task: Task<Void, Never>?

    init(id: String, asset: PHAsset, version: Date?, hdr: Bool) {
        self.id = id
        self.asset = asset
        self.version = version
        self.hdr = hdr
        let request = self.request
        task = Task { [weak self] in
            let loaded = await Self.ready(asset: asset, hdr: hdr, request: request)
            guard let self else { return }
            if let loaded {
                self.loaded = loaded
            } else if !self.isCancelled {
                self.hasFailed = true
            }
        }
    }

    /// The item fetched and readied, or nil when it could not be (or the wait was cancelled).
    private static func ready(asset: PHAsset, hdr: Bool, request: PlayerItemRequest) async -> Loaded? {
        guard let item = await request.item(for: asset) else { return nil }
        // PhotoKit's own composition (an edited video's crop, filter or trim) stands: replaced, the edits would
        // play unmade. Such a video plays in its own range whatever the HDR switch says.
        if !hdr, item.videoComposition == nil {
            // Read ahead and off the main thread: the tracks of a video still in iCloud would stall it.
            item.videoComposition = await standardRangeComposition(for: item.asset)
        }
        guard let duration = try? await item.asset.load(.duration), duration.seconds.isFinite, duration.seconds > 0,
              (try? await item.asset.load(.isPlayable)) == true else {
            if !Task.isCancelled { Log.media.error("video is not playable or has no length") }
            return nil
        }
        return Loaded(item: item, duration: duration.seconds)
    }

    func wait() async {
        await task?.value
    }

    func cancel() {
        isCancelled = true
        task?.cancel()
        request.cancel()
    }

    /// A pass-through composition that asks for standard-range output, so an HDR video is tone-mapped down.
    private static func standardRangeComposition(for asset: AVAsset) async -> AVVideoComposition? {
        guard var configuration = try? await AVVideoComposition.Configuration(for: asset) else { return nil }
        configuration.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        configuration.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        configuration.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        return AVVideoComposition(configuration: configuration)
    }
}

/// PhotoKit's player item request as one async call: the item, or nil when it failed or was cancelled. PhotoKit may
/// call back before the request method returns, or more than once (progress), so a lock gates the continuation.
private final class PlayerItemRequest: Sendable {
    private struct State {
        var continuation: CheckedContinuation<AVPlayerItem?, Never>?
        var requestID: PHImageRequestID?
        var isDone = false
        var isCancelled = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    @MainActor
    func item(for asset: PHAsset) async -> AVPlayerItem? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let proceed = state.withLock { state -> Bool in
                    guard !state.isDone, !state.isCancelled else { return false }
                    state.continuation = continuation
                    return true
                }
                guard proceed else {
                    continuation.resume(returning: nil)
                    return
                }
                let options = PHVideoRequestOptions()
                options.isNetworkAccessAllowed = true
                options.deliveryMode = .automatic
                let requestID = PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { @Sendable [state] item, info in
                    if (info?[PHImageCancelledKey] as? Bool) != true, let error = info?[PHImageErrorKey] as? NSError {
                        Log.media.error("video item request failed: \(error, privacy: .public)")
                    }
                    let continuation = state.withLock { state -> CheckedContinuation<AVPlayerItem?, Never>? in
                        guard !state.isDone else { return nil }
                        state.isDone = true
                        defer { state.continuation = nil }
                        return state.continuation
                    }
                    continuation?.resume(returning: item)
                }
                let cancelNow = state.withLock { state -> Bool in
                    state.requestID = requestID
                    return state.isCancelled
                }
                if cancelNow { PHImageManager.default().cancelImageRequest(requestID) }
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        let (continuation, requestID) = state.withLock { state -> (CheckedContinuation<AVPlayerItem?, Never>?, PHImageRequestID?) in
            state.isCancelled = true
            guard !state.isDone else { return (nil, nil) }
            state.isDone = true
            defer { state.continuation = nil }
            return (state.continuation, state.requestID)
        }
        continuation?.resume(returning: nil)
        if let requestID { PHImageManager.default().cancelImageRequest(requestID) }
    }
}
