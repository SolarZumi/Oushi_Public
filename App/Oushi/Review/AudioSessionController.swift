// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import AVFoundation

/// The app's one audio session. Silent videos play under the ambient category, so they do not stop the music
/// playing; turning a video's sound on takes the playback category, so it is heard with the ring switch off as in
/// Photos, and gives it back afterwards. Interruptions (a call) and a lost route (headphones unplugged) are
/// reported so the player can pause.
///
/// The session's own calls block: each is a round trip to the audio server, and giving the session back waits on
/// the player's audio running down. Made on the main thread they held the screen still, and as giving back comes
/// with a swipe away from a video with its sound on, the card stuttered at the start of its flight. So they run on
/// a queue of their own, in the order asked, and the main thread never waits on them.
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

    private let session = AudioSessionWorker()
    private var observers: [any NSObjectProtocol] = []

    init() {
        // Ambient from the start: a muted player still activates the session when it plays, and the default
        // (solo ambient) would silence other apps.
        session.start()
        let center = NotificationCenter.default
        let shared = AVAudioSession.sharedInstance()
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.mediaServicesWereReset() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: shared, queue: .main) { [weak self] notification in
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
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: shared, queue: .main) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
            MainActor.assumeIsolated { self?.onRouteLost?() }
        })
    }

    /// Takes the playback session for sound, or gives it back for silence, and answers whether sound is on after
    /// this: a session that cannot be taken (a call holds the audio) leaves it off. Giving back waits, off the main
    /// thread, for the player's audio to stop running.
    func setSoundOn(_ on: Bool) async -> Bool {
        await session.setSoundOn(on)
    }

    /// After a reset the session is back at the system's default: set up again as it was, then the player's turn.
    private func mediaServicesWereReset() {
        Task { [weak self] in
            guard let self else { return }
            await self.session.reestablish()
            self.onMediaServicesReset?()
        }
    }
}

/// The audio session's calls, made one after another on a serial queue of their own; its state is touched only
/// there.
private final class AudioSessionWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Oushi.audio-session", qos: .userInitiated)
    private var isSoundOn = false
    /// Bumped by each change of sound, so a retry of an earlier giving back gives up once sound was asked for since.
    private var generation = 0
    /// Giving the session back is tried again a few times: a player just paused may still run audio for a moment.
    private static let deactivationAttempts = 4
    private static let deactivationRetry: TimeInterval = 0.15

    private var session: AVAudioSession { .sharedInstance() }

    func start() {
        queue.async { self.setAmbient() }
    }

    func setSoundOn(_ on: Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.applySound(on)) }
        }
    }

    func reestablish() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.restore()
                continuation.resume()
            }
        }
    }

    // On `queue`.

    private func applySound(_ on: Bool) -> Bool {
        guard on != isSoundOn else { return isSoundOn }
        generation += 1
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
            giveBack(attempt: 1, generation: generation)
        }
        return isSoundOn
    }

    /// Deactivates the session so other apps' audio resumes, trying again shortly if it is still busy (the
    /// player's audio runs on for a moment after a pause), and sets the ambient category whether or not it went.
    private func giveBack(attempt: Int, generation: Int) {
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            if attempt < Self.deactivationAttempts {
                queue.asyncAfter(deadline: .now() + Self.deactivationRetry) {
                    guard !self.isSoundOn, self.generation == generation else { return }
                    self.giveBack(attempt: attempt + 1, generation: generation)
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

    private func restore() {
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
    }
}
