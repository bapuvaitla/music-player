import Foundation
import MediaPlayer
import Combine
import AppKit

/// Registers this app with macOS's system media controls (`MPRemoteCommandCenter`)
/// so the keyboard media keys (and Control Center's Now Playing widget)
/// drive this app instead of whatever last claimed them — typically Music.app.
/// macOS routes hardware media keys to whichever app is actively keeping
/// `MPNowPlayingInfoCenter` updated, so this is the standard, sanctioned way
/// to do this — no accessibility permissions or private APIs involved.
@MainActor
public final class MediaKeyController {
    private let player: PlayerController
    private let coordinator: PlaybackCoordinator
    private let library: LibraryModel
    private var cancellables: Set<AnyCancellable> = []
    private var artworkTask: Task<Void, Never>?

    public init(player: PlayerController, coordinator: PlaybackCoordinator, library: LibraryModel) {
        self.player = player
        self.coordinator = coordinator
        self.library = library
        configureRemoteCommands()
        observePlayerState()
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if !self.player.isPlaying {
                self.coordinator.togglePlayPause(fallbackQueue: self.library.visibleTracks)
            }
            return .success
        }

        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self, self.player.isPlaying else { return .commandFailed }
            self.player.pause()
            return .success
        }

        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.coordinator.togglePlayPause(fallbackQueue: self.library.visibleTracks)
            return .success
        }

        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.coordinator.next()
            return .success
        }

        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.coordinator.previous()
            return .success
        }

        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self.player.seek(to: event.positionTime)
            return .success
        }

        // Not supported — explicitly disabled so Control Center doesn't
        // show dead buttons for them.
        center.stopCommand.isEnabled = false
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
    }

    private func observePlayerState() {
        player.$currentTrack
            .sink { [weak self] track in
                self?.updateNowPlayingInfo(for: track)
            }
            .store(in: &cancellables)

        player.$isPlaying
            .sink { [weak self] _ in
                self?.updatePlaybackRateAndPosition()
            }
            .store(in: &cancellables)
    }

    private func updateNowPlayingInfo(for track: Track?) {
        artworkTask?.cancel()

        guard let track else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        let info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: track.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? 1.0 : 0.0
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        artworkTask = Task {
            guard let image = await ArtworkLoader.shared.artwork(for: track) else { return }
            guard !Task.isCancelled else { return }

            // MediaPlayer.framework invokes the request handler below from
            // its own internal background queue, never the main actor. The
            // request handler parameter isn't marked @Sendable in the
            // imported header, so a plain closure literal constructed here
            // (inside a @MainActor method) is inferred as @MainActor-
            // isolated, and Swift embeds a runtime executor check that
            // traps the instant the framework calls it off-main. That was
            // the actual crash — wrapping the *construction* in
            // Task.detached didn't help, since MPMediaItemArtwork itself
            // isn't Sendable and can't cross back to the main actor anyway.
            // Marking the closure literal `@Sendable` directly overrides
            // the isolation inference, making it nonisolated regardless of
            // where it's built. The `@unchecked Sendable` box is what makes
            // capturing the (non-Sendable) NSImage inside it legal —
            // read-only use from a background queue, exactly what happens
            // here, is safe in practice despite NSImage not being Sendable.
            let box = UncheckedSendableBox(image)
            let artwork = MPMediaItemArtwork(boundsSize: box.value.size) { @Sendable _ in box.value }

            var updated = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? info
            updated[MPMediaItemPropertyArtwork] = artwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = updated
        }
    }

    private func updatePlaybackRateAndPosition() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = player.isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

/// Legitimizes sharing an `NSImage` across the actor boundary into a
/// framework-invoked closure. `NSImage` isn't formally `Sendable`, but
/// read-only use (size, pixel data) from a background queue — exactly what
/// `MPMediaItemArtwork`'s request handler does — is safe in practice; this
/// is the standard, deliberate escape hatch for that specific situation,
/// not a blanket "trust me."
private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
