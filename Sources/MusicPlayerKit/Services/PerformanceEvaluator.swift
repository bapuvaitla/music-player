import Foundation
import Accelerate

/// Verifies a recorded performance against a `NoteSequence`'s known
/// expected notes.
///
/// This is deliberately *not* blind polyphonic pitch transcription (figuring
/// out an unknown chord from a raw signal with no prior is a genuine
/// research problem). The tab/melody already says exactly which note(s)
/// should be sounding at each moment, so the actual job is verification:
/// "is there energy at this *specific known* frequency right now," checked
/// independently per expected note. That's standard, well-understood DSP,
/// and it works the same whether one note or several (a chord) are expected
/// at once — no note ever needs to be identified from scratch.
public enum PerformanceEvaluator {

    /// Why a note was scored a miss — nil whenever `hit` is true.
    public enum MissReason: String, Sendable {
        /// An onset landed inside the tolerance window *and* carried a
        /// clear, different pitch of its own there — not just any nearby
        /// attack, which could just as easily be a muted/percussive hit,
        /// fret buzz, or pick scratch with no identifiable pitch at all
        /// (see `.missed`, which is what those fall under instead).
        case wrongNote
        /// Nothing landed inside the tolerance window, but the nearest
        /// onset nearby was before the expected time.
        case early
        /// Nothing landed inside the tolerance window, but the nearest
        /// onset nearby was after the expected time.
        case late
        /// Nothing pitched was found near the expected time — either no
        /// onset at all nearby, or one was (some kind of attack/transient
        /// happened), but it carried no clear identifiable pitch of its
        /// own to call a "wrong note" instead.
        case missed
    }

    public struct NoteEvaluation: Sendable, Hashable {
        public let note: ScoreNote
        public let hit: Bool
        /// Detected onset time minus the note's expected `startTime`, in
        /// seconds. Nil when no onset was found near the expected time at
        /// all (a clean miss, as opposed to a late/early but present hit).
        public let timingOffset: TimeInterval?
        /// Autocorrelation-based pitch estimate (MIDI note number) at the
        /// matched onset. Only populated when `evaluate(isVocal: true)` —
        /// meaningful only for a monophonic line, so guitar evaluation
        /// (which may be a chord) leaves this nil.
        public let detectedPitch: Int?
        public let missReason: MissReason?
    }

    public struct Result: Sendable {
        public let perNote: [NoteEvaluation]

        public init(perNote: [NoteEvaluation]) {
            self.perNote = perNote
        }

        /// Exactly on pitch *and* within `onsetTolerance` of the expected
        /// time — the strict count. Kept separate from `correctCount`
        /// (below) since some callers (e.g. change-detection in
        /// `OSMDWebView`) want the exact per-note result, not the more
        /// forgiving overall score.
        public var hitCount: Int { perNote.filter(\.hit).count }
        /// `hit`, or missed only on timing (`.early`/`.late`) — something
        /// right was genuinely played, just not exactly on the beat.
        /// Counted as correct for the overall score: an early/late label
        /// exists to show *where* a note drifted, not to flunk a note
        /// that was actually played. `.wrongNote`/`.missed` still count
        /// against it — nothing was there, or the wrong thing was.
        public var correctCount: Int {
            perNote.filter { $0.hit || $0.missReason == .early || $0.missReason == .late }.count
        }
        public var accuracy: Double {
            perNote.isEmpty ? 0 : Double(correctCount) / Double(perNote.count)
        }
    }

    /// How far (in seconds) a detected onset may fall from a note's
    /// expected start time and still count as an attempt at that note.
    /// 200ms — tight ensemble timing is closer to ±20-30ms, but that's not
    /// a fair bar for someone practicing; this stays comfortably above
    /// normal amateur timing variance without going so loose it stops
    /// meaning anything.
    public static let onsetTolerance: TimeInterval = 0.2

    /// How far (in cents — 100ths of a semitone) a detected pitch may sit
    /// from a note's exact expected frequency and still count as that
    /// note. 25 cents comfortably clears the ~99.5-cent gap that first
    /// motivated narrowing this window (see `peakMagnitude`'s doc for
    /// that history), but different strings/instruments can drift out of
    /// tune by different amounts (a wound low string is a common
    /// culprit) — not something one fixed number can account for across
    /// every guitar, which is why this is exposed the same way
    /// `onsetTolerance` is: a real default, but user-adjustable.
    public static let pitchTolerance: Double = 25.0

    /// - Parameters:
    ///   - samples: mono recorded audio, e.g. from a microphone/instrument
    ///     input tap, aligned so that `samples[0]` corresponds to
    ///     `regionStart` of `sequence` — not necessarily `t = 0`, since a
    ///     recording commonly starts partway in (e.g. at a loop region's
    ///     start) rather than at the top of the piece.
    ///   - isVocal: when true, also runs monophonic pitch tracking so a
    ///     near-miss can report *how* off-pitch it was, not just hit/miss.
    ///   - onsetTolerance: overrides `Self.onsetTolerance` — exposed as a
    ///     user-adjustable setting (see `RecordEvaluateControl`) so a
    ///     string of "miss"/"wrong" results that are actually a recording-
    ///     latency mismatch rather than genuinely bad playing can be told
    ///     apart: widen it and see if they turn into hits.
    ///   - pitchTolerance: overrides `Self.pitchTolerance`, in cents — same
    ///     idea, for a string/instrument that tends to drift further out
    ///     of tune than others.
    public static func evaluate(
        samples: [Float],
        sampleRate: Double,
        against sequence: NoteSequence,
        isVocal: Bool = false,
        regionStart: TimeInterval = 0,
        onsetTolerance: TimeInterval = Self.onsetTolerance,
        pitchTolerance: Double = Self.pitchTolerance
    ) -> Result {
        let onsets = detectOnsets(samples: samples, sampleRate: sampleRate)
        // Wider than `onsetTolerance` — purely for labeling a clean miss as
        // "early"/"late" when there's a plausible nearby onset to blame it
        // on, versus "missed" when there's genuinely nothing around. Scales
        // with a widened tolerance so it stays meaningfully wider than it,
        // rather than nearly coinciding with it at the high end.
        let nearbyRadius: TimeInterval = max(0.5, onsetTolerance * 3)

        let perNote: [NoteEvaluation] = sequence.notes.map { note in
            let relativeStart = note.startTime - regionStart
            // The *closest* onset within tolerance, not the first one in
            // time order — with a wide tolerance and closely-spaced notes
            // (a fast run is the common case, which on a guitar tends to
            // mean higher frets/notes), the window can easily contain more
            // than one real onset, e.g. this note's own attack *and* a
            // neighboring note's. `.first` always took whichever came
            // earliest regardless of which one this note's own attack
            // actually was, so `frequencyPresent` below would sometimes
            // sample the *wrong* note's onset — explaining reports of
            // widening the tolerance sometimes making pickup *worse*
            // rather than better, exactly for these fast/close passages.
            let matchingOnset = onsets
                .filter { abs($0 - relativeStart) <= onsetTolerance }
                .min(by: { abs($0 - relativeStart) < abs($1 - relativeStart) })
            let checkTime = matchingOnset ?? relativeStart
            let frequencyCheck = matchingOnset != nil
                ? checkFrequency(samples: samples, sampleRate: sampleRate, atTime: checkTime, targetFrequency: note.frequency, toleranceCents: pitchTolerance)
                : nil
            let present = frequencyCheck?.expectedPresent ?? false
            let pitch = isVocal ? detectPitch(samples: samples, sampleRate: sampleRate, atTime: checkTime) : nil

            var missReason: MissReason?
            if !present {
                if matchingOnset != nil, frequencyCheck?.hasClearAlternatePeak == true {
                    missReason = .wrongNote
                } else if matchingOnset != nil {
                    // An onset landed on time, but nothing pitched was
                    // clearly identifiable there — a muted/percussive hit,
                    // fret buzz, or pick noise, none of which are really
                    // "a different note" (see `.wrongNote`'s doc).
                    missReason = .missed
                } else if let nearest = onsets
                    .filter({ abs($0 - relativeStart) <= nearbyRadius })
                    .min(by: { abs($0 - relativeStart) < abs($1 - relativeStart) }) {
                    missReason = nearest < relativeStart ? .early : .late
                } else {
                    missReason = .missed
                }
            }

            return NoteEvaluation(
                note: note,
                hit: present,
                timingOffset: matchingOnset.map { $0 - relativeStart },
                detectedPitch: pitch,
                missReason: missReason
            )
        }
        return Result(perNote: perNote)
    }

    public static func frequency(forMIDIPitch pitch: Int) -> Double {
        440.0 * pow(2.0, (Double(pitch) - 69.0) / 12.0)
    }

    public static func midiPitch(forFrequency frequency: Double) -> Int? {
        guard frequency > 0 else { return nil }
        return Int((69.0 + 12.0 * log2(frequency / 440.0)).rounded())
    }

    // MARK: - Onset detection (spectral flux)

    /// Locates *when* something was played, independent of pitch: sums the
    /// frame-to-frame positive spectral difference (energy that appeared,
    /// ignoring energy that decayed) and flags local peaks that clear an
    /// adaptive threshold. Used both to score timing and to center each
    /// note's frequency-verification window on when it actually happened
    /// rather than only where it was expected to.
    private static func detectOnsets(samples: [Float], sampleRate: Double) -> [TimeInterval] {
        let windowSize = 2048
        let hopSize = 512

        // Real silence, prepended purely for this analysis (the original
        // `samples` — not this padded copy — is still what every other
        // check runs against). A Hann window tapers to near-zero at a
        // frame's own edges, so an attack landing right at the very start
        // of the recording — the common case for a take's first note —
        // has its transient partly swallowed by the window itself: not
        // just under-detected as an onset, but sometimes registered at an
        // imprecise moment that then makes the frequency check sample the
        // wrong slice of audio too (a spurious "wrong note" instead of a
        // miss). Half a window of padding puts a transient starting right
        // at the padding boundary close to frame 0's center — the Hann
        // window's most sensitive point — rather than its dead zone.
        let padding = [Float](repeating: 0, count: windowSize / 2)
        let paddedSamples = padding + samples
        let paddingDuration = Double(padding.count) / sampleRate

        guard paddedSamples.count >= windowSize else { return [] }

        let fft = RealFFT(size: windowSize)
        let window = hannWindow(size: windowSize)

        var flux: [Float] = []
        var times: [TimeInterval] = []
        // Alongside flux — an *absolute* floor a candidate onset also has
        // to clear (see below), not just a relative jump against
        // whatever's around it.
        var rmsValues: [Float] = []
        // Frame 0 is compared against an assumed-silent baseline (all
        // zeros) rather than skipped — it has no real previous frame, but
        // treating it as flux-less made the very first note of a take
        // structurally undetectable: there's no "before" to show a rise
        // from, no matter how cleanly it was played.
        var previousMagnitudes: [Float]?
        var index = 0
        while index + windowSize <= paddedSamples.count {
            let frame = Array(paddedSamples[index..<(index + windowSize)])
            let magnitudes = fft.magnitudes(of: frame, window: window)
            let baseline = previousMagnitudes ?? [Float](repeating: 0, count: magnitudes.count)
            var sum: Float = 0
            for bin in 0..<magnitudes.count {
                let diff = magnitudes[bin] - baseline[bin]
                if diff > 0 { sum += diff }
            }
            flux.append(sum)
            var sumSquares: Float = 0
            for sample in frame { sumSquares += sample * sample }
            rmsValues.append((sumSquares / Float(frame.count)).squareRoot())
            // Shifted back by the padding so returned onset times stay
            // aligned to the original, un-padded `samples` timeline.
            times.append(Double(index) / sampleRate - paddingDuration)
            previousMagnitudes = magnitudes
            index += hopSize
        }
        guard flux.count > 2 else { return [] }

        // Frame 0's flux is left out of the mean/variance used to set the
        // adaptive threshold — compared against silence rather than a
        // real previous frame, it's typically far larger than every other
        // frame's flux, and would otherwise drag the threshold up enough
        // to make genuine but quieter mid-recording onsets harder to
        // clear. It's still checked against that threshold afterward.
        let statsFlux = Array(flux.dropFirst())
        let mean = statsFlux.isEmpty ? 0 : statsFlux.reduce(0, +) / Float(statsFlux.count)
        let variance = statsFlux.isEmpty ? 0 : statsFlux.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) } / Float(statsFlux.count)
        let threshold = mean + 1.5 * sqrt(variance)

        // A *relative* threshold alone has no floor: in a stretch of near-
        // silence, `mean`/`variance` themselves shrink to near-zero, so
        // ordinary ambient noise (which concentrates at low frequencies —
        // room rumble, HVAC, electrical hum) trivially clears "1.5 std
        // devs above" a nearly-flat baseline and gets reported as a real
        // onset. That's what let a low string's expected note come back
        // "hit" even while nothing was actually played: an onset from
        // pure noise, followed by that same noise's low-frequency energy
        // clearing `frequencyPresent`'s check too. This absolute RMS
        // floor (same value `TunerEngine` already gates on) means a
        // candidate frame has to be genuinely audible, not just louder
        // than an already-quiet moment, to ever count.
        let minimumRMS: Float = 0.01

        var onsets: [TimeInterval] = []
        for i in 0..<flux.count {
            guard flux[i] > threshold else { continue }
            guard rmsValues[i] > minimumRMS else { continue }
            // The "local peak among neighbors" refinement only makes
            // sense with both neighbors present — frame 0 (and the very
            // last frame) just need to clear the threshold on their own.
            if i > 0, i < flux.count - 1, flux[i] < flux[i - 1] || flux[i] < flux[i + 1] { continue }
            // Collapse onsets closer together than a very short note could
            // plausibly be, rather than reporting the same pluck twice.
            if let last = onsets.last, times[i] - last < 0.1 { continue }
            onsets.append(times[i])
        }
        return onsets
    }

    // MARK: - Expected-frequency verification

    struct FrequencyCheck {
        /// Whether the *specific known* target frequency (or one of its
        /// first two harmonics) was present.
        let expectedPresent: Bool
        /// Whether the spectrum has a clear, narrow dominant peak at all
        /// — real plucked/picked/sung notes concentrate most of their
        /// energy into a handful of bins; a muted/percussive hit, fret
        /// buzz, or pick scratch doesn't, even though it still triggers a
        /// genuine onset. Only meaningful (and only checked by callers)
        /// when `expectedPresent` is false — it's what tells "a *different*
        /// note was clearly played" (`.wrongNote`) apart from "an attack
        /// happened here, but nothing pitched came out of it" (`.missed`).
        let hasClearAlternatePeak: Bool
    }

    /// Checks for energy at one *specific known* frequency around `time` —
    /// not "what pitch is this," just "is this particular pitch present" —
    /// while also characterizing the spectrum enough to tell a genuine
    /// *different* note apart from an un-pitched attack (see
    /// `FrequencyCheck.hasClearAlternatePeak`). Run once per expected
    /// note, so a chord is simply several of these checked independently.
    private static func checkFrequency(samples: [Float], sampleRate: Double, atTime time: TimeInterval, targetFrequency: Double, toleranceCents: Double) -> FrequencyCheck {
        // 16384, not 8192 — finer frequency resolution (~2.7Hz/bin instead
        // of ~5.4Hz), needed now that harmonics are checked too: two
        // unrelated notes' partials can sit close enough together that a
        // coarser window's spectral leakage bleeds across them (this is
        // what the "wrong note" test case caught — E2's 2nd harmonic and
        // D#3's fundamental are only ~9Hz apart).
        let windowSize = 16384
        guard let frame = forwardFrame(samples: samples, sampleRate: sampleRate, afterOnsetAt: time, size: windowSize) else {
            return FrequencyCheck(expectedPresent: false, hasClearAlternatePeak: false)
        }

        let fft = RealFFT(size: windowSize)
        let magnitudes = fft.magnitudes(of: frame, window: hannWindow(size: windowSize))

        // Compared against the spectrum's own dominant peak rather than
        // its median/noise-floor: a played note's fundamental should be
        // among the strongest content present, and this stays meaningful
        // even when the background is near-silent (where a median-based
        // floor is tiny enough that ordinary spectral leakage can look
        // like an enormous multiple of it).
        let globalPeak = magnitudes.max() ?? 0
        guard globalPeak > 0 else { return FrequencyCheck(expectedPresent: false, hasClearAlternatePeak: false) }

        // Checks the fundamental *and* its first two harmonics, not the
        // fundamental alone — a plucked low string's fundamental is often
        // genuinely weaker than its own harmonics (a well-known acoustic
        // effect, worse through a laptop mic's bass rolloff), so a
        // fundamental-only check under-detects exactly the notes that
        // showed it most (open low E). A hit on any of the three counts.
        var expectedPresent = false
        for multiple in [1.0, 2.0, 3.0] {
            let peak = peakMagnitude(magnitudes, near: targetFrequency * multiple, sampleRate: sampleRate, windowSize: windowSize, toleranceCents: toleranceCents)
            if peak > globalPeak * 0.15 {
                expectedPresent = true
                break
            }
        }

        // "Clearly tonal" — the dominant peak stands far enough above the
        // spectrum's own average to be a real, narrow harmonic partial
        // rather than broadband noise/an attack transient's splatter.
        // Pure noise's max-of-many-bins still clears a *low* multiple of
        // the mean fairly often just from how extreme values behave
        // across thousands of bins (this window has ~8192) — 15x sits
        // comfortably above that statistical ceiling while staying well
        // below where an actual plucked note's peak-to-mean ratio lands,
        // going by the difference between the "clean note" and "quiet
        // ambient noise" fixtures this file's own tests already cover.
        let meanMagnitude = magnitudes.reduce(0, +) / Float(magnitudes.count)
        let tonalPeakRatio: Float = 15.0
        let hasClearAlternatePeak = meanMagnitude > 0 && globalPeak > meanMagnitude * tonalPeakRatio

        return FrequencyCheck(expectedPresent: expectedPresent, hasClearAlternatePeak: hasClearAlternatePeak)
    }

    private static func peakMagnitude(_ magnitudes: [Float], near targetFrequency: Double, sampleRate: Double, windowSize: Int, toleranceCents: Double) -> Float {
        let binHz = sampleRate / Double(windowSize)
        let centerBin = Int((targetFrequency / binHz).rounded())
        // A *fixed* bin-count radius gives wildly uneven tuning tolerance
        // across the guitar's range, because bin width is a constant
        // number of Hz but tuning tolerance is inherently a constant
        // *percentage* of frequency (cents): 1 bin (~2.7Hz at this window
        // size) is a generous ~56 cents for a low E's ~82Hz fundamental,
        // but under 10 cents for a note near 1kHz — tighter than normal
        // tuning drift, which is why high notes were going almost
        // entirely undetected. Scaling the radius with frequency (a
        // user-adjustable `toleranceCents` — see `pitchTolerance`, 25
        // cents by default) fixes that, and as a side effect *tightens*
        // the window for low notes versus the old fixed 1-bin radius,
        // which helps rather than hurts: those were exactly the notes
        // prone to false hits from low-frequency ambient noise. The
        // default stays safely clear of the ~99.5-cent gap that caused
        // the original "wrong note" collision this radius was first
        // narrowed for (E2's 2nd harmonic at 164.8Hz vs. D#3's
        // fundamental at 155.6Hz) — widening it well past that reopens
        // that specific collision risk, which is worth knowing before
        // reaching for a much larger value than a semitone or so.
        let toleranceHz = targetFrequency * (pow(2.0, toleranceCents / 1200.0) - 1.0)
        let searchRadius = max(1, Int((toleranceHz / binHz).rounded(.up)))
        let lower = max(0, centerBin - searchRadius)
        let upper = min(magnitudes.count - 1, centerBin + searchRadius)
        guard lower <= upper else { return 0 }
        return magnitudes[lower...upper].max() ?? 0
    }

    // MARK: - Vocal pitch tracking (autocorrelation)

    /// Genuine open-ended monophonic pitch tracking — unlike
    /// `frequencyPresent`, this doesn't know the expected note in advance.
    /// Only meaningful for a single melodic line (vocals), which is why
    /// `evaluate` only runs it when `isVocal` is true.
    private static func detectPitch(samples: [Float], sampleRate: Double, atTime time: TimeInterval) -> Int? {
        let windowSize = 2048
        guard let frame = forwardFrame(samples: samples, sampleRate: sampleRate, afterOnsetAt: time, size: windowSize) else { return nil }

        let minFrequency = 70.0   // a bit below D2
        let maxFrequency = 1000.0 // a bit above B5
        let minLag = Int(sampleRate / maxFrequency)
        let maxLag = min(Int(sampleRate / minFrequency), frame.count - 1)
        guard minLag < maxLag else { return nil }

        var bestLag = -1
        var bestCorrelation: Float = 0
        for lag in minLag...maxLag {
            var sum: Float = 0
            for i in 0..<(frame.count - lag) {
                sum += frame[i] * frame[i + lag]
            }
            if sum > bestCorrelation {
                bestCorrelation = sum
                bestLag = lag
            }
        }
        guard bestLag > 0, bestCorrelation > 0 else { return nil }
        return midiPitch(forFrequency: sampleRate / Double(bestLag))
    }

    // MARK: - Shared helpers

    /// A window starting a little *after* `time`, deliberately not
    /// centered on it: `time` is a detected/expected onset, and a window
    /// straddling the attack itself (silence abruptly becoming a tone)
    /// picks up the attack transient's broadband spectral splatter — a
    /// sudden step carries energy at every frequency, which can fool the
    /// expected-frequency check into "detecting" a pitch that was never
    /// actually played. Skipping past the attack keeps the analysis in
    /// the note's steady state instead.
    private static func forwardFrame(samples: [Float], sampleRate: Double, afterOnsetAt time: TimeInterval, size: Int) -> [Float]? {
        let attackMargin: TimeInterval = 0.03
        let start = Int((time + attackMargin) * sampleRate)
        if start >= 0, start + size <= samples.count {
            return Array(samples[start..<(start + size)])
        }
        // Recordings commonly start or end mid-note; clamp to whatever's
        // available rather than failing outright near the edges.
        let clampedStart = max(0, min(start, samples.count - size))
        guard clampedStart >= 0, clampedStart + size <= samples.count else { return nil }
        return Array(samples[clampedStart..<(clampedStart + size)])
    }

    private static func hannWindow(size: Int) -> [Float] {
        var window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        return window
    }
}

/// Thin wrapper around vDSP's real-FFT (`vDSP_fft_zrip`), which needs a
/// power-of-two size and its own real/split-complex packing dance
/// (`vDSP_ctoz`) to get a plain sample array in and a magnitude spectrum
/// out.
private final class RealFFT {
    private let size: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup

    init(size: Int) {
        self.size = size
        self.log2n = vDSP_Length(log2(Double(size)))
        self.setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    /// Magnitude spectrum, `size / 2` bins (bin 0 = DC, bin k = `k *
    /// sampleRate / size` Hz). Values sit on vDSP's real-FFT scale (roughly
    /// 2x a textbook FFT's) — irrelevant here since callers only ever
    /// compare magnitudes from this same function against each other.
    func magnitudes(of samples: [Float], window: [Float]) -> [Float] {
        var windowed = [Float](repeating: 0, count: size)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(size))

        var real = [Float](repeating: 0, count: size / 2)
        var imag = [Float](repeating: 0, count: size / 2)
        var magnitudesSquared = [Float](repeating: 0, count: size / 2)

        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                windowed.withUnsafeBufferPointer { windowedPtr in
                    windowedPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(size / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudesSquared, 1, vDSP_Length(size / 2))
            }
        }

        var result = [Float](repeating: 0, count: size / 2)
        var count = Int32(size / 2)
        vvsqrtf(&result, magnitudesSquared, &count)
        return result
    }
}
