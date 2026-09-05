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
        /// Something was clearly played right on time (an onset landed
        /// inside the tolerance window) — just not the expected pitch.
        case wrongNote
        /// Nothing landed inside the tolerance window, but the nearest
        /// onset nearby was before the expected time.
        case early
        /// Nothing landed inside the tolerance window, but the nearest
        /// onset nearby was after the expected time.
        case late
        /// No onset at all was found anywhere near the expected time.
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

        public var hitCount: Int { perNote.filter(\.hit).count }
        public var accuracy: Double {
            perNote.isEmpty ? 0 : Double(hitCount) / Double(perNote.count)
        }
    }

    /// How far (in seconds) a detected onset may fall from a note's
    /// expected start time and still count as an attempt at that note.
    /// 200ms — tight ensemble timing is closer to ±20-30ms, but that's not
    /// a fair bar for someone practicing; this stays comfortably above
    /// normal amateur timing variance without going so loose it stops
    /// meaning anything.
    public static let onsetTolerance: TimeInterval = 0.2

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
    public static func evaluate(
        samples: [Float],
        sampleRate: Double,
        against sequence: NoteSequence,
        isVocal: Bool = false,
        regionStart: TimeInterval = 0,
        onsetTolerance: TimeInterval = Self.onsetTolerance
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
            let matchingOnset = onsets.first { abs($0 - relativeStart) <= onsetTolerance }
            let checkTime = matchingOnset ?? relativeStart
            let present = matchingOnset != nil
                && frequencyPresent(samples: samples, sampleRate: sampleRate, atTime: checkTime, frequency: note.frequency)
            let pitch = isVocal ? detectPitch(samples: samples, sampleRate: sampleRate, atTime: checkTime) : nil

            var missReason: MissReason?
            if !present {
                if matchingOnset != nil {
                    missReason = .wrongNote
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

        var onsets: [TimeInterval] = []
        for i in 0..<flux.count {
            guard flux[i] > threshold else { continue }
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

    /// Checks for energy at one *specific known* frequency around `time` —
    /// not "what pitch is this," just "is this particular pitch present."
    /// Run once per expected note, so a chord is simply several of these
    /// checked independently.
    private static func frequencyPresent(samples: [Float], sampleRate: Double, atTime time: TimeInterval, frequency: Double) -> Bool {
        // 16384, not 8192 — finer frequency resolution (~2.7Hz/bin instead
        // of ~5.4Hz), needed now that harmonics are checked too: two
        // unrelated notes' partials can sit close enough together that a
        // coarser window's spectral leakage bleeds across them (this is
        // what the "wrong note" test case caught — E2's 2nd harmonic and
        // D#3's fundamental are only ~9Hz apart).
        let windowSize = 16384
        guard let frame = forwardFrame(samples: samples, sampleRate: sampleRate, afterOnsetAt: time, size: windowSize) else { return false }

        let fft = RealFFT(size: windowSize)
        let magnitudes = fft.magnitudes(of: frame, window: hannWindow(size: windowSize))

        // Compared against the spectrum's own dominant peak rather than
        // its median/noise-floor: a played note's fundamental should be
        // among the strongest content present, and this stays meaningful
        // even when the background is near-silent (where a median-based
        // floor is tiny enough that ordinary spectral leakage can look
        // like an enormous multiple of it).
        let globalPeak = magnitudes.max() ?? 0
        guard globalPeak > 0 else { return false }

        // Checks the fundamental *and* its first two harmonics, not the
        // fundamental alone — a plucked low string's fundamental is often
        // genuinely weaker than its own harmonics (a well-known acoustic
        // effect, worse through a laptop mic's bass rolloff), so a
        // fundamental-only check under-detects exactly the notes that
        // showed it most (open low E). A hit on any of the three counts.
        for multiple in [1.0, 2.0, 3.0] {
            let peak = peakMagnitude(magnitudes, near: frequency * multiple, sampleRate: sampleRate, windowSize: windowSize)
            if peak > globalPeak * 0.15 {
                return true
            }
        }
        return false
    }

    private static func peakMagnitude(_ magnitudes: [Float], near targetFrequency: Double, sampleRate: Double, windowSize: Int) -> Float {
        let binHz = sampleRate / Double(windowSize)
        let centerBin = Int((targetFrequency / binHz).rounded())
        // 1 bin, not 2: now that `frequencyPresent` checks two harmonics
        // in addition to the fundamental, a wider radius here let a wrong
        // note's own fundamental get mistaken for the expected note's
        // harmonic when the two landed close together (e.g. E2's 2nd
        // harmonic at 164.8Hz sits within 2 bins of D#3's fundamental at
        // 155.6Hz) — this stays generous enough for realistic tuning
        // drift (~5Hz at these frequencies is still several times more
        // slack than a guitar even noticeably out of tune would need).
        let searchRadius = 1
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
