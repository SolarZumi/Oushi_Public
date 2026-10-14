// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import AVFoundation
import SwiftUI
import UIKit

/// A photo card as one UIKit view: the card ground with its corners and edge, the photo, the video playing over it,
/// and the cover that hides it out of the foreground. One view, so that when the phone turns, the card and all
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
        view.setCardSize(size)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PhotoCardView, context: Context) -> CGSize? {
        size
    }

    static func dismantleUIView(_ view: PhotoCardView, coordinator: ()) {
        view.setPlayer(nil)
    }
}

final class PhotoCardView: UIView {
    /// The card itself, centered in this view and eased to each new size; everything else is inside it.
    private let card = UIView()
    private let imageView = UIImageView()
    private var playerView: PlayerLayerView?
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
