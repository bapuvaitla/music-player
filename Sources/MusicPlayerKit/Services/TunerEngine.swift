import Foundation
import AVFoundation

/// A standalone chromatic tuner: taps the mic (or, if selected as the Mac's
/// system input, a directly-connected instrument) and reports the nearest
/// note plus how many cents sharp/flat the detected pitch is — independent
/// of `PerformanceEvaluator`, which verifies *known* expected notes rather
/// than identifying an unknown one from scratch.
@MainActor
public final class TunerEngine: ObservableObject {
    public struct Reading: Sendable, Equatable {
        public let frequency: Double
        public let noteName: String
        /// -50...50, how far the detected pitch sits from the nearest
        /// note's exact frequency (negative = flat, positive = sharp).
        public let cents: Double
    }

    @Published public private(set) var isRunning = false
    @Published public private(set) var reading: Reading?
    /// The raw, unprocessed samples from the most recent tap buffer
    /// (roughly -1...1), refreshed every buffer purely for the popover's
    /// live waveform — not used by the pitch detector itself. Deliberately
    /// not downsampled or smoothed: an accurate (if jagged) trace of the
    /// actual signal is the point.
    @Published public private(set) var waveform: [Float] = []

    private let engine = AVAudioEngine()
    // Same reasoning as NotePlaybackEngine/AudioRecorder: written once at
    // init, read once at deinit — no real concurrent access to guard.
    private nonisolated(unsafe) var configChangeObserver: NSObjectProtocol?
    /// Cross-buffer smoothing state, in fractional MIDI note units — a raw
    /// per-buffer `detectPitch` reading jitters by a couple of cents buffer
    /// to buffer even for a dead-steady tone, which reads as a twitchy
    /// needle. Lives only on the main actor (touched only from `ingest`).
    private var smoothedMidi: Double?

    public init() {
        observeConfigurationChanges()
    }

    deinit {
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
        }
    }

    public func start() {
        guard !isRunning else { return }
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        let sampleRate = format.sampleRate
        // `@Sendable`: without it Swift infers this closure inherits
        // TunerEngine's `@MainActor` isolation (AVAudioNodeTapBlock isn't
        // itself Sendable in the SDK) and installs a runtime isolation
        // check — but AVAudioEngine always invokes tap blocks on its own
        // real-time audio thread, never the main actor, which is exactly
        // what crashed AudioRecorder before that fix. This closure only
        // calls static, stateless `TunerEngine` methods, then hops to the
        // main actor to publish the result — it never touches `self`
        // directly off-actor.
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { @Sendable pcmBuffer, _ in
            guard let channelData = pcmBuffer.floatChannelData else { return }
            let samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(pcmBuffer.frameLength)))
            let result = TunerEngine.detectPitch(samples: samples, sampleRate: sampleRate)
            Task { @MainActor [weak self] in
                self?.ingest(rawReading: result, waveform: samples)
            }
        }
        do {
            try engine.start()
            isRunning = true
        } catch {
            print("TunerEngine: failed to start audio engine: \(error)")
            input.removeTap(onBus: 0)
        }
    }

    public func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        reading = nil
        waveform = []
        smoothedMidi = nil
    }

    /// Applies cross-buffer smoothing to a raw per-buffer reading before
    /// publishing it, and always publishes the latest waveform trace
    /// regardless of whether a pitch was detected this buffer.
    private func ingest(rawReading: Reading?, waveform: [Float]) {
        self.waveform = waveform
        guard let rawReading else {
            smoothedMidi = nil
            reading = nil
            return
        }

        let rawMidi = 69.0 + 12.0 * log2(rawReading.frequency / 440.0)
        let midi: Double
        if let previous = smoothedMidi, abs(rawMidi - previous) < 1.0 {
            // A light low-pass filter, not a heavy one — enough to settle
            // the couple-of-cents buffer-to-buffer jitter without making
            // the needle feel laggy. Reset outright (below) rather than
            // filtered through when the pitch jumps by a semitone or more,
            // so switching strings doesn't drag the old note's reading
            // along with it.
            midi = previous * 0.6 + rawMidi * 0.4
        } else {
            midi = rawMidi
        }
        smoothedMidi = midi

        let nearestMidi = midi.rounded()
        let cents = (midi - nearestMidi) * 100
        let name = Self.noteNames[((Int(nearestMidi) % 12) + 12) % 12]
        let octave = Int(nearestMidi) / 12 - 1
        let smoothedFrequency = 440.0 * pow(2.0, (midi - 69.0) / 12.0)
        reading = Reading(frequency: smoothedFrequency, noteName: "\(name)\(octave)", cents: cents)
    }

    /// Same recovery Apple documents for a shared hardware device being
    /// reconfigured out from under a running engine — see
    /// NotePlaybackEngine/MetronomeEngine for the original diagnosis. No
    /// output nodes here to reconnect, just a fresh tap + restart.
    private func observeConfigurationChanges() {
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.engine.inputNode.removeTap(onBus: 0)
                self.isRunning = false
                self.start()
            }
        }
    }

    // MARK: - Pitch detection (YIN)

    private nonisolated static let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    /// Stateless and thread-safe — called directly from the real-time audio
    /// tap thread, not the main actor. `nonisolated` because a static
    /// member of a `@MainActor` class otherwise inherits that isolation too,
    /// which would make this uncallable (without an `await`) from the
    /// tap's `@Sendable`, non-isolated closure. `public` so the underlying
    /// pitch detection can be regression-tested headlessly against
    /// synthetic tones, without a real microphone.
    public nonisolated static func detectPitch(samples: [Float], sampleRate: Double) -> Reading? {
        // Below a plucked guitar string's ambient noise floor, a tuner
        // reporting a "pitch" is worse than reporting nothing at all.
        var sumSquares: Float = 0
        for sample in samples { sumSquares += sample * sample }
        let rms = (sumSquares / Float(samples.count)).squareRoot()
        guard rms > 0.01 else { return nil }

        guard let frequency = yinFrequency(samples: samples, sampleRate: sampleRate) else { return nil }

        let midi = 69.0 + 12.0 * log2(frequency / 440.0)
        let nearestMidi = midi.rounded()
        let cents = (midi - nearestMidi) * 100
        let name = noteNames[((Int(nearestMidi) % 12) + 12) % 12]
        let octave = Int(nearestMidi) / 12 - 1
        return Reading(frequency: frequency, noteName: "\(name)\(octave)", cents: cents)
    }

    /// The YIN algorithm: a cumulative-mean-normalized difference function,
    /// rather than raw autocorrelation, so a fundamental doesn't lose to
    /// its own stronger harmonic (the classic "octave error") the way plain
    /// autocorrelation can. Range covers a 7-string's low B (~61.7Hz) up
    /// through well above a 6-string's open high E (~329.6Hz), with
    /// headroom for a sharp string or a harmonic touch.
    private nonisolated static func yinFrequency(
        samples: [Float],
        sampleRate: Double,
        minFrequency: Double = 60,
        maxFrequency: Double = 500
    ) -> Double? {
        let maxLag = min(samples.count - 1, Int(sampleRate / minFrequency))
        let minLag = max(1, Int(sampleRate / maxFrequency))
        let windowSize = samples.count - maxLag
        guard maxLag > minLag, windowSize > 0 else { return nil }

        var difference = [Float](repeating: 0, count: maxLag + 1)
        for tau in 1...maxLag {
            var sum: Float = 0
            for i in 0..<windowSize {
                let delta = samples[i] - samples[i + tau]
                sum += delta * delta
            }
            difference[tau] = sum
        }

        var cumulativeMeanNormalized = [Float](repeating: 1, count: maxLag + 1)
        var runningSum: Float = 0
        for tau in 1...maxLag {
            runningSum += difference[tau]
            cumulativeMeanNormalized[tau] = runningSum > 0 ? difference[tau] * Float(tau) / runningSum : 1
        }

        // The first dip below threshold, walked forward to its local
        // minimum — not the global minimum outright, since a later, deeper
        // dip is usually an octave-down false match rather than the true
        // fundamental.
        let threshold: Float = 0.15
        var chosenTau: Int?
        var tau = minLag
        while tau <= maxLag {
            if cumulativeMeanNormalized[tau] < threshold {
                while tau + 1 <= maxLag, cumulativeMeanNormalized[tau + 1] < cumulativeMeanNormalized[tau] {
                    tau += 1
                }
                chosenTau = tau
                break
            }
            tau += 1
        }
        guard let bestTau = chosenTau ?? (minLag...maxLag).min(by: { cumulativeMeanNormalized[$0] < cumulativeMeanNormalized[$1] }),
              cumulativeMeanNormalized[bestTau] < 0.5 else {
            return nil
        }

        // Parabolic interpolation around the chosen lag for sub-sample
        // precision — needed for a tuner's cents display to actually hold
        // still rather than jitter between whole-sample frequency steps.
        var refinedTau = Double(bestTau)
        if bestTau > minLag, bestTau < maxLag {
            let s0 = Double(cumulativeMeanNormalized[bestTau - 1])
            let s1 = Double(cumulativeMeanNormalized[bestTau])
            let s2 = Double(cumulativeMeanNormalized[bestTau + 1])
            let denominator = s0 - 2 * s1 + s2
            if denominator != 0 {
                refinedTau += 0.5 * (s0 - s2) / denominator
            }
        }
        guard refinedTau > 0 else { return nil }
        return sampleRate / refinedTau
    }
}
