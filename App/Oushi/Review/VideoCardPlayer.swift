// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import AVFoundation
import UIKit

/// The surface a video card plays on: an AVPlayerLayer filling its frame, showing the card's own video's player
/// (`VideoSession`). The player itself, and everything about what it plays, is `VideoPlaybackController`'s.
final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    private var readiness: NSKeyValueObservation?

    /// Clear until the player has a frame to show, then at once: the card shows nothing of the video before its
    /// own picture (no poster, which is often another moment than the frame the video starts on).
    var player: AVPlayer? {
        get { playerLayer.player }
        set {
            guard playerLayer.player !== newValue else { return }
            playerLayer.player = newValue
            readiness = nil
            alpha = 0
            guard newValue != nil else { return }
            // Reported wherever AVFoundation changes it: only whether it is ready crosses to the main actor.
            readiness = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
                let ready = layer.isReadyForDisplay
                Task { @MainActor [weak self] in
                    guard ready, let self, self.playerLayer.player != nil else { return }
                    UIView.performWithoutAnimation { self.alpha = 1 }
                }
            }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        playerLayer.videoGravity = .resizeAspectFill
        alpha = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
