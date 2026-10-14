// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import Photos
import SwiftUI

/// Draws the card stack described by `CardDeck` and feeds it the drag.
struct CardDeckView<Summary: View>: View {
    let deck: CardDeck
    /// Where the bars' parts are, for the welcome's halo to pulse out of the capsule.
    let layout: ReviewLayout
    /// The area the cards are laid out in, from the screen's own GeometryReader.
    let room: CGSize
    let summary: Summary

    /// A photo the pool overlay is showing in the deck's place, so the deck does not draw it twice.
    var hiddenPhotoID: String? = nil
    /// Something covers the deck (the pool, the settings): a video on top pauses rather than play on unseen.
    var isObscured = false
    /// The pool overlay is standing in for the system card on top (with a copy of it), so there is one card on screen.
    var hidesSystemCards = false

    @Environment(AppSettings.self) private var settings
    /// The video card whose controls (the scrubber) are hidden by a tap on it; the next video shows them again.
    @State private var hiddenControlsID: String?
    /// The app's one player: the video on top, the next one loading ahead, and what the user asked of it.
    @Environment(VideoPlaybackController.self) private var playback

    @Environment(PhotoLibrary.self) private var library
    @Environment(PhotoImageLoader.self) private var images
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @Environment(\.cardsCovered) private var isCovered
    @GestureState private var isDragging = false
    /// The finger's travel when the drag was recognized; translations are reported from there.
    @State private var dragOrigin: CGSize?
    /// Retries asked for on photos that failed to load, by photo, and the photos whose load has failed.
    @State private var retries: [String: Int] = [:]
    @State private var failedLoads: Set<String> = []
    /// The deck is on screen: the lessons' demos run only while it is, and not under the pool or the settings.
    @State private var isOnScreen = false
    /// Where the room is on screen, for the capsule's place to be known in the room's coordinates.
    @State private var roomOrigin: CGPoint = .zero

    init(deck: CardDeck, layout: ReviewLayout, room: CGSize, summary: Summary, hiddenPhotoID: String? = nil, isObscured: Bool = false, hidesSystemCards: Bool = false) {
        self.deck = deck
        self.layout = layout
        self.room = room
        self.summary = summary
        self.hiddenPhotoID = hiddenPhotoID
        self.isObscured = isObscured
        self.hidesSystemCards = hidesSystemCards
    }

    var body: some View {
        // The deck's room is handed down, never measured off the cards: a stack would size itself to its cards,
        // the cards are sized from the room, and the two would hold each other at whatever size they had when
        // the phone was turned. Each photo card eases itself to a new size (see PhotoCard), so the room can be
        // taken at once, in whatever layout pass it comes.
        ZStack {
            ForEach(deck.cards) { card in
                cardView(card)
                    // The card on top says where it is, for the pool to grow out of and shrink back to.
                    .anchorPreference(key: TopCardAnchor.self, value: .bounds) { card.role == .top ? $0 : nil }
                    .transition(deck.insertionTransition(for: card.item))
            }
            if deck.phase.isWelcome {
                // Comes into focus after the last lesson's card has gone, and goes out of focus on 开始使用. While
                // it stands, a halo pulses out of the capsule below, so the eye is led to the one thing to do.
                let shown = deck.phase.isWelcomeShown
                welcomeWords
                    .blur(radius: shown || reduceMotion ? 0 : 14)
                    .opacity(shown ? 1 : 0)
                    .accessibilityHidden(!shown)
                if shown, !reduceMotion, layout.capsuleFrame != .zero {
                    WelcomePulse(frame: layout.capsuleFrame.offsetBy(dx: -roomOrigin.x, dy: -roomOrigin.y))
                        .transition(.opacity)
                }
            }
        }
        .frame(width: room.width, height: room.height)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { roomOrigin = $0.origin }
        // The one drag gesture, on the room, which covers the cards: a finger on a card or beside it is the same
        // drag. The cards attach no gesture of their own; a thin, tall or wide photo leaves little card to hold.
        .overlay(alignment: .bottom) {
            // The controls of the video on top, at the bottom of the room as Photos keeps them under the
            // video, whatever its shape. A tap on the card hides them, for this card.
            if let id = deck.currentID, isVideo(id), hiddenControlsID != id {
                VideoScrubber(playback: playback, videoID: id, width: room.width)
                    // One scrubber per video: a throw still running when the card is swiped away must not go on
                    // seeking the next video.
                    .id(id)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.2), value: hiddenControlsID)
        // The controls show when a video comes on top, long enough to say it is one, then leave the picture
        // alone. Any touch on them, or a tap bringing them back, starts the wait over; paused, they stay.
        .task(id: controlsHideKey) {
            guard let id = deck.currentID, hiddenControlsID != id, playback.wantsPlaying, !playback.isScrubbing,
                  isVideo(id) else { return }
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            hiddenControlsID = id
        }
        // The player follows the deck: the video on top is shown, the next one readied, and the picture plays
        // only while the card can be seen.
        .onChange(of: videoKey, initial: true) { _, key in
            let current = key.current.flatMap(library.asset(for:))
            let next = key.next.flatMap(library.asset(for:))
            playback.show(key.current, asset: current, version: current?.modificationDate, hdr: key.hdr)
            playback.prepare(next: key.next, asset: next, version: next?.modificationDate, hdr: key.hdr)
        }
        .onChange(of: isVideoVisible, initial: true) { _, visible in playback.isVisible = visible }
        .contentShape(.rect)
        .gesture(swipe)
        .onChange(of: room, initial: true) { _, size in deck.size = size }
        // The deck's events as haptics, if the user wants taps: a soft one when a downward pull comes free of its
        // place or re-holds, the system's for a lesson passed or refused.
        .sensoryFeedback(trigger: deck.feedback) { _, feedback in
            guard settings.hapticsEnabled, let feedback else { return nil }
            switch feedback.kind {
            case .armed, .disarmed: return .impact(flexibility: .soft)
            case .lessonPassed: return .success
            case .lessonRefused: return .error
            }
        }
        .onChange(of: reduceMotion, initial: true) { _, value in deck.reduceMotion = value }
        .onAppear { isOnScreen = true }
        .onDisappear { isOnScreen = false }
        .onChange(of: isOnScreen && !isObscured, initial: true) { _, shown in deck.isPresented = shown }
        // The card on top changed: the controls hidden on the one before show again on the next video.
        .onChange(of: deck.currentID) { hiddenControlsID = nil }
        .onChange(of: isDragging) { _, dragging in
            // A drag the system cancels never reaches onEnded; the gesture state still resets.
            if !dragging, dragOrigin != nil {
                dragOrigin = nil
                deck.dragCancelled()
            }
        }
        .task(id: preheatKey) { preheat() }
    }

    @ViewBuilder
    private func cardView(_ card: DeckCard) -> some View {
        let style = deck.style(for: card.role)
        switch card.item {
        case .summary:
            summary
                .scaleEffect(style.scale)
                .opacity(style.opacity)
                .allowsHitTesting(card.role == .top)
                .accessibilityHidden(card.role != .top)
        case .access:
            AccessCard(status: library.authorizationStatus, bounds: room) {
                Task { await library.requestAccess() }
            }
            .scaleEffect(style.scale)
            .offset(style.offset)
            .opacity(hidesSystemCards ? 0 : style.opacity)
        case .lesson(let lesson):
            TutorialCard(lesson: lesson, bounds: room)
                .scaleEffect(style.scale)
                .offset(style.offset)
                .modifier(RefusalShake(trigger: card.role == .top && !reduceMotion ? refusal : nil))
                .opacity(hidesSystemCards ? 0 : style.opacity)
                .allowsHitTesting(card.role == .top)
                // The lessons can be passed without the drag they teach.
                .accessibilityAction(named: "保留") { deck.fling(.right, speed: 0) }
                .accessibilityAction(named: "移入待删除") { deck.fling(.down, speed: 0) }
                .accessibilityHidden(card.role != .top)
        case .photo(let photoID):
            photoCard(photoID, role: card.role, style: style)
        }
    }

    /// The last refusal of a lesson's card, for its shake.
    private var refusal: LessonMark? {
        guard let feedback = deck.feedback, case .lessonRefused(let mark) = feedback.kind else { return nil }
        return mark
    }

    private func photoCard(_ photoID: String, role: DeckCard.Role, style: CardStyle) -> some View {
        let asset = library.asset(for: photoID)
        let size = fittedPhotoSize(asset, in: room)
        let isTop = role == .top
        let isVideo = asset?.mediaType == .video
        // The deck's player shows on the card whose video it holds: the one on top.
        let playsHere = isTop && isVideo && playback.videoID == photoID
        let loadFailed = failedLoads.contains(photoID)
        let videoFailed = playsHere && playback.status == .failed
        return PhotoLoading(id: photoID, size: size, attempt: retries[photoID, default: 0], onFailure: { failed in
            if failed { failedLoads.insert(photoID) } else { failedLoads.remove(photoID) }
        }) { image, failed in
            PhotoCard(
                image: image,
                size: size,
                cornerRadius: CardShape.photoCornerRadius,
                isCovered: isCovered,
                isHDR: settings.photoHDR,
                player: playsHere ? playback.player : nil
            )
            .overlay {
                // A failure over the quick preview too: the preview is not the photo, and is all there would be.
                if failed {
                    loadingFailure(String(localized: "暂时无法载入照片")) { retries[photoID, default: 0] += 1 }
                } else if videoFailed {
                    loadingFailure(String(localized: "暂时无法载入视频")) { playback.retry() }
                } else if image == nil || (playsHere && (playback.status == .loading || playback.status == .buffering)) {
                    ProgressView()
                        .controlSize(playsHere ? .large : .regular)
                        .tint(image == nil ? nil : .white)
                }
            }
        }
        .frame(width: size.width, height: size.height)
            // No tap gesture here: a tap gesture holds the room's drag back while it waits to fail, and the wait
            // shows as the card standing still, then jumping to the finger. The drag itself reports a tap.
            .contentShape(.rect)
            .scaleEffect(style.scale)
            .offset(style.offset)
            .opacity(photoID == hiddenPhotoID ? 0 : style.opacity)
            .allowsHitTesting(isTop)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(asset?.accessibilityName ?? String(localized: "照片"))
            // The failure and its retry are inside the combined element: said here, and offered as an action.
            .accessibilityValue(loadFailed ? String(localized: "暂时无法载入照片") : videoFailed ? String(localized: "暂时无法载入视频") : "")
            .accessibilityHint("左右滑动保留，下滑移入待删除")
            .accessibilityAction(named: "保留") { deck.fling(.right, speed: 0) }
            .accessibilityAction(named: "移入待删除") { deck.fling(.down, speed: 0) }
            // The video's controls are inside the combined element; the same choices as actions, on a video only.
            .accessibilityActions {
                if loadFailed {
                    Button("重试") { retries[photoID, default: 0] += 1 }
                } else if videoFailed {
                    Button("重试") { playback.retry() }
                }
                if isVideo, isTop {
                    Button(playback.soundOn ? "关闭声音" : "打开声音") { playback.soundOn.toggle() }
                    Button(playback.wantsPlaying ? "暂停" : "播放") { playback.wantsPlaying.toggle() }
                }
            }
            // After the element is made, so the hiding applies to it.
            .accessibilityHidden(!isTop)
    }

    private func loadingFailure(_ words: String, retry: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.icloud")
                .font(.title2)
            Text(words)
                .font(.subheadline)
            Button("重试", action: retry)
                .buttonStyle(.bordered)
        }
        .foregroundStyle(.secondary)
    }

    private func isVideo(_ id: String) -> Bool {
        library.asset(for: id)?.mediaType == .video
    }

    /// Changes after which the controls' wait to hide starts over.
    private struct ControlsHideKey: Equatable {
        var currentID: String?
        var hiddenControlsID: String?
        var wantsPlaying: Bool
        var soundOn: Bool
        var isScrubbing: Bool
    }

    private var controlsHideKey: ControlsHideKey {
        ControlsHideKey(
            currentID: deck.currentID, hiddenControlsID: hiddenControlsID,
            wantsPlaying: playback.wantsPlaying, soundOn: playback.soundOn, isScrubbing: playback.isScrubbing
        )
    }

    /// Which video is on top and which comes next, with the HDR choice; the library's revision is in it so a
    /// lookup that found nothing before the library was read is made again, and one that found an older version
    /// (the video since edited in Photos) too.
    private struct VideoKey: Equatable {
        var current: String?
        var next: String?
        var hdr: Bool
        var libraryRevision: Int
    }

    private var videoKey: VideoKey {
        VideoKey(
            current: deck.currentID.flatMap { isVideo($0) ? $0 : nil },
            next: deck.nextID.flatMap { isVideo($0) ? $0 : nil },
            hdr: settings.videoHDR,
            libraryRevision: library.changeRevision
        )
    }

    /// A video plays only while it can be seen: not covered (the app out of the foreground), not hidden under the
    /// pool, not behind the pool or the settings.
    private var isVideoVisible: Bool {
        !deck.isCovered && !isCovered && !isObscured && deck.currentID != hiddenPhotoID
    }

    /// How far the finger moves before the touch is a drag; lifted before that, it was a tap.
    private let dragThreshold: CGFloat = 10

    // MARK: Welcome

    private var welcomeWords: some View {
        Text("欢迎使用")
            .font(.title.weight(.semibold))
            .foregroundStyle(.white)
    }

    /// The deck's one gesture, the way UIKit's pan recognizer works: it takes every touch in the room from the
    /// moment it lands, waits for the finger to travel the threshold, and reports from there: a beginning
    /// carrying the travel that crossed the threshold (the axis is read from it), then translations measured
    /// from that beginning (the hysteresis), then an end with the velocity. A touch lifted before the threshold
    /// is a tap, which shows or hides a video's controls. There is no separate tap gesture: SwiftUI would hold
    /// the drag back until the tap had failed, and that wait shows as the card standing still, then jumping.
    private var swipe: some Gesture {
        // Global coordinates: the card moves under the finger, so local translations would feed back on themselves.
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .updating($isDragging) { _, state, _ in state = true }
            .onChanged { value in
                if let origin = dragOrigin {
                    deck.dragChanged(translation: CGSize(
                        width: value.translation.width - origin.width, height: value.translation.height - origin.height
                    ))
                } else if hypot(value.translation.width, value.translation.height) >= dragThreshold {
                    dragOrigin = value.translation
                    deck.dragBegan(travel: value.translation)
                }
            }
            .onEnded { value in
                if dragOrigin != nil {
                    dragOrigin = nil
                    deck.dragEnded(velocity: value.velocity)
                } else {
                    tapped()
                }
            }
    }

    /// A tap on a video card shows its controls if they are hidden, hides them if they show.
    private func tapped() {
        guard let id = deck.currentID, isVideo(id) else { return }
        hiddenControlsID = hiddenControlsID == id ? nil : id
    }

    // MARK: Preheating

    private struct PreheatKey: Equatable {
        var ids: [String]
        var room: CGSize
    }

    private var preheatKey: PreheatKey {
        PreheatKey(ids: deck.upcomingIDs, room: room)
    }

    /// Asks PhotoKit to start decoding the next photos at exactly the pixel size their cards will request.
    private func preheat() {
        let requests = deck.upcomingIDs.map { id -> (String, CGSize) in
            let size = fittedPhotoSize(library.asset(for: id), in: room)
            return (id, CGSize(width: size.width * displayScale, height: size.height * displayScale))
        }
        images.preheat(requests)
    }
}

/// A lesson's card shaking its head after refusing the wrong gesture: once the card has snapped back, five
/// jerks, shrinking, the first one's way chosen by the refusal itself.
private struct RefusalShake: ViewModifier {
    let trigger: LessonMark?

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: CGFloat(0), trigger: trigger) { view, offset in
            view.offset(x: offset)
        } keyframes: { _ in
            let first: CGFloat = if let trigger, case .refused(let firstJerk) = trigger.kind { firstJerk } else { 0 }
            KeyframeTrack {
                LinearKeyframe(0, duration: Motion.refuseSnap)
                LinearKeyframe(first * 10, duration: 0.05)
                LinearKeyframe(first * -8, duration: 0.05)
                LinearKeyframe(first * 6, duration: 0.05)
                LinearKeyframe(first * -4, duration: 0.05)
                LinearKeyframe(first * 2, duration: 0.05)
                LinearKeyframe(0, duration: 0.05)
            }
        }
    }
}

/// A halo, like the sun's, that pulses out of the progress capsule while the welcome stands: a soft light the
/// capsule's shape, spreading the same distance outward on every side (the shape grows by an even margin, and
/// its blur widens) and fading to nothing as it spreads, slowly, one every few seconds, two in flight at a time.
/// It lies outside the capsule only; the capsule itself is left alone. Each is born inside the capsule, dark,
/// and brightens as it comes out, so no light appears at once at the edge. Driven by keyframes over the whole
/// period, repeating, so every pulse runs its full course (phase-driven, a pulse was cut short mid-way).
private struct WelcomePulse: View {
    /// The capsule's frame in the room's coordinates.
    let frame: CGRect

    @State private var secondStarted = false

    /// How far beyond the capsule's edge the light reaches at the end of a pulse, how long a pulse takes, and how
    /// long it takes to come out and brighten.
    private let reach: CGFloat = 56
    private let period = 4.0
    private let rise = 0.9

    private struct Light {
        var spread: CGFloat = -10
        var blur: CGFloat = 4
        var opacity: Double = 0
    }

    var body: some View {
        ZStack {
            halo
            if secondStarted { halo }
        }
        .frame(width: frame.width, height: frame.height)
        // Outside the capsule only: the capsule's own area is cut out, so the button is not lit from behind.
        .mask {
            Rectangle()
                .frame(width: frame.width + 4 * (reach + 44), height: frame.height + 4 * (reach + 44))
                .overlay {
                    Capsule()
                        .frame(width: frame.width + 1, height: frame.height + 1)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
        }
        .position(x: frame.midX, y: frame.midY)
        .task {
            try? await Task.sleep(for: .seconds(period / 2))
            guard !Task.isCancelled else { return }
            secondStarted = true
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var halo: some View {
        KeyframeAnimator(initialValue: Light(), repeating: true) { light in
            Capsule()
                .fill(.white)
                .frame(width: frame.width + 2 * light.spread, height: frame.height + 2 * light.spread)
                .blur(radius: light.blur)
                .opacity(light.opacity)
        } keyframes: { _ in
            KeyframeTrack(\.spread) {
                CubicKeyframe(6, duration: rise)
                CubicKeyframe(reach, duration: period - rise)
            }
            KeyframeTrack(\.blur) {
                CubicKeyframe(10, duration: rise)
                CubicKeyframe(44, duration: period - rise)
            }
            KeyframeTrack(\.opacity) {
                CubicKeyframe(0.5, duration: rise)
                CubicKeyframe(0, duration: period - rise)
            }
        }
    }
}

/// Where the card on top of the deck is, as an anchor the screen resolves in whatever space it needs.
struct TopCardAnchor: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        if let next = nextValue() { value = next }
    }
}
