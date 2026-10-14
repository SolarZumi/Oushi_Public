// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import AVFoundation

/// The app's one audio session. Silent videos play under the ambient category, so they do not stop the music
/// playing; turning a video's sound on takes the playback category, so it is heard with the ring switch off as in
/// Photos, and gives it back afterwards. Interruptions (a call) and a lost route (headphones unplugged) are
/// reported so the player can pause.
@MainActor
final class AudioSessionController {
    enum Interruption: Equatable {
        /// A call or another app took the audio.
        case began
        /// It gave the audio back; `resumes` is the system's word on whether playback should go on by itself.
        case ended(resumes: Bool)
    }

    var onInterruption: ((Interruption) -> Void)?
    /// The headphones were unplugged or the speaker route otherwise lost.
    var onRouteLost: (() -> Void)?
    /// The media services were reset: the session has been set up again here; players must be made anew.
    var onMediaServicesReset: (() -> Void)?

    private let session = AVAudioSession.sharedInstance()
    private var isSoundOn = false
    private var observers: [any NSObjectProtocol] = []
    /// Giving the session back is tried again a few times: a player just paused may still run audio for a moment.
    private var deactivation: Task<Void, Never>?
    private static let deactivationAttempts = 4
    private static let deactivationRetry: Duration = .milliseconds(150)

    init() {
        // Ambient from the start: a muted player still activates the session when it plays, and the default
        // (solo ambient) would silence other apps.
        setAmbient()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.mediaServicesWereReset() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let resumes = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) } ?? false
            MainActor.assumeIsolated {
                switch type {
                case .began: self?.onInterruption?(.began)
                case .ended: self?.onInterruption?(.ended(resumes: resumes))
                @unknown default: break
                }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
            MainActor.assumeIsolated { self?.onRouteLost?() }
        })
    }

    /// Takes the playback session for sound, or gives it back for silence. Returns whether sound is on after
    /// this: a session that cannot be taken (a call holds the audio) leaves it off. The player must be paused
    /// before the session is given back: it cannot be deactivated while audio runs.
    @discardableResult
    func setSoundOn(_ on: Bool) -> Bool {
        guard on != isSoundOn else { return isSoundOn }
        deactivation?.cancel()
        deactivation = nil
        if on {
            do {
                try session.setCategory(.playback, mode: .moviePlayback)
                try session.setActive(true)
                isSoundOn = true
            } catch {
                // Not taken: back to ambient, so the music is not left stopped for nothing; tried again next time.
                Log.media.error("audio session could not be taken for sound: \(error, privacy: .public)")
                setAmbient()
            }
        } else {
            isSoundOn = false
            giveBack(attempt: 1)
        }
        return isSoundOn
    }

    /// Deactivates the session so other apps' audio resumes, trying again shortly if it is still busy (the
    /// player's audio runs on for a moment after a pause), and sets the ambient category whether or not it went.
    private func giveBack(attempt: Int) {
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            if attempt < Self.deactivationAttempts {
                deactivation = Task { [weak self] in
                    try? await Task.sleep(for: Self.deactivationRetry)
                    guard let self, !Task.isCancelled, !self.isSoundOn else { return }
                    self.giveBack(attempt: attempt + 1)
                }
            } else {
                Log.media.error("audio session could not be given back: \(error, privacy: .public)")
            }
        }
        if attempt == 1 { setAmbient() }
    }

    private func setAmbient() {
        do {
            try session.setCategory(.ambient, mode: .default)
        } catch {
            Log.media.error("audio session could not be set to ambient: \(error, privacy: .public)")
        }
    }

    /// After a reset the session is back at the system's default: set up again as it was, then the player's turn.
    private func mediaServicesWereReset() {
        if isSoundOn {
            do {
                try session.setCategory(.playback, mode: .moviePlayback)
                try session.setActive(true)
            } catch {
                Log.media.error("audio session could not be taken again after a reset: \(error, privacy: .public)")
                isSoundOn = false
                setAmbient()
            }
        } else {
            setAmbient()
        }
        onMediaServicesReset?()
    }
}
