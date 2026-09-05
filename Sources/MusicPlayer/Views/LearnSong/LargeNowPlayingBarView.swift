import SwiftUI
import MusicPlayerKit

/// The song's own transport in Learn Song mode, with one addition: a loop
/// region. Drag the two handles on the scrub bar, toggle looping on, and
/// the song repeats just that section while you practice. Reuses the
/// same `PlayerController`/`PlaybackCoordinator` as the rest of the app —
/// the song doesn't need to stay in sync with the tab/vocal playback, so
/// there's no separate player instance here.
///
/// Artwork/title/artist already live in `LearnSongView`'s header, so this
/// only needs to say "this is the song itself" (a small label) rather than
/// repeating that identity — but it turned out to get real use, so it's
/// sized for that rather than treated as a footnote.
struct LargeNowPlayingBarView: View {
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var coordinator: PlaybackCoordinator

    let track: Track
    /// The owner (`LearnSongView`) persists this — nil means no loop set.
    @Binding var loopRegion: ClosedRange<TimeInterval>?

    @State private var loopEnabled: Bool
    @State private var loopStart: TimeInterval
    @State private var loopEnd: TimeInterval

    init(track: Track, loopRegion: Binding<ClosedRange<TimeInterval>?>) {
        self.track = track
        self._loopRegion = loopRegion
        let initial = loopRegion.wrappedValue
        _loopEnabled = State(initialValue: initial != nil)
        _loopStart = State(initialValue: initial?.lowerBound ?? 0)
        _loopEnd = State(initialValue: initial?.upperBound ?? 10)
    }

    private var isThisTrackCurrent: Bool { player.currentTrack?.id == track.id }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 14) {
                // Play controls lead on the left — the thing you reach for
                // constantly, worth top billing rather than trailing after
                // the label. Play is the one action at full size/contrast;
                // previous/next recede accordingly (smaller, muted).
                HStack(spacing: 18) {
                    Button { coordinator.previous() } label: {
                        Image(systemName: "backward.fill").font(.system(size: 15))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                    Button {
                        if isThisTrackCurrent {
                            player.togglePlayPause()
                        } else {
                            coordinator.play(track: track, in: [track])
                            // play(track:) resets loopRegion — reapply if
                            // the user had already turned looping on.
                            applyLoopRegion()
                        }
                    } label: {
                        Image(systemName: (isThisTrackCurrent && player.isPlaying) ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 30))
                    }
                    .buttonStyle(.plain)

                    Button { coordinator.next() } label: {
                        Image(systemName: "forward.fill").font(.system(size: 15))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }

                Label("Original Track", systemImage: "music.note")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)

                Spacer()

                // "Select a section [of the song] to loop" — sized up to
                // match the rest of this bar's new prominence.
                Toggle(isOn: $loopEnabled) {
                    Image(systemName: "repeat")
                        .font(.system(size: 15))
                }
                .toggleStyle(.button)
                .tint(.accentColor)
                .help("Loop a section of the song")
            }

            HStack(spacing: 6) {
                Text(timeString(player.currentTime))
                    .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                    .frame(width: 30, alignment: .trailing)

                LoopScrubBar(
                    loopEnabled: loopEnabled,
                    loopStart: $loopStart,
                    loopEnd: $loopEnd,
                    duration: max(player.duration, loopEnd),
                    currentTime: isThisTrackCurrent ? player.currentTime : 0,
                    onSeek: { time in
                        if isThisTrackCurrent { player.seek(to: time) }
                    }
                )

                Text(timeString(player.duration))
                    .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                    .frame(width: 30, alignment: .leading)
            }
        }
        .padding(14)
        // Bumped up from a faint gray tint to the app's standard "lifted
        // surface" — this turned out to be worth reaching for often
        // enough to earn real presence, not just a quiet footnote.
        .background(Color.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onChange(of: loopEnabled) { _, _ in applyLoopRegion() }
        .onChange(of: loopStart) { _, _ in applyLoopRegion() }
        .onChange(of: loopEnd) { _, _ in applyLoopRegion() }
    }

    private func applyLoopRegion() {
        if loopEnabled, loopEnd > loopStart {
            let region = loopStart...loopEnd
            loopRegion = region
            if isThisTrackCurrent { player.loopRegion = region }
        } else {
            loopRegion = nil
            if isThisTrackCurrent { player.loopRegion = nil }
        }
    }

    private func timeString(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let total = Int(time.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
