import SwiftUI
import MusicPlayerKit

/// The song's own transport in Learn Song mode, with one addition: a loop
/// region. Drag the two handles on the scrub bar to select a section —
/// that's always available, whether or not looping is on. Toggle looping
/// to repeat it, or leave it off to just play through that section once;
/// the "x" button clears back to the full song. Reuses the same
/// `PlayerController`/`PlaybackCoordinator` as the rest of the app — the
/// song doesn't need to stay in sync with the tab/vocal playback, so
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
    /// A region can be selected independent of whether it loops — see
    /// `isLoopEnabled`. The owner (`LearnSongView`) persists both.
    @Binding var selectedRegion: ClosedRange<TimeInterval>?
    @Binding var isLoopEnabled: Bool

    @State private var loopEnabled: Bool
    @State private var loopStart: TimeInterval
    @State private var loopEnd: TimeInterval
    /// The last values *this* control itself wrote into `selectedRegion`/
    /// `isLoopEnabled` — see `PlaybackLoopControl.lastWrittenRegion` for
    /// the full story. Without these, a region/toggle set from a practice
    /// pane's own loop control (which writes the same shared state) sat
    /// invisible to this control's still-stale local state — and the very
    /// next time anything here called `applyLoopRegion()` (pressing Play
    /// while the song wasn't already loaded is one such spot, a few lines
    /// down) would silently stomp that change right back.
    @State private var lastWrittenRegion: ClosedRange<TimeInterval>?
    @State private var lastWrittenIsLoopEnabled: Bool

    init(track: Track, selectedRegion: Binding<ClosedRange<TimeInterval>?>, isLoopEnabled: Binding<Bool>) {
        self.track = track
        self._selectedRegion = selectedRegion
        self._isLoopEnabled = isLoopEnabled
        let initial = selectedRegion.wrappedValue
        _loopEnabled = State(initialValue: isLoopEnabled.wrappedValue)
        _loopStart = State(initialValue: initial?.lowerBound ?? 0)
        _loopEnd = State(initialValue: initial?.upperBound ?? 10)
        _lastWrittenRegion = State(initialValue: initial)
        _lastWrittenIsLoopEnabled = State(initialValue: isLoopEnabled.wrappedValue)
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
                    Button {
                        if isThisTrackCurrent { player.seek(to: 0) }
                    } label: {
                        Image(systemName: "backward.end.fill").font(.system(size: 15))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Rewind to the beginning")

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
                // match the rest of this bar's new prominence. Drag either
                // handle below to select/adjust a region regardless of
                // whether this is on; it just controls whether it repeats.
                Toggle(isOn: $loopEnabled) {
                    Image(systemName: "repeat")
                        .font(.system(size: 15))
                }
                .toggleStyle(.button)
                .tint(.accentColor)
                .help("Loop the selected region")

                Button {
                    reset()
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(selectedRegion == nil)
                .help("Reset to the full song")
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
        .onChange(of: selectedRegion) { _, newValue in
            guard newValue != lastWrittenRegion else { return }
            lastWrittenRegion = newValue
            if let newValue {
                loopStart = newValue.lowerBound
                loopEnd = newValue.upperBound
            }
            if isThisTrackCurrent { player.loopRegion = newValue }
        }
        .onChange(of: isLoopEnabled) { _, newValue in
            guard newValue != lastWrittenIsLoopEnabled else { return }
            lastWrittenIsLoopEnabled = newValue
            loopEnabled = newValue
            if isThisTrackCurrent { player.loopsRegion = newValue }
        }
    }

    private func applyLoopRegion() {
        // Always updates the region regardless of `loopEnabled` — a
        // region can be selected (and used to scope Play Along/Sing
        // Along, or just to mark a section of the song) without looping
        // it. Only `isLoopEnabled` controls whether anything repeats.
        let region = loopEnd > loopStart ? loopStart...loopEnd : nil
        lastWrittenRegion = region
        selectedRegion = region
        lastWrittenIsLoopEnabled = loopEnabled
        isLoopEnabled = loopEnabled
        if isThisTrackCurrent {
            player.loopRegion = region
            player.loopsRegion = loopEnabled
        }
    }

    /// Clears the shared region/toggle back to "no region, whole song" —
    /// and resets the local handle positions back to a default span, so
    /// the next drag starts fresh instead of resuming from wherever they
    /// last were.
    private func reset() {
        loopEnabled = false
        loopStart = 0
        loopEnd = min(player.duration, 10)
        lastWrittenRegion = nil
        selectedRegion = nil
        lastWrittenIsLoopEnabled = false
        isLoopEnabled = false
        if isThisTrackCurrent {
            player.loopRegion = nil
            player.loopsRegion = false
        }
    }

    private func timeString(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let total = Int(time.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
