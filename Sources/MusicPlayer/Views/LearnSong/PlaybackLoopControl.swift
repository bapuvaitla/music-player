import SwiftUI

/// A compact loop toggle + `LoopScrubBar`, condensed into one row for the
/// tighter space in each Learn Song pane/full score. Reads and writes the
/// same one shared loop region as the song's own transport
/// (`LargeNowPlayingBarView`) — see `LearnSongView.applyLoopRegionToEngines`
/// — not a region of its own; this is just the convenient place to see
/// and drag it against whichever stave's bars are on screen right now,
/// without scrolling down to the transport at the bottom of the window.
struct PlaybackLoopControl: View {
    @Binding var loopRegion: ClosedRange<TimeInterval>?
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
    /// The last value *this* control itself wrote into `loopRegion` — the
    /// same region is also set from other places (the song's own
    /// transport, or this same control on a different pane), and
    /// `loopEnabled`/`loopStart`/`loopEnd` only ever get seeded once, at
    /// `init`. Without tracking this, there was no way for `.onChange(of:
    /// loopRegion)` (below) to tell "the shared region changed because I
    /// just wrote it" (safe to ignore) apart from "something *else*
    /// changed it" (needs mirroring into this control's own local state) —
    /// so a region set anywhere else would sit invisible to this control's
    /// still-stale local state, right up until anything here next called
    /// `apply()`, which would silently overwrite that external change with
    /// its own stale idea of the region (frequently back to nil/off).
    /// That's what made the loop region appear to randomly reset itself.
    @State private var lastWrittenRegion: ClosedRange<TimeInterval>?

    init(loopRegion: Binding<ClosedRange<TimeInterval>?>, duration: TimeInterval, currentTime: TimeInterval, onSeek: @escaping (TimeInterval) -> Void, barTimes: [TimeInterval] = [], snapPoints: [TimeInterval] = []) {
        self._loopRegion = loopRegion
        self.duration = duration
        self.currentTime = currentTime
        self.onSeek = onSeek
        self.barTimes = barTimes
        self.snapPoints = snapPoints
        let initial = loopRegion.wrappedValue
        _loopEnabled = State(initialValue: initial != nil)
        _loopStart = State(initialValue: initial?.lowerBound ?? 0)
        _loopEnd = State(initialValue: initial?.upperBound ?? Self.defaultLoopEnd(duration: duration, barTimes: barTimes))
        _lastWrittenRegion = State(initialValue: initial)
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

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $loopEnabled) {
                Image(systemName: "repeat")
                    .font(.system(size: 15, weight: .semibold))
            }
            .toggleStyle(.button)
            .tint(.accentColor)
            .help("Loop a section of this")

            LoopScrubBar(
                loopEnabled: loopEnabled,
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
        .onChange(of: loopRegion) { _, newValue in
            guard newValue != lastWrittenRegion else { return }
            lastWrittenRegion = newValue
            loopEnabled = newValue != nil
            if let newValue {
                loopStart = newValue.lowerBound
                loopEnd = newValue.upperBound
            }
        }
    }

    private func apply() {
        let region = (loopEnabled && loopEnd > loopStart) ? loopStart...loopEnd : nil
        lastWrittenRegion = region
        loopRegion = region
    }
}
