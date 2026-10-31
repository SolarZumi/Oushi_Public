// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import AVFoundation
import PhotosUI
import SwiftUI
import UIKit

/// A playback of a card's Live Photo asked for. Each is new: asking again plays the moment again.
struct LivePlay: Equatable {
    /// The two ways Photos plays a Live Photo: a short stir of its moment as it comes into view, silent and
    /// without a tap; or the whole of it on a press, with its sound and the system's tap as it starts.
    enum Kind: Equatable {
        case glimpse
        case whole(muted: Bool)

        var style: PHLivePhotoViewPlaybackStyle {
            self == .glimpse ? .hint : .full
        }
    }

    let token = UUID()
    let kind: Kind
}

/// A photo card as one UIKit view: the card ground with its corners and edge, the photo, the video or the Live
/// Photo's moment playing over it, the Live Photo badge, and the cover that hides it out of the foreground. One view, so that when the phone turns, the card and all
/// that is in it turn and resize as one: drawn by SwiftUI, the card's parts are layers of their own, and inside
/// UIKit's rotation animation they come apart, the ground and the photo each ending up somewhere else until the
/// turn is over.
///
/// The card eases to a new size by itself. Asked for one inside the system's rotation animation it takes that
/// animation's length, so it resizes as it turns; otherwise it resizes briskly.
struct PhotoCard: UIViewRepresentable {
    let image: UIImage?
    let size: CGSize
    let cornerRadius: CGFloat
    /// The app is leaving the foreground: the photo dissolves into blur under the ground.
    let isCovered: Bool
    /// Photos with a gain map light up in HDR when the user wants them to.
    let isHDR: Bool
    /// The deck's player, when this card's video is what it holds: its picture plays over the poster.
    var player: AVPlayer? = nil
    /// The words of the Live Photo badge, for a Live Photo; nil for any other photo.
    var liveBadge: String? = nil
    /// The Live Photo behind the photo, once loaded, on the card on top: its moment plays over the photo.
    var livePhoto: PHLivePhoto? = nil
    /// The playback asked for: a new one plays the moment through; nil stops one under way, easing back.
    var livePlay: LivePlay? = nil

    @Environment(\.displayScale) private var displayScale

    func makeUIView(context: Context) -> PhotoCardView {
        PhotoCardView()
    }

    func updateUIView(_ view: PhotoCardView, context: Context) {
        view.edgeWidth = 2 / displayScale
        view.cornerRadius = cornerRadius
        view.setImage(image, hdr: isHDR)
        view.setCovered(isCovered)
        view.setPlayer(player)
        view.setLiveBadge(liveBadge)
        view.setLivePhoto(livePhoto)
        view.setLivePlay(livePlay)
        view.setCardSize(size)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PhotoCardView, context: Context) -> CGSize? {
        size
    }

    static func dismantleUIView(_ view: PhotoCardView, coordinator: ()) {
        view.setPlayer(nil)
        view.setLivePhoto(nil)
    }
}

final class PhotoCardView: UIView {
    /// The card itself, centered in this view and eased to each new size; everything else is inside it.
    private let card = UIView()
    private let imageView = UIImageView()
    private var playerView: PlayerLayerView?
    private var liveView: PHLivePhotoView?
    private var liveBadge: LiveBadgeView?
    /// The Live Photo playback last asked for, while one is wanted.
    private var liveToken: UUID?
    /// How the playback under way plays: a press during a glimpse goes on into the whole moment.
    private var liveStyle: PHLivePhotoViewPlaybackStyle = .full
    private var isLivePlaying = false
    private var isLiveStopping = false
    /// Asked again while the last playback was easing back: it plays once that one has ended.
    private var replaysLive = false
    private let blur = UIVisualEffectView(effect: nil)
    private let cover = UIView()
    private var cardSize: CGSize = .zero
    private var isCovered = false

    var cornerRadius: CGFloat = 0 {
        didSet { card.layer.cornerRadius = cornerRadius }
    }

    var edgeWidth: CGFloat = 1 {
        didSet { card.layer.borderWidth = edgeWidth }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Touches land here and go on to the deck's drag, which SwiftUI runs; the view has no gestures of its own.
        // Were it not to take touches, SwiftUI would find nothing under the finger and the drag would not start.
        isUserInteractionEnabled = true
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerCurve = .continuous
        card.layer.borderColor = UIColor.white.withAlphaComponent(0.1).cgColor
        card.clipsToBounds = true
        addSubview(card)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        for view in [imageView, blur, cover] {
            view.frame = card.bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            card.addSubview(view)
        }
        cover.backgroundColor = .secondarySystemBackground
        cover.alpha = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        card.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    func setImage(_ image: UIImage?, hdr: Bool) {
        imageView.preferredImageDynamicRange = hdr ? .high : .standard
        if imageView.image !== image { imageView.image = image }
    }

    /// The card takes `size`: at once the first time or while off screen, otherwise eased, with the system's
    /// rotation animation when asked inside it, so the card resizes as it turns.
    func setCardSize(_ size: CGSize) {
        guard size != cardSize else { return }
        let first = cardSize == .zero
        cardSize = size
        let apply = {
            self.card.bounds.size = size
            self.card.layoutIfNeeded()
        }
        if first || window == nil {
            apply()
            return
        }
        let inherited = UIView.inheritedAnimationDuration
        UIView.animate(withDuration: inherited > 0 ? inherited : 0.35, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut], animations: apply)
    }

    /// Out of the foreground the photo dissolves into blur under the card color, and focuses again on return.
    func setCovered(_ covered: Bool) {
        guard covered != isCovered else { return }
        isCovered = covered
        let duration = covered ? 0.35 : 0.45
        UIView.animate(withDuration: duration, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut]) {
            self.blur.effect = covered ? UIBlurEffect(style: .regular) : nil
            self.cover.alpha = covered ? 1 : 0
        }
    }

    /// The Live Photo badge in the card's top left corner, where Photos puts it; under the cover, so a covered card
    /// shows nothing of its photo.
    func setLiveBadge(_ words: String?) {
        guard let words else {
            liveBadge?.removeFromSuperview()
            liveBadge = nil
            return
        }
        let badge = liveBadge ?? {
            let badge = LiveBadgeView()
            // Pinned to the top left as the card resizes.
            badge.autoresizingMask = [.flexibleRightMargin, .flexibleBottomMargin]
            card.insertSubview(badge, belowSubview: blur)
            liveBadge = badge
            return badge
        }()
        badge.words = words
        badge.frame = CGRect(origin: CGPoint(x: 12, y: 12), size: badge.intrinsicContentSize)
    }

    /// The Live Photo's own view, over the photo and hidden except while it plays: at rest the card shows its photo,
    /// with the user's HDR choice, and the moment shows only as it plays. Its own press-to-play is off; the deck's
    /// drag reports the press, so a press and a swipe never compete for the touch.
    func setLivePhoto(_ livePhoto: PHLivePhoto?) {
        guard let livePhoto else {
            liveView?.stopPlayback()
            liveView?.removeFromSuperview()
            liveView = nil
            liveToken = nil
            isLivePlaying = false
            isLiveStopping = false
            replaysLive = false
            return
        }
        let view = liveView ?? {
            let view = PHLivePhotoView(frame: card.bounds)
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.contentMode = .scaleAspectFill
            view.clipsToBounds = true
            view.isUserInteractionEnabled = false
            view.playbackGestureRecognizer.isEnabled = false
            view.alpha = 0
            view.delegate = self
            card.insertSubview(view, aboveSubview: imageView)
            liveView = view
            return view
        }()
        if view.livePhoto !== livePhoto { view.livePhoto = livePhoto }
    }

    /// Plays the moment for a new playback asked for, and stops one under way, easing back to the photo, when none
    /// is asked for any more. A playback asked for while one plays on joins it (a whole one asked during a glimpse
    /// carries the glimpse on into the whole moment); while one eases back, it plays next.
    func setLivePlay(_ play: LivePlay?) {
        guard let liveView else { return }
        guard let play else {
            liveToken = nil
            replaysLive = false
            if isLivePlaying, !isLiveStopping {
                isLiveStopping = true
                liveView.stopPlayback()
            }
            return
        }
        guard play.token != liveToken else { return }
        liveToken = play.token
        if case .whole(let muted) = play.kind { liveView.isMuted = muted }
        let style = play.kind.style
        if !isLivePlaying {
            liveStyle = style
            liveView.startPlayback(with: style)
        } else if isLiveStopping {
            liveStyle = style
            replaysLive = true
        } else if liveStyle == .hint, style == .full {
            liveStyle = style
            liveView.startPlayback(with: style)
        }
    }

    /// The deck's player plays over the poster while this card's video is the one it holds; the cards behind, and
    /// the card once its video has moved on, show the poster alone.
    func setPlayer(_ player: AVPlayer?) {
        guard let player else {
            playerView?.player = nil
            playerView?.removeFromSuperview()
            playerView = nil
            return
        }
        if playerView == nil {
            let view = PlayerLayerView()
            view.frame = card.bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            card.insertSubview(view, aboveSubview: imageView)
            playerView = view
        }
        playerView?.player = player
    }
}

extension PhotoCardView: PHLivePhotoViewDelegate {
    func livePhotoView(_ livePhotoView: PHLivePhotoView, willBeginPlaybackWith playbackStyle: PHLivePhotoViewPlaybackStyle) {
        isLivePlaying = true
        isLiveStopping = false
        livePhotoView.alpha = 1
    }

    func livePhotoView(_ livePhotoView: PHLivePhotoView, didEndPlaybackWith playbackStyle: PHLivePhotoViewPlaybackStyle) {
        isLivePlaying = false
        isLiveStopping = false
        // Back at the photo it started from: the card's own photo shows again.
        livePhotoView.alpha = 0
        if replaysLive, liveToken != nil {
            replaysLive = false
            livePhotoView.startPlayback(with: liveStyle)
        }
    }
}

/// The Live Photo badge as Photos shows it in a photo's corner: the symbol and the word, white on a small capsule
/// of dark blur. The capsule's rounded left end is centered on the symbol's ring, so the two curves run together:
/// the symbol sits as far from the capsule's top, bottom and left as the ring is round.
final class LiveBadgeView: UIView {
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let symbol = UIImageView()
    private let label = UILabel()
    /// Between the ring and the capsule's edge, above, below and to the left; and between the ring and the word.
    private let margin: CGFloat = 3
    private let gap: CGFloat = 3
    /// The ring as drawn inside the symbol's image, which carries room around it for setting in a line of text.
    private let ink: CGRect

    var words: String = "" {
        didSet {
            guard words != oldValue else { return }
            label.text = words
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }

    override init(frame: CGRect) {
        let font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .systemFont(ofSize: 12, weight: .semibold))
        let image = UIImage(systemName: "livephoto", withConfiguration: UIImage.SymbolConfiguration(font: font))
        ink = image.map(Self.inkBounds) ?? .zero
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
        layer.cornerCurve = .continuous
        blur.frame = bounds
        blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(blur)
        label.font = font
        label.textColor = .white
        symbol.image = image
        symbol.tintColor = .white
        addSubview(symbol)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The ring's side; the capsule is this plus the margin above and below, unless the word is taller.
    private var ringSide: CGFloat { max(ink.width, ink.height) }

    private var height: CGFloat {
        max(ringSide + 2 * margin, ceil(label.intrinsicContentSize.height))
    }

    override var intrinsicContentSize: CGSize {
        let end = height / 2 + ringSide / 2 + gap + label.intrinsicContentSize.width
        // The word ends as far from the right end as the ring starts from the left.
        return CGSize(width: ceil(end + (height - ringSide) / 2), height: height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let radius = bounds.height / 2
        layer.cornerRadius = radius
        // The ring's center on the left end's center: the image placed so its drawn part lands there.
        let center = CGPoint(x: radius, y: radius)
        let size = symbol.image?.size ?? .zero
        symbol.frame = CGRect(x: center.x - ink.midX, y: center.y - ink.midY, width: size.width, height: size.height)
        let text = label.intrinsicContentSize
        label.frame = CGRect(x: radius + ringSide / 2 + gap, y: (bounds.height - text.height) / 2, width: text.width, height: text.height)
    }

    /// Where a symbol image actually draws, measured from its pixels: the image's bounds include room for setting
    /// it in text, unevenly above and below, so centering the bounds does not center the glyph. Drawn into a bitmap
    /// of alpha alone, a byte a pixel, rows from the top, so the bytes read are the coverage and nothing else.
    private static func inkBounds(of image: UIImage) -> CGRect {
        let scale: CGFloat = 4
        let size = image.size
        let wide = Int(ceil(size.width * scale)), high = Int(ceil(size.height * scale))
        guard wide > 0, high > 0,
              let context = CGContext(data: nil, width: wide, height: high, bitsPerComponent: 8, bytesPerRow: wide,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
        else { return CGRect(origin: .zero, size: size) }
        // UIKit's way up: the first row in memory is the image's top.
        context.translateBy(x: 0, y: CGFloat(high))
        context.scaleBy(x: scale, y: -scale)
        UIGraphicsPushContext(context)
        image.withTintColor(.black, renderingMode: .alwaysOriginal).draw(at: .zero)
        UIGraphicsPopContext()
        guard let data = context.data else { return CGRect(origin: .zero, size: size) }
        let bytes = data.bindMemory(to: UInt8.self, capacity: wide * high)
        var minX = wide, minY = high, maxX = -1, maxY = -1
        for y in 0..<high {
            for x in 0..<wide where bytes[y * wide + x] > 32 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return CGRect(origin: .zero, size: size) }
        return CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                      width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }
}
