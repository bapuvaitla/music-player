import Foundation
import AVFoundation
import Combine

@MainActor
public final class PlayerController: ObservableObject {
    @Published public private(set) var currentTrack: Track?
    @Published public private(set) var isPlaying: Bool = false
    @Published public private(set) var currentTime: TimeInterval = 0
    @Published public private(set) var duration: TimeInterval = 0
    @Published public var volume: Float = 0.8 {
        didSet { player?.volume = volume }
    }

    public var onTrackFinished: (() -> Void)?

    /// When set, playback jumps back to `lowerBound` once it reaches
    /// `upperBound` (or, with `loopsRegion` false, just stops there
    /// instead) — used by Learn Song to scope/loop a section of the song
    /// while practicing. `nil` (the default) has no effect on normal
    /// playback. Cleared automatically whenever a new track starts, since
    /// a loop region only makes sense for the track it was set on.
    public var loopRegion: ClosedRange<TimeInterval>?
    /// When true (the default) and `loopRegion` is set, reaching its end
    /// seeks back to its start and keeps playing. When false, reaching
    /// its end just stops — a region can be selected purely to scope
    /// where playback stops, played through once, without repeating it.
    public var loopsRegion: Bool = true

    /// Fired whenever a track stops being current (skipped, replaced, or
    /// finished), with how much of it was actually heard, in units of "one
    /// full listen" (0...∞ — rewinding to replay a passage means real
    /// listening time can exceed the track's own duration in one sitting,
    /// and that's credited rather than capped). Intended for accumulating
    /// fractional play counts.
    public var onFractionalPlay: ((Track, Double) -> Void)?

    private var player: AVAudioPlayer?
    private var timer: Timer?

    /// Total real seconds actually spent playing the current track, not
    /// just how far into it the playhead has reached — advances on every
    /// timer tick while genuinely playing regardless of seeking, so
    /// rewinding to replay a passage accumulates extra rather than being
    /// ignored the way a position-based measure would.
    private var accumulatedPlayedSeconds: TimeInterval = 0

    public init() {}

    public func play(track: Track) {
        // Placeholder tracks (see Track.isPlaceholder) have no real file
        // behind them — nothing to play. Guarded here too, not just in
        // PlaybackCoordinator, since this is reachable directly.
        guard !track.isPlaceholder else { return }

        recordFractionalPlayIfNeeded()

        do {
            let newPlayer = try AVAudioPlayer(contentsOf: track.url)
            newPlayer.volume = volume
            newPlayer.delegate = playerDelegate
            newPlayer.prepareToPlay()
            newPlayer.play()

            player = newPlayer
            currentTrack = track
            duration = newPlayer.duration
            currentTime = 0
            accumulatedPlayedSeconds = 0
            loopRegion = nil
            isPlaying = true
            startTimer()
        } catch {
            print("Failed to play \(track.path): \(error)")
        }
    }

    public func togglePlayPause() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    public func pause() {
        player?.pause()
        isPlaying = false
    }

    public func seek(to time: TimeInterval) {
        player?.currentTime = time
        currentTime = time
    }

    public func stop() {
        recordFractionalPlayIfNeeded()
        player?.stop()
        player = nil
        currentTrack = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        accumulatedPlayedSeconds = 0
        stopTimer()
    }

    private lazy var playerDelegate = PlayerDelegate { [weak self] in
        Task { @MainActor in
            self?.handleFinished()
        }
    }

    private func handleFinished() {
        recordFractionalPlayIfNeeded()
        // Prevent the next play(track:) call (triggered by onTrackFinished)
        // from double-crediting this same finished track.
        currentTrack = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        accumulatedPlayedSeconds = 0
        stopTimer()
        onTrackFinished?()
    }

    /// Credits however much of the current track has actually been heard so
    /// far (by elapsed playing time, not playhead position). Called before
    /// replacing/clearing the current track so a skip mid-song, or the
    /// track finishing naturally, both still count.
    private func recordFractionalPlayIfNeeded() {
        guard let pending = pendingFractionalPlay else { return }
        onFractionalPlay?(pending.track, pending.fraction)
    }

    /// However much of the current track has been heard so far, as a
    /// fraction of its duration — the same value `recordFractionalPlayIfNeeded`
    /// would credit right now. Exposed read-only so app termination can
    /// flush it through an awaited write instead of the closure-based path,
    /// which fires an unstructured `Task` that AppKit can tear down mid-write.
    public var pendingFractionalPlay: (track: Track, fraction: Double)? {
        guard let track = currentTrack, duration > 0 else { return nil }
        let fraction = accumulatedPlayedSeconds / duration
        guard fraction > 0 else { return nil }
        return (track, fraction)
    }

    private func startTimer() {
        stopTimer()
        // Timer.scheduledTimer(withTimeInterval:repeats:) only fires in the
        // run loop's .default mode, which AppKit switches away from during
        // any mouse-tracking loop — dragging the scrub bar, resizing a
        // window, holding down a slider, even having a menu open. During
        // that stretch this timer would simply stop firing, so seconds
        // playing right then never accumulated. Scheduling it in .common
        // modes instead keeps it ticking through all of that.
        let newTimer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
                if player.isPlaying {
                    self.accumulatedPlayedSeconds += 0.25
                }
                if let loopRegion = self.loopRegion, self.currentTime >= loopRegion.upperBound {
                    if self.loopsRegion {
                        self.seek(to: loopRegion.lowerBound)
                    } else {
                        // `pause()`, not `stop()` — this should just halt
                        // at the end of the selected region and stay on
                        // this track, not tear down playback state or
                        // (via `onTrackFinished`) advance to the next one
                        // in the queue.
                        self.pause()
                    }
                }
            }
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate {
    let onFinish: () -> Void

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish()
    }
}
