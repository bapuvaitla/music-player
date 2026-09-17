import SwiftUI
import MusicPlayerKit

/// The song's own transport in Learn Song mode, with one addition: a loop
/// region. Two independent toggles — region-select and loop — give four
/// states: neither on (plays the full song, once); region on, loop off
/// (plays just that section, once); both on (loops just that section);
/// region off, loop on (loops the entire song). Reuses the same
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

    /// Mirrors `selectedRegion != nil` — see `PlaybackLoopControl.regionSelected`
    /// for why this is its own piece of local state rather than computed
    /// inline.
    @State private var regionSelected: Bool
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
        _regionSelected = State(initialValue: initial != nil)
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
            }

            // The two toggles and the scrub bar they apply to all live in
            // one row — they used to be split across two rows (toggle/
            // reset up top, scrub bar below) with two different gaps,
            // which made the "these go together" grouping hard to read.
            // The toggles are a tight pair (8pt); there's extra room
            // (16pt) before the time label/scrub bar/time label cluster,
            // matching `PlaybackLoopControl`'s layout.
            HStack(spacing: 16) {
                HStack(spacing: 8) {
                    LoopControlToggle(isActive: regionSelected, help: "Select a region") {
                        regionSelected.toggle()
                    } icon: { color in
                        RegionSelectIcon(color: color)
                    }

                    LoopControlToggle(isActive: loopEnabled, help: "Loop") {
                        loopEnabled.toggle()
                    } icon: { color in
                        Image(systemName: "repeat")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(color)
                    }
                }

                Text(timeString(player.currentTime))
                    .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                    .frame(width: 30, alignment: .trailing)

                LoopScrubBar(
                    loopEnabled: loopEnabled,
                    isRegionSelected: regionSelected,
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
        .onChange(of: regionSelected) { _, newValue in
            // A fresh default span every time selection turns on, rather
            // than resuming wherever the handles last were.
            if newValue {
                loopStart = 0
                loopEnd = min(player.duration, 10)
            }
            applyLoopRegion()
        }
        .onChange(of: loopEnabled) { _, _ in applyLoopRegion() }
        .onChange(of: loopStart) { _, _ in applyLoopRegion() }
        .onChange(of: loopEnd) { _, _ in applyLoopRegion() }
        .onChange(of: selectedRegion) { _, newValue in
            guard newValue != lastWrittenRegion else { return }
            lastWrittenRegion = newValue
            regionSelected = newValue != nil
            if let newValue {
                loopStart = newValue.lowerBound
                loopEnd = newValue.upperBound
            }
            syncPlayerLoop()
        }
        .onChange(of: isLoopEnabled) { _, newValue in
            guard newValue != lastWrittenIsLoopEnabled else { return }
            lastWrittenIsLoopEnabled = newValue
            loopEnabled = newValue
            syncPlayerLoop()
        }
    }

    private func applyLoopRegion() {
        let region = regionSelected ? loopStart...loopEnd : nil
        lastWrittenRegion = region
        selectedRegion = region
        lastWrittenIsLoopEnabled = loopEnabled
        isLoopEnabled = loopEnabled
        syncPlayerLoop()
    }

    /// With no region selected but looping on, the *whole song* loops —
    /// so the engine still needs a concrete range, not `nil`. Centralized
    /// here since three different places (a region/loop toggle changing
    /// locally, or either one changing from outside via `selectedRegion`/
    /// `isLoopEnabled`) all need to recompute the same thing.
    private func syncPlayerLoop() {
        guard isThisTrackCurrent else { return }
        player.loopRegion = regionSelected ? loopStart...loopEnd : (loopEnabled ? 0...player.duration : nil)
        player.loopsRegion = loopEnabled
    }

    private func timeString(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let total = Int(time.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
