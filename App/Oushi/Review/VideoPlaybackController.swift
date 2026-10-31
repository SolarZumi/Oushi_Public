// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import AVFoundation
import Observation
import Photos
import os

/// The deck's videos, each card with a player of its own, so a video behaves as a thing on the card rather than a
/// picture lent to whichever card is on top: the card coming up holds its video on its first frame; on top it
/// plays; swiped away it plays on, silent, until it has left the screen, where its player goes. Only the
/// video on top is remembered: one that comes back on top (undo) starts over from its first frame.
///
/// The deck view reports the video cards on screen and what each is (`update`), and whether the deck can be seen.
/// The controls and the scrubber act on the video on top, through the properties below that stand for it.
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

    /// What a video card is to the deck right now.
    enum Role: Equatable {
        /// On top: plays while it can be seen and the user wants it to; the controls are its.
        case top
        /// Under the top card, coming up: loaded and held on the frame it will start from.
        case next
        /// Put back under the card undo is bringing back, on its way to the next card's place: held where it
        /// stands until it is there, so nothing about it changes while it can still be seen.
        case yielding
        /// Swiped away and still on screen: plays on until it is gone, but silent: the swipe says the user is done
        /// with it, and so with its sound.
        case leaving
    }

    /// One video card on the screen.
    struct Card {
        let id: String
        let asset: PHAsset
        let role: Role
    }

    /// The video on top, which the controls and the scrubber act on.
    private(set) var videoID: String?
    /// The videos with players: the ones on screen.
    private(set) var sessions: [String: VideoSession] = [:]
    /// The deck can be seen: not covered, not under the pool or the settings.
    var isVisible = false {
        didSet { applyAll() }
    }

    private var top: VideoSession? { videoID.flatMap { sessions[$0] } }

    // The video on top, for the controls and the scrubber.

    var status: Status { top?.status ?? .idle }
    var time: Double { top?.time ?? 0 }
    var duration: Double { top?.duration ?? 0 }
    var isScrubbing: Bool { top?.isScrubbing ?? false }

    var wantsPlaying: Bool {
        get { top?.wantsPlaying ?? true }
        set {
            guard let top else { return }
            // Pressed either way, the button is the user's word: an interruption's resumption is no longer owed.
            resumesAfterInterruption = false
            top.wantsPlaying = newValue
            apply(top)
        }
    }

    /// One switch for every video: turned on for one, the videos after it are heard too, so someone who wants the
    /// sound need not ask for it video after video. It is not kept: the app starts silent.
    var soundOn: Bool {
        get { isSoundWanted }
        set {
            guard isSoundWanted != newValue else { return }
            isSoundWanted = newValue
            soundChanged(silencing: newValue ? nil : top)
        }
    }
    private var isSoundWanted = false

    /// The items of the videos coming up after the next card, readying ahead of their turn.
    @ObservationIgnored private var prepared: [String: ItemLoad] = [:]
    @ObservationIgnored private var hdr = true
    /// An interruption (a call, another app's audio) paused the video on top: it plays again by itself if the
    /// system says so when the interruption ends. There may be no end to it, so the button shows the pause now.
    @ObservationIgnored private var resumesAfterInterruption = false
    /// Bumped by each change of sound, so the session's answer to an earlier one is not applied over a later one.
    @ObservationIgnored private var soundChange = 0
    /// The audio session is the playback one: some video's sound is heard.
    @ObservationIgnored private var isSoundHeard = false
    @ObservationIgnored private let audio = AudioSessionController()

    /// Lives as long as the app.
    init() {
        audio.onInterruption = { [weak self] interruption in
            guard let self else { return }
            switch interruption {
            case .began:
                if let top = self.top, top.wantsPlaying {
                    top.wantsPlaying = false
                    self.resumesAfterInterruption = true
                }
                for session in self.sessions.values where session.role == .leaving { session.wantsPlaying = false }
                self.applyAll()
            case .ended(let resumes):
                if resumes, self.resumesAfterInterruption, let top = self.top { top.wantsPlaying = true }
                self.resumesAfterInterruption = false
                self.applyAll()
            }
        }
        audio.onRouteLost = { [weak self] in
            // Headphones unplugged: the video heard through them, the one on top, pauses, as music does.
            guard let self, self.isSoundWanted, let top = self.top else { return }
            top.wantsPlaying = false
            self.apply(top)
        }
        audio.onMediaServicesReset = { [weak self] in self?.rebuildPlayers() }
    }

    // MARK: Which videos

    /// The video cards on screen and what each is now, the videos coming up after them, and the HDR choice. A card
    /// keeps its video's player as it goes from coming up to on top to leaving; a video off the screen lets go of
    /// its player.
    func update(cards: [Card], upcoming: [(id: String, asset: PHAsset)], hdr: Bool) {
        self.hdr = hdr
        let onScreen = Set(cards.map(\.id))
        for (id, session) in sessions where !onScreen.contains(id) {
            sessions[id] = nil
            session.tearDown()
        }
        for card in cards {
            let session = sessionShowing(card)
            let was = session.role
            session.role = card.role
            if card.role == .top, was != .top {
                // Come on top: it plays. Back on top after it left (undo), it is not remembered: from the start.
                if was == .leaving { session.startOver() }
                session.wantsPlaying = true
                resumesAfterInterruption = false
            } else if card.role == .next, was == .top || was == .yielding {
                // In the next card's place, out of sight: back on its first frame for its next turn. (On top again
                // before it got there, it was never put back, and goes on from where it stood.)
                session.startOver()
            }
        }
        videoID = cards.first { $0.role == .top }?.id
        prepare(upcoming.filter { sessions[$0.id] == nil })
        applyAll()
        soundChanged(silencing: nil)
    }

    /// The session for a card's video: the one it already has, made anew in place when the video was edited in
    /// Photos or the HDR choice changed (going on from where it was), or a new one from the item readied ahead.
    private func sessionShowing(_ card: Card) -> VideoSession {
        let version = card.asset.modificationDate
        if let session = sessions[card.id] {
            guard session.version != version || session.hdr != hdr else { return session }
            let remade = makeSession(card.id, asset: card.asset, startingAt: session.time)
            remade.wantsPlaying = session.wantsPlaying
            remade.role = session.role
            session.tearDown()
            sessions[card.id] = remade
            return remade
        }
        let session = makeSession(card.id, asset: card.asset, startingAt: 0)
        sessions[card.id] = session
        return session
    }

    private func makeSession(_ id: String, asset: PHAsset, startingAt start: Double) -> VideoSession {
        let version = asset.modificationDate
        let load: ItemLoad
        if let ready = prepared.removeValue(forKey: id), ready.version == version, ready.hdr == hdr, !ready.hasFailed {
            load = ready
        } else {
            load = ItemLoad(id: id, asset: asset, version: version, hdr: hdr)
        }
        return VideoSession(id: id, asset: asset, load: load, startTime: start) { [weak self] session in
            self?.apply(session)
        }
    }

    /// Readies the items of the videos coming up after the next card, and lets go of ones no longer coming.
    private func prepare(_ upcoming: [(id: String, asset: PHAsset)]) {
        let wanted = Set(upcoming.map(\.id))
        for (id, load) in prepared where !wanted.contains(id) {
            load.cancel()
            prepared[id] = nil
        }
        for video in upcoming {
            let version = video.asset.modificationDate
            if let load = prepared[video.id], load.version == version, load.hdr == hdr { continue }
            prepared[video.id]?.cancel()
            prepared[video.id] = ItemLoad(id: video.id, asset: video.asset, version: version, hdr: hdr)
        }
    }

    /// The player a card shows: its video's.
    func player(for id: String) -> AVPlayer? {
        sessions[id]?.player
    }

    func status(of id: String) -> Status {
        sessions[id]?.status ?? .idle
    }

    /// Fetches the video on top again, after a failure.
    func retry() {
        guard let top, let id = videoID else { return }
        let remade = makeSession(id, asset: top.asset, startingAt: 0)
        remade.role = top.role
        top.tearDown()
        sessions[id] = remade
        apply(remade)
    }

    /// The media services were reset (rare): players made before it are dead. Each video gets a new one, from
    /// where it was.
    private func rebuildPlayers() {
        Log.media.notice("media services were reset: the players are made anew")
        for (id, session) in sessions {
            let remade = makeSession(id, asset: session.asset, startingAt: session.time)
            remade.role = session.role
            remade.wantsPlaying = session.wantsPlaying
            session.tearDown()
            sessions[id] = remade
        }
        applyAll()
        soundChanged(silencing: nil)
    }

    // MARK: Playing

    private func applyAll() {
        for session in sessions.values { apply(session) }
    }

    private func apply(_ session: VideoSession) {
        let plays: Bool
        switch session.role {
        case .top: plays = isVisible && session.wantsPlaying && !session.isScrubbing
        // Plays on as it was as it leaves; still visible, until the deck is covered.
        case .leaving: plays = isVisible && session.wantsPlaying
        case .next, .yielding, nil: plays = false
        }
        session.setPlaying(plays)
        // Only the video on top is heard: one swiped away falls silent at once.
        session.player.isMuted = !(isSoundHeard && isSoundWanted && session.role == .top)
    }

    /// Takes the playback session while the sound is on and a video is on screen, and gives it back otherwise. The
    /// session's calls run off the main thread (`AudioSessionController`), so neither a tap on the sound button
    /// nor a card leaving waits for them; a sound turned off is silent at once, one turned on is heard once the
    /// session is taken. A video the user silences while it alone plays holds still until the session is given
    /// back, which cannot happen while its audio runs.
    private func soundChanged(silencing silenced: VideoSession?) {
        let wanted = isSoundWanted && sessions.values.contains { $0.role != nil }
        guard wanted != isSoundHeard || silenced != nil else {
            // Heard already (the video before it): this one's is heard at once.
            applyAll()
            return
        }
        soundChange += 1
        let change = soundChange
        if !wanted {
            isSoundHeard = false
            for session in sessions.values { session.player.isMuted = true }
        }
        let holds = !wanted && silenced?.isPlaying == true && !sessions.values.contains { $0 !== silenced && $0.isPlaying }
        if holds { silenced?.isHeldForSound = true }
        Task { [weak self] in
            guard let self else { return }
            let on = await self.audio.setSoundOn(wanted)
            guard change == self.soundChange else { return }
            if wanted, !on {
                // Not taken (a call holds the audio): the switch goes back and the pictures stay silent, rather
                // than sound under the ambient session, silenced by the ring switch and mixed into whatever plays.
                self.isSoundWanted = false
            }
            self.isSoundHeard = wanted && on
            silenced?.isHeldForSound = false
            self.applyAll()
        }
    }

    // MARK: The scrubber

    /// Jumps the video on top to `seconds`; from the scrubber of `video`: a scrubber on its way out (its video
    /// swiped away) must not move the next one.
    func seek(to seconds: Double, precise: Bool = false, video id: String) {
        guard id == videoID else { return }
        top?.seek(to: seconds, precise: precise)
    }

    /// The scrubber of `video` has a finger on it (or its throw runs), or has let go.
    func setScrubbing(_ scrubbing: Bool, video id: String) {
        guard id == videoID, let top else { return }
        top.isScrubbing = scrubbing
        apply(top)
    }
}

/// One video with its own player: the item loading, then playing in a loop on the card that shows it, with what
/// the user asked of it and where it stands.
@MainActor
@Observable
final class VideoSession {
    let id: String
    let asset: PHAsset
    var version: Date? { load.version }
    var hdr: Bool { load.hdr }
    let player = AVQueuePlayer()

    /// What the card is to the deck; nil only until the deck has said.
    var role: VideoPlaybackController.Role?
    private(set) var status: VideoPlaybackController.Status = .loading
    /// Seconds into the video, as the player reports it, and its length.
    private(set) var time: Double
    private(set) var duration: Double = 0
    /// The user's choice for this video: played or paused. (The sound is one switch for all, the controller's.)
    var wantsPlaying = true
    /// A finger is on the scrubber, or its throw is still running: the video holds still meanwhile.
    var isScrubbing = false
    /// Holds still while the audio session is given back.
    var isHeldForSound = false {
        didSet { if isHeldForSound != oldValue { changed(self) } }
    }

    @ObservationIgnored private let load: ItemLoad
    @ObservationIgnored private let changed: (VideoSession) -> Void
    @ObservationIgnored private var looper: AVPlayerLooper?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var failureObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var isSeeking = false
    @ObservationIgnored private var pendingSeek: (seconds: Double, precise: Bool)?
    @ObservationIgnored private var wantsToPlay = false
    @ObservationIgnored private var isTornDown = false

    var isPlaying: Bool { player.rate != 0 }

    init(id: String, asset: PHAsset, load: ItemLoad, startTime: Double, changed: @escaping (VideoSession) -> Void) {
        self.id = id
        self.asset = asset
        self.load = load
        self.time = startTime
        self.changed = changed
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.actionAtItemEnd = .advance
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            // On the main queue by request, so the main actor's state may be touched here.
            MainActor.assumeIsolated { self?.report(time) }
        }
        if startTime > 0 { pendingSeek = (startTime, true) }
        Task { [weak self] in
            await load.wait()
            guard let self, !self.isTornDown else { return }
            if let loaded = load.loaded {
                self.install(loaded)
            } else if !load.isCancelled {
                self.status = .failed
                self.changed(self)
            }
        }
    }

    private func install(_ loaded: ItemLoad.Loaded) {
        Log.media.info("video \(self.id, privacy: .public) ready, \(loaded.duration, privacy: .public) s")
        duration = loaded.duration
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
                    self.changed(self)
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
                self.changed(self)
            }
        }
        runSeeks()
        changed(self)
    }

    /// Back to the first frame, as a video coming up has it: nothing about where it was is kept.
    func startOver() {
        isScrubbing = false
        seek(to: 0, precise: true)
    }

    /// Plays or holds still, as its card's place in the deck and the user's choices say.
    func setPlaying(_ plays: Bool) {
        wantsToPlay = plays
        let playing = plays && looper != nil && status != .failed && !isHeldForSound
        if playing {
            if player.rate == 0 { player.play() }
        } else if player.rate != 0 {
            player.pause()
        }
    }

    func tearDown() {
        isTornDown = true
        load.cancel()
        player.pause()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        observations = []
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        failureObserver = nil
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
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
    /// release, lands exactly.
    func seek(to seconds: Double, precise: Bool) {
        guard duration > 0, status != .failed else { return }
        pendingSeek = (min(max(seconds, 0), duration), precise)
        runSeeks()
    }

    /// Runs the seeks waiting, one at a time, while the item can take them; a seek that must wait for the item to
    /// be ready (the start a video comes back to) is run by the readiness observer.
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
