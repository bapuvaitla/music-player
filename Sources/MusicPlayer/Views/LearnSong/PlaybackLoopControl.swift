import SwiftUI

/// A compact loop toggle + `LoopScrubBar`, condensed into one row for the
/// tighter space in each Learn Song pane/full score. Reads and writes the
/// same one shared region/loop-toggle pair as the song's own transport
/// (`LargeNowPlayingBarView`) — see `LearnSongView.applyLoopRegionToEngines`
/// — not a region of its own; this is just the convenient place to see
/// and drag it against whichever stave's bars are on screen right now,
/// without scrolling down to the transport at the bottom of the window.
/// The region and the toggle are independent: dragging always updates
/// `selectedRegion` (used to scope Play Along/Sing Along regardless of
/// looping), while the toggle only controls whether anything repeats.
struct PlaybackLoopControl: View {
    /// A region can be selected independent of whether it loops — see
    /// `isLoopEnabled`.
    @Binding var selectedRegion: ClosedRange<TimeInterval>?
    /// The one shared loop toggle. On: both normal playback and Play
    /// Along/Sing Along repeat `selectedRegion`. Off: both still use
    /// `selectedRegion` to scope playback/scoring, they just don't repeat.
    @Binding var isLoopEnabled: Bool
    let duration: TimeInterval
    let currentTime: TimeInterval
    let onSeek: (TimeInterval) -> Void
    /// Bar-start times, shown as tick marks on the scrub bar so a loop
    /// region can be lined up against actual bar boundaries.
    var barTimes: [TimeInterval] = []
    /// Bar/beat positions the loop handles softly snap to while dragging.
    var snapPoints: [TimeInterval] = []

    @State private var loopEnabled: Bool
    @State private var loopStart: TimeInterval
    @State private var loopEnd: TimeInterval
    /// The last values *this* control itself wrote into `selectedRegion`/
    /// `isLoopEnabled` — the same shared state is also set from other
    /// places (the song's own transport, or this same control on a
    /// different pane), and the local `loopEnabled`/`loopStart`/`loopEnd`
    /// only ever get seeded once, at `init`. Without tracking these, there
    /// was no way for `.onChange` (below) to tell "the shared state
    /// changed because I just wrote it" (safe to ignore) apart from
    /// "something *else* changed it" (needs mirroring into this control's
    /// own local state) — so a region/toggle set anywhere else would sit
    /// invisible to this control's still-stale local state, right up until
    /// anything here next called `apply()`, which would silently overwrite
    /// that external change with its own stale idea of it. That's what
    /// made the loop region appear to randomly reset itself.
    @State private var lastWrittenRegion: ClosedRange<TimeInterval>?
    @State private var lastWrittenIsLoopEnabled: Bool

    init(selectedRegion: Binding<ClosedRange<TimeInterval>?>, isLoopEnabled: Binding<Bool>, duration: TimeInterval, currentTime: TimeInterval, onSeek: @escaping (TimeInterval) -> Void, barTimes: [TimeInterval] = [], snapPoints: [TimeInterval] = []) {
        self._selectedRegion = selectedRegion
        self._isLoopEnabled = isLoopEnabled
        self.duration = duration
        self.currentTime = currentTime
        self.onSeek = onSeek
        self.barTimes = barTimes
        self.snapPoints = snapPoints
        let initial = selectedRegion.wrappedValue
        _loopEnabled = State(initialValue: isLoopEnabled.wrappedValue)
        _loopStart = State(initialValue: initial?.lowerBound ?? 0)
        _loopEnd = State(initialValue: initial?.upperBound ?? Self.defaultLoopEnd(duration: duration, barTimes: barTimes))
        _lastWrittenRegion = State(initialValue: initial)
        _lastWrittenIsLoopEnabled = State(initialValue: isLoopEnabled.wrappedValue)
    }

    /// The first loop region a pane offers, before you've dragged
    /// anything — 4 bars from the start when bar data is available
    /// (`barTimes[4]` is exactly the end of the 4th bar), else the whole
    /// piece if it's shorter than that, else a flat 5-second fallback for
    /// a sequence with no bar data at all.
    private static func defaultLoopEnd(duration: TimeInterval, barTimes: [TimeInterval]) -> TimeInterval {
        if barTimes.count > 4 {
            return barTimes[4]
        } else if !barTimes.isEmpty {
            return duration
        }
        return min(duration, 5)
    }

    private var isRegionSelected: Bool { selectedRegion != nil }

    var body: some View {
        // The toggle and reset button are a tight pair (8pt) — one acts on
        // the other's target — but there's extra room (16pt) before the
        // scrub bar itself, so the reset button doesn't read as glued to
        // the measure ruler it's nowhere near operating on directly.
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                Button {
                    loopEnabled.toggle()
                } label: {
                    // Filled solid green when on, plain gray glyph with no
                    // fill when off — a flat tint (as a system `Toggle`
                    // rendered it) read as "on" even at rest, so this
                    // needs the two states to look nothing alike rather
                    // than just a shade apart.
                    Image(systemName: "repeat")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(loopEnabled ? Color.white : Color.secondary)
                        .frame(width: 28, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(loopEnabled ? Color.green : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .help("Loop the selected region")

                // Drag either handle on the bar below to select/adjust a
                // region — that's always available, regardless of whether
                // looping is on. This just clears back to "no region,
                // whole song" once you're done with one.
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

            LoopScrubBar(
                loopEnabled: loopEnabled,
                isRegionSelected: isRegionSelected,
                loopStart: $loopStart,
                loopEnd: $loopEnd,
                duration: max(duration, loopEnd),
                currentTime: currentTime,
                onSeek: onSeek,
                barTimes: barTimes,
                snapPoints: snapPoints
            )
        }
        .onChange(of: loopEnabled) { _, _ in apply() }
        .onChange(of: loopStart) { _, _ in apply() }
        .onChange(of: loopEnd) { _, _ in apply() }
        .onChange(of: duration) { _, newValue in
            // A freshly-imported/replaced sequence: the previous default
            // end (min(oldDuration, 5)) may no longer make sense.
            if loopEnd > newValue { loopEnd = newValue }
        }
        .onChange(of: selectedRegion) { _, newValue in
            guard newValue != lastWrittenRegion else { return }
            lastWrittenRegion = newValue
            if let newValue {
                loopStart = newValue.lowerBound
                loopEnd = newValue.upperBound
            }
        }
        .onChange(of: isLoopEnabled) { _, newValue in
            guard newValue != lastWrittenIsLoopEnabled else { return }
            lastWrittenIsLoopEnabled = newValue
            loopEnabled = newValue
        }
    }

    private func apply() {
        // Always updates the region regardless of `loopEnabled` — a
        // region can be selected (and used to scope Play Along/Sing
        // Along) without looping it. Only `isLoopEnabled` controls
        // whether anything actually repeats.
        let region = loopEnd > loopStart ? loopStart...loopEnd : nil
        lastWrittenRegion = region
        selectedRegion = region
        lastWrittenIsLoopEnabled = loopEnabled
        isLoopEnabled = loopEnabled
    }

    /// Clears the shared region/toggle back to "no region, whole song" —
    /// and resets the local handle positions back to the default span, so
    /// the next drag starts fresh instead of resuming from wherever they
    /// last were.
    private func reset() {
        loopEnabled = false
        loopStart = 0
        loopEnd = Self.defaultLoopEnd(duration: duration, barTimes: barTimes)
        lastWrittenRegion = nil
        selectedRegion = nil
        lastWrittenIsLoopEnabled = false
        isLoopEnabled = false
    }
}
