import Foundation

public enum RepeatMode: Sendable {
    case off, all, one
}

@MainActor
public final class PlaybackCoordinator: ObservableObject {
    public let player: PlayerController

    /// Manually queued tracks ("Play Next" / "Add to Queue"). These always
    /// take priority over the natural continuation of whatever list you
    /// played from, and persist across switching to a different track —
    /// only an explicit `clearUpNext()` empties it.
    @Published public private(set) var upNext: [Track] = []
    @Published public private(set) var isShuffling: Bool = false
    @Published public private(set) var repeatMode: RepeatMode = .off

    /// The list you actually played from (an album, playlist, filtered
    /// view...). Advancing walks this in order, or in `shuffledOrder` when
    /// shuffling.
    private var baseQueue: [Track] = []
    private var shuffledOrder: [Track] = []
    private var currentIndex: Int?
    private var lastPlayedTrack: Track?

    public init(player: PlayerController) {
        self.player = player
        player.onTrackFinished = { [weak self] in
            guard let self else { return }
            if self.repeatMode == .one, let track = self.lastPlayedTrack {
                self.startPlaying(track)
            } else {
                self.next()
            }
        }
    }

    private var activeOrder: [Track] { isShuffling ? shuffledOrder : baseQueue }

    /// The natural continuation after the current track, ignoring `upNext`
    /// — used to preview what plays once the manual queue drains.
    public var upcomingFromQueue: [Track] {
        guard let currentIndex, currentIndex + 1 < activeOrder.count else { return [] }
        return Array(activeOrder[(currentIndex + 1)...])
    }

    private func startPlaying(_ track: Track) {
        // Placeholder tracks (see Track.isPlaceholder) have no backing
        // file — silently do nothing rather than let it fall through to
        // PlayerController and fail there.
        guard !track.isPlaceholder else { return }
        lastPlayedTrack = track
        player.play(track: track)
    }

    public func play(track: Track, in queue: [Track]) {
        baseQueue = queue
        currentIndex = queue.firstIndex(of: track)
        if isShuffling {
            regenerateShuffle(keeping: track)
        }
        startPlaying(track)
    }

    /// `fallbackQueue` is used only when there's nothing else to fall back
    /// on (no current track, no manual queue, no queue from browsing) —
    /// i.e. pressing Play right after launch, before selecting anything.
    /// In that case a random track from it is where playback starts.
    public func togglePlayPause(fallbackQueue: [Track] = []) {
        guard player.currentTrack == nil else {
            player.togglePlayPause()
            return
        }
        if !upNext.isEmpty {
            playFromUpNext()
            return
        }
        if let first = activeOrder.first {
            currentIndex = 0
            startPlaying(first)
            return
        }
        let playableFallback = fallbackQueue.filter { !$0.isPlaceholder }
        guard let randomIndex = playableFallback.indices.randomElement() else { return }
        baseQueue = playableFallback
        let track = playableFallback[randomIndex]
        if isShuffling {
            regenerateShuffle(keeping: track)
        } else {
            currentIndex = randomIndex
        }
        startPlaying(track)
    }

    public func next() {
        if !upNext.isEmpty {
            playFromUpNext()
            return
        }
        guard let currentIndex else { return }
        if currentIndex + 1 < activeOrder.count {
            self.currentIndex = currentIndex + 1
            startPlaying(activeOrder[currentIndex + 1])
        } else if repeatMode == .all, !activeOrder.isEmpty {
            self.currentIndex = 0
            startPlaying(activeOrder[0])
        }
    }

    public func previous() {
        guard let currentIndex else { return }
        if player.currentTime > 3 {
            player.seek(to: 0)
            return
        }
        guard currentIndex - 1 >= 0 else {
            player.seek(to: 0)
            return
        }
        self.currentIndex = currentIndex - 1
        startPlaying(activeOrder[currentIndex - 1])
    }

    private func playFromUpNext() {
        let track = upNext.removeFirst()
        startPlaying(track)
    }

    // MARK: - Shuffle & repeat

    public func toggleShuffle() {
        isShuffling.toggle()
        if isShuffling {
            regenerateShuffle(keeping: player.currentTrack)
        }
    }

    public func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    private func regenerateShuffle(keeping current: Track?) {
        var remaining = baseQueue
        if let current, let idx = remaining.firstIndex(of: current) {
            remaining.remove(at: idx)
        }
        remaining.shuffle()

        if let current {
            shuffledOrder = [current] + remaining
            currentIndex = 0
        } else {
            shuffledOrder = remaining
            currentIndex = remaining.isEmpty ? nil : 0
        }
    }

    // MARK: - Manual queue

    /// Inserts at the front of the manual queue, so it plays immediately
    /// after whatever's currently playing.
    public func playNext(_ track: Track) {
        upNext.insert(track, at: 0)
    }

    /// Appends to the end of the manual queue, after anything already queued.
    public func addToQueue(_ track: Track) {
        upNext.append(track)
    }

    public func removeFromUpNext(at offset: Int) {
        guard upNext.indices.contains(offset) else { return }
        upNext.remove(at: offset)
    }

    public func clearUpNext() {
        upNext.removeAll()
    }
}
