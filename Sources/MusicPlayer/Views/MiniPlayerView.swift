import SwiftUI
import MusicPlayerKit

/// A compact, optionally always-on-top player window — separate from the
/// main library window so it can stay visible while you work elsewhere.
/// Resizable: dragging the window bigger grows the artwork. Text/controls
/// stay a fixed size rather than scaling — letting them scale with width
/// alone (independent of height) is what previously let a wide-but-short
/// window clip the transport buttons off the bottom.
struct MiniPlayerView: View {
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var coordinator: PlaybackCoordinator
    @EnvironmentObject private var library: LibraryModel

    @State private var keepOnTop = true
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0

    /// Vertical space the padding, text, slider, and button row need at
    /// their fixed size — whatever's left over goes to the artwork.
    private let reservedHeight: CGFloat = 172

    var body: some View {
        GeometryReader { geo in
            let artSize = max(60, min(geo.size.width - 36, geo.size.height - reservedHeight))

            VStack(spacing: 10) {
                ArtworkView(track: player.currentTrack, size: artSize, cornerRadius: 10)
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 4)

                VStack(spacing: 2) {
                    Text(player.currentTrack?.title ?? "Not Playing")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(player.currentTrack?.artist ?? " ")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)

                if let track = player.currentTrack {
                    // A numeric stepper, not the table's slider control —
                    // a second slider right above the track progress bar
                    // read as visually confusing/redundant.
                    Stepper(
                        value: Binding(
                            get: { track.rating },
                            set: { library.setRating($0, for: track) }
                        ),
                        in: 0...11
                    ) {
                        Text(track.rating == 0 ? "–" : "\(track.rating)")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(track.rating == 0 ? Color.secondary : Color.accentColor)
                    }
                    .controlSize(.small)
                    .fixedSize()
                }

                Slider(
                    value: Binding(
                        get: { isScrubbing ? scrubValue : player.currentTime },
                        set: { scrubValue = $0 }
                    ),
                    in: 0...max(player.duration, 0.1),
                    onEditingChanged: { editing in
                        if editing {
                            isScrubbing = true
                            scrubValue = player.currentTime
                        } else {
                            player.seek(to: scrubValue)
                            isScrubbing = false
                        }
                    }
                )
                .controlSize(.small)
                .disabled(player.currentTrack == nil)

                HStack(spacing: 26) {
                    Button { coordinator.previous() } label: {
                        Image(systemName: "backward.fill")
                    }
                    .foregroundStyle(player.currentTrack == nil ? Color.secondary.opacity(0.4) : Color.primary)
                    .disabled(player.currentTrack == nil)

                    Button { coordinator.togglePlayPause(fallbackQueue: library.visibleTracks) } label: {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 30))
                    }
                    .disabled(player.currentTrack == nil && library.visibleTracks.isEmpty)

                    Button { coordinator.next() } label: {
                        Image(systemName: "forward.fill")
                    }
                    .foregroundStyle(player.currentTrack == nil ? Color.secondary.opacity(0.4) : Color.primary)
                    .disabled(player.currentTrack == nil)
                }
                .buttonStyle(.plain)
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 160, idealWidth: 190, minHeight: 260, idealHeight: 300)
        .background(Color.appBackground)
        .background(WindowLevelController(isFloating: keepOnTop))
        .overlay(alignment: .topTrailing) {
            Button {
                keepOnTop.toggle()
            } label: {
                Image(systemName: keepOnTop ? "pin.fill" : "pin")
                    .font(.system(size: 11))
                    .foregroundStyle(keepOnTop ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .padding(10)
            .help(keepOnTop ? "Always on top — click to allow other windows above it" : "Click to keep this window on top")
        }
    }
}
