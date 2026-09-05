import SwiftUI

/// A compact loop toggle + `LoopScrubBar`, for looping a section of a
/// `NotePlaybackEngine`'s tab/vocal playback — the same idea as the song's
/// loop region in `LargeNowPlayingBarView`, just condensed into one row
/// for the tighter space in each Learn Song pane.
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
    }

    private func apply() {
        loopRegion = (loopEnabled && loopEnd > loopStart) ? loopStart...loopEnd : nil
    }
}
