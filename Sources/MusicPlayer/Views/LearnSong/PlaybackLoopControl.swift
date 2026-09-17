import SwiftUI

/// Two toggle buttons + `LoopScrubBar`, condensed into one row for the
/// tighter space in each Learn Song pane/full score. Reads and writes the
/// same one shared region/loop-toggle pair as the song's own transport
/// (`LargeNowPlayingBarView`) — see `LearnSongView.applyLoopRegionToEngines`
/// — not a region of its own; this is just the convenient place to see
/// and drag it against whichever stave's bars are on screen right now,
/// without scrolling down to the transport at the bottom of the window.
///
/// Region-select and loop are two independent toggles, giving four states:
/// neither on (plays the full song, once); region on, loop off (plays just
/// that section, once); both on (loops just that section); region off,
/// loop on (loops the *entire* song — see `LearnSongView.applyLoopRegionToEngines`
/// for how a nil region plus loop-on becomes a full-duration loop on each
/// engine). The region-select toggle is also how a selection starts and
/// ends: turning it on shows a fresh default span to drag, turning it off
/// clears the region entirely — there's no separate reset button anymore,
/// since that button's whole job (get back to "no region") is now just
/// this toggle's off state.
struct PlaybackLoopControl: View {
    /// A region can be selected independent of whether it loops — see
    /// `isLoopEnabled`.
    @Binding var selectedRegion: ClosedRange<TimeInterval>?
    /// The one shared loop toggle. On: both normal playback and Play
    /// Along/Sing Along repeat `selectedRegion` (or, with no region
    /// selected, the entire song). Off: a selected region still scopes
    /// playback/scoring, it just doesn't repeat.
    @Binding var isLoopEnabled: Bool
    let duration: TimeInterval
    let currentTime: TimeInterval
    let onSeek: (TimeInterval) -> Void
    /// Bar-start times, shown as tick marks on the scrub bar so a loop
    /// region can be lined up against actual bar boundaries.
    var barTimes: [TimeInterval] = []
    /// Bar/beat positions the loop handles softly snap to while dragging.
    var snapPoints: [TimeInterval] = []

    /// Mirrors `selectedRegion != nil` — the region-select button's own
    /// on/off state. Kept as separate local state (rather than just
    /// computing `selectedRegion != nil` inline) because turning it on
    /// needs to also seed `loopStart`/`loopEnd` with a fresh default span
    /// in the same gesture; see `apply()`.
    @State private var regionSelected: Bool
    @State private var loopEnabled: Bool
    @State private var loopStart: TimeInterval
    @State private var loopEnd: TimeInterval
    /// The last values *this* control itself wrote into `selectedRegion`/
    /// `isLoopEnabled` — the same shared state is also set from other
    /// places (the song's own transport, or this same control on a
    /// different pane), and the local `regionSelected`/`loopEnabled`/
    /// `loopStart`/`loopEnd` only ever get seeded once, at `init`. Without
    /// tracking these, there was no way for `.onChange` (below) to tell
    /// "the shared state changed because I just wrote it" (safe to ignore)
    /// apart from "something *else* changed it" (needs mirroring into this
    /// control's own local state) — so a region/toggle set anywhere else
    /// would sit invisible to this control's still-stale local state,
    /// right up until anything here next called `apply()`, which would
    /// silently overwrite that external change with its own stale idea of
    /// it. That's what made the loop region appear to randomly reset
    /// itself.
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
        _regionSelected = State(initialValue: initial != nil)
        _loopEnabled = State(initialValue: isLoopEnabled.wrappedValue)
        _loopStart = State(initialValue: initial?.lowerBound ?? 0)
        _loopEnd = State(initialValue: initial?.upperBound ?? Self.defaultLoopEnd(duration: duration, barTimes: barTimes))
        _lastWrittenRegion = State(initialValue: initial)
        _lastWrittenIsLoopEnabled = State(initialValue: isLoopEnabled.wrappedValue)
    }

    /// The region a fresh region-selection starts with — 4 bars from the
    /// start when bar data is available (`barTimes[4]` is exactly the end
    /// of the 4th bar), else the whole piece if it's shorter than that,
    /// else a flat 5-second fallback for a sequence with no bar data at
    /// all.
    private static func defaultLoopEnd(duration: TimeInterval, barTimes: [TimeInterval]) -> TimeInterval {
        if barTimes.count > 4 {
            return barTimes[4]
        } else if !barTimes.isEmpty {
            return duration
        }
        return min(duration, 5)
    }

    var body: some View {
        // The two toggles are a tight pair (8pt) — they're the same kind
        // of control, read together — but there's extra room (16pt)
        // before the scrub bar itself, which they don't sit directly on
        // top of.
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

            LoopScrubBar(
                loopEnabled: loopEnabled,
                isRegionSelected: regionSelected,
                loopStart: $loopStart,
                loopEnd: $loopEnd,
                duration: max(duration, loopEnd),
                currentTime: currentTime,
                onSeek: onSeek,
                barTimes: barTimes,
                snapPoints: snapPoints
            )
        }
        .onChange(of: regionSelected) { _, newValue in
            // A fresh default span every time selection turns on, rather
            // than resuming wherever the handles last were — predictable,
            // and matches what the old standalone reset button used to do.
            if newValue {
                loopStart = 0
                loopEnd = Self.defaultLoopEnd(duration: duration, barTimes: barTimes)
            }
            apply()
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
            regionSelected = newValue != nil
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
        let region = regionSelected ? loopStart...loopEnd : nil
        lastWrittenRegion = region
        selectedRegion = region
        lastWrittenIsLoopEnabled = loopEnabled
        isLoopEnabled = loopEnabled
    }
}
