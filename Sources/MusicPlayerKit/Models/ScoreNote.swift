import Foundation

/// One note from a parsed tab or vocal melody — used for both, since they
/// reduce to the same shape (a pitch over a span of time); tab notes
/// additionally carry which string/fret produced that pitch.
public struct ScoreNote: Sendable, Hashable {
    /// A technique tying this note to the one immediately before it,
    /// rather than it being freshly picked/attacked on its own — mirrors
    /// standard tab notation's "H"/"P"/slide-line markings.
    public enum Articulation: Sendable, Hashable {
        case hammerOn
        case pullOff
        case slide
    }

    /// Seconds from the start of the piece, resolved from the source's
    /// own note durations and tempo.
    public var startTime: TimeInterval
    public var duration: TimeInterval
    /// 0-127, standard MIDI note number.
    public var midiPitch: Int
    /// 1-6 for tab notes (low E = 6, high e = 1, matching standard tab
    /// notation numbering); nil for vocal notes.
    public var string: Int?
    /// Tab notes only; nil for vocal notes.
    public var fret: Int?
    /// Set when this note is reached via a hammer-on/pull-off/slide from
    /// the previous note rather than being picked fresh.
    public var incomingArticulation: Articulation?

    public init(
        startTime: TimeInterval,
        duration: TimeInterval,
        midiPitch: Int,
        string: Int? = nil,
        fret: Int? = nil,
        incomingArticulation: Articulation? = nil
    ) {
        self.startTime = startTime
        self.duration = duration
        self.midiPitch = midiPitch
        self.string = string
        self.fret = fret
        self.incomingArticulation = incomingArticulation
    }

    /// Standard equal-temperament conversion, A4 (MIDI 69) = 440Hz.
    public var frequency: Double {
        440.0 * pow(2.0, Double(midiPitch - 69) / 12.0)
    }
}

/// A parsed tab or vocal melody — an ordered set of notes (chords are
/// simply multiple notes sharing a `startTime`), sorted by `startTime`.
public struct NoteSequence: Sendable {
    public var notes: [ScoreNote]
    public var title: String?
    /// Beats per minute, from the source's `<sound tempo="...">` (120 if
    /// absent) — exposed for a metronome/count-in to click in time with
    /// the piece, independent of the individual note timings above.
    public var tempo: Double
    /// Start time of each `<measure>` in the source, in order — lets the
    /// UI lay the piece out as bars/lines (like a real score) and lets
    /// rewind/forward step by bar, independent of any fixed
    /// beats-per-bar assumption (works for any time signature, since it's
    /// taken directly from the source's own measure boundaries).
    public var barStartTimes: [TimeInterval]
    /// From the source's `<time><beats>` (the numerator — e.g. 4 for
    /// 4/4), 4 if absent. Used only to divide a bar into beats for
    /// `beatLabel(forStartTime:)`; a single global value, same
    /// simplification as `tempo` (a mid-piece time-signature change isn't
    /// tracked).
    public var beatsPerBar: Int

    public init(notes: [ScoreNote], title: String? = nil, tempo: Double = 120, barStartTimes: [TimeInterval] = [], beatsPerBar: Int = 4) {
        self.notes = notes.sorted { $0.startTime < $1.startTime }
        self.title = title
        self.tempo = tempo
        self.barStartTimes = barStartTimes
        self.beatsPerBar = beatsPerBar
    }

    /// Every distinct start time, in order — i.e. one entry per "beat" of
    /// the sequence, whether that beat is a single note or a chord.
    public var onsetTimes: [TimeInterval] {
        Array(Set(notes.map(\.startTime))).sorted()
    }

    /// All notes that start at once at a given onset (a chord, or a lone
    /// single note).
    public func notes(at onsetTime: TimeInterval, tolerance: TimeInterval = 0.001) -> [ScoreNote] {
        notes.filter { abs($0.startTime - onsetTime) <= tolerance }
    }

    /// The last sounding note's end time, extended to cover any trailing
    /// bars that contain no pitched notes (a rest-only tail — common when
    /// an instrument's part rests for a stretch, e.g. an intro/outro it
    /// doesn't play on). Without this, trailing rest bars would be
    /// invisible to anything sized off `duration` (average bar-width
    /// estimates, loop-region bounds, "forward" clamping), which is what
    /// caused those bars to be miscounted in early layout attempts.
    public var duration: TimeInterval {
        let noteEnd = notes.map { $0.startTime + $0.duration }.max() ?? 0
        guard barStartTimes.count > 1 else { return noteEnd }
        let gaps = zip(barStartTimes, barStartTimes.dropFirst()).map { $1 - $0 }
        let averageBarLength = gaps.reduce(0, +) / Double(gaps.count)
        let barEnd = (barStartTimes.last ?? 0) + averageBarLength
        return max(noteEnd, barEnd)
    }

    /// Average length of a bar, from the actual gaps between consecutive
    /// `barStartTimes` — not `duration / barStartTimes.count`, which
    /// silently breaks whenever the piece has trailing rest-only bars
    /// (they'd drag the "average" down well below any bar's *real*
    /// length, since `duration` itself was built from `notes` — see the
    /// property above). Used to size a score line's bars-per-row.
    public var averageBarLength: TimeInterval {
        guard barStartTimes.count > 1 else { return max(duration, 0.001) }
        let gaps = zip(barStartTimes, barStartTimes.dropFirst()).map { $1 - $0 }
        return gaps.reduce(0, +) / Double(gaps.count)
    }

    /// The start of the bar containing (or immediately before) `time` —
    /// "rewind one bar." A small epsilon means pressing this while sitting
    /// exactly at a bar's start steps back to the *previous* bar rather
    /// than staying put, matching what a musician expects from "back."
    public func barStart(before time: TimeInterval, epsilon: TimeInterval = 0.05) -> TimeInterval {
        let priorBars = barStartTimes.filter { $0 < time - epsilon }
        return priorBars.last ?? 0
    }

    /// The start of the next bar after `time` — "forward one bar." Clamps
    /// to the sequence's end if there is no further bar.
    public func barStart(after time: TimeInterval, epsilon: TimeInterval = 0.05) -> TimeInterval {
        let laterBars = barStartTimes.filter { $0 > time + epsilon }
        return laterBars.first ?? duration
    }

    /// Every beat position in the piece — each bar's downbeat plus its
    /// interior beats (per `beatsPerBar`), in order. Used for "snap to
    /// bar/beat" interactions like the loop-region scrub bar's handles.
    public var beatTimes: [TimeInterval] {
        guard !barStartTimes.isEmpty else { return [] }
        var points: [TimeInterval] = []
        for (index, barStart) in barStartTimes.enumerated() {
            let barEnd = index + 1 < barStartTimes.count ? barStartTimes[index + 1] : duration
            let beatDuration = (barEnd - barStart) / Double(max(beatsPerBar, 1))
            for beat in 0..<max(beatsPerBar, 1) {
                points.append(barStart + beatDuration * Double(beat))
            }
        }
        return points
    }

    /// Standard rhythm count-off notation for where `time` falls within
    /// its bar — "1", "2", "3", "4" on the beat, "&" on the off-beat
    /// halfway between two beats, "e"/"a" on the sixteenth-note
    /// subdivisions either side of that — i.e. the "1 e & a 2 e & a…"
    /// system musicians count subdivisions with. Quantizes to the nearest
    /// sixteenth of a beat, which is plenty for a simplified display (not
    /// engraved rhythm notation).
    public func beatLabel(forStartTime time: TimeInterval, epsilon: TimeInterval = 0.01) -> String {
        let barTime = barStartTimes.last(where: { $0 <= time + epsilon }) ?? 0
        let barEnd = barStart(after: barTime)
        let beatDuration = max(barEnd - barTime, 0.001) / Double(max(beatsPerBar, 1))
        let rawBeat = (time - barTime) / beatDuration // 0-indexed, fractional
        let quarterBeats = Int((rawBeat * 4).rounded())
        let beatNumber = quarterBeats / 4 + 1
        let subdivision = ((quarterBeats % 4) + 4) % 4
        let suffix = ["", "e", "&", "a"][subdivision]
        return "\(beatNumber)\(suffix)"
    }
}
