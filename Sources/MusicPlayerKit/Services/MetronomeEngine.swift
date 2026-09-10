import Foundation
import AVFoundation

/// A simple audible click track for a Record/Evaluate session — a 4-beat
/// count-in before capture starts, and/or a steady click for the duration
/// of the take. Independent of `NotePlaybackEngine`: ticks are scheduled
/// purely from a BPM value, not derived from any `NoteSequence`'s notes.
@MainActor
public final class MetronomeEngine: ObservableObject {
    /// 0...1. Halfway up the slider by default, not maxed or barely-there
    /// — an easy, obvious starting point to adjust from either direction.
    public var volume: Float = 0.5 {
        didSet { engine.mainMixerNode.outputVolume = volume }
    }

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    /// A short synthesized "thock," not a sampled instrument — this used
    /// to load General MIDI's "Low Wood Block" patch from Apple's built-in
    /// `gs_instruments.dls` soundfont, but that patch (like most of that
    /// soundfont) is a thin, dated sample that reads as a plain electronic
    /// beep rather than anything wood-like, no matter how correctly it's
    /// triggered. Synthesizing the click directly — a damped tone plus a
    /// slightly-detuned overtone, both under a fast exponential decay —
    /// gives a warmer, percussive "thock" with full control over the
    /// timbre, and sidesteps this class's whole prior history of sound-
    /// bank loading-order bugs entirely (see git history for the two
    /// separate "metronome comes back as a plain beep" incidents that
    /// caused).
    private let clickBuffer: AVAudioPCMBuffer
    private var scheduledWorkItems: [DispatchWorkItem] = []
    // `nonisolated(unsafe)` — see NotePlaybackEngine's identical property
    // for why: written once at init, read once at deinit, no concurrent
    // access to guard against despite Swift 6's default caution here.
    private nonisolated(unsafe) var configChangeObserver: NSObjectProtocol?

    /// How long the click's synthesized decay runs before it's
    /// effectively silent — used only to know when it's safe to schedule
    /// the *next* click without the two overlapping oddly at fast tempos.
    private static let clickDuration: TimeInterval = 0.09

    public init() {
        let sampleRate = 44100.0
        clickBuffer = Self.makeClickBuffer(sampleRate: sampleRate)
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: clickBuffer.format)
        engine.mainMixerNode.outputVolume = volume
        // Engine start is deferred to the first actual click (see
        // `ensureEngineStarted()`), same as before — no instrument to
        // eagerly (mis)load anymore, but starting the engine itself still
        // waits, consistent with every other engine in this app.
        observeConfigurationChanges()
    }

    deinit {
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
        }
    }

    /// A fast attack, fast-decaying tone plus a slightly-detuned, quieter
    /// overtone — the detuning (not a clean harmonic ratio) is what reads
    /// as "wood" rather than "bell" or "beep": real wood has inharmonic,
    /// not purely harmonic, resonant modes. The envelope's decay (~18ms)
    /// is what makes it a percussive knock instead of a sustained tone.
    private static func makeClickBuffer(sampleRate: Double) -> AVAudioPCMBuffer {
        let duration: TimeInterval = 0.07
        let frameCount = AVAudioFrameCount(duration * sampleRate)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            fatalError("MetronomeEngine: failed to allocate click buffer")
        }
        buffer.frameLength = frameCount
        let data = buffer.floatChannelData![0]

        let fundamental = 1100.0   // Hz — in a plausible wood-block range
        let overtone = fundamental * 2.76 // inharmonic, not a clean 2x/3x ratio
        let decayTau = 0.016       // seconds — fast decay = a "thock," not a beep

        for i in 0..<Int(frameCount) {
            let t = Double(i) / sampleRate
            let envelope = exp(-t / decayTau)
            let tone = sin(2 * .pi * fundamental * t) + 0.32 * sin(2 * .pi * overtone * t)
            data[i] = Float(tone * envelope * 0.6)
        }
        return buffer
    }

    private func ensureEngineStarted() {
        // Re-establishing the connection, not just restarting, matters
        // here: a hardware reconfiguration can force the engine onto a
        // different internal processing format, and a bare `engine.start()`
        // after that would either throw or come back up with the player
        // node not actually routed to the mixer — silence, or (worse)
        // audio that stops partway through a count-in already in flight,
        // since the reconnect never happened. `connect` is safe to call
        // again on an existing connection.
        engine.connect(playerNode, to: engine.mainMixerNode, format: clickBuffer.format)
        do {
            try engine.start()
            // A player node's `play()` puts it in a "ready to render
            // scheduled buffers" state — persistent, not per-buffer — so
            // this only needs calling once the engine is actually up
            // (including after a reconfiguration-triggered restart).
            playerNode.play()
        } catch {
            print("MetronomeEngine: failed to start audio engine: \(error)")
        }
    }

    /// `AudioRecorder` adding a microphone input tap reconfigures the
    /// shared hardware device and silently stops every other engine
    /// already running, this one included (the missing count-in/click
    /// audio on takes after the first Record press) — see
    /// `NotePlaybackEngine`'s identical fix. Restarting (and re-playing
    /// the player node) once notified recovers it.
    private func observeConfigurationChanges() {
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.ensureEngineStarted()
            }
        }
    }

    /// Schedules `count` evenly-spaced clicks starting immediately, then
    /// calls `completion` once the last one has sounded — used for a
    /// count-in before a take actually begins.
    public func playClicks(count: Int, beatInterval: TimeInterval, completion: @escaping () -> Void = {}) {
        ensureEngineStarted()
        cancel()
        for beat in 0..<count {
            scheduleClick(after: beatInterval * Double(beat))
        }
        let completionItem = DispatchWorkItem(block: completion)
        DispatchQueue.main.asyncAfter(deadline: .now() + beatInterval * Double(count), execute: completionItem)
        scheduledWorkItems.append(completionItem)
    }

    /// Starts a steady click every `beatInterval` seconds until `cancel()`.
    public func startSteadyClick(beatInterval: TimeInterval) {
        ensureEngineStarted()
        cancel()
        scheduleSteadyClick(anchor: Date(), beatInterval: beatInterval, beatIndex: 0)
    }

    public func cancel() {
        for item in scheduledWorkItems { item.cancel() }
        scheduledWorkItems.removeAll()
        playerNode.stop()
        playerNode.play()
    }

    private func scheduleClick(after delay: TimeInterval) {
        let onItem = DispatchWorkItem { [weak self] in
            self?.fireClick()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: onItem)
        scheduledWorkItems.append(onItem)
    }

    private func fireClick() {
        playerNode.scheduleBuffer(clickBuffer, at: nil, options: .interrupts)
    }

    /// Recursively schedules one beat at a time, but every beat's target
    /// time is computed from the same fixed `anchor`, not from "now" at
    /// the moment the previous beat's closure happened to actually run.
    /// The previous version rescheduled each click `beatInterval` from
    /// "now" — so any delay in a click actually firing (main-thread
    /// contention is routine in a SwiftUI app: view updates, the live
    /// evaluator's own FFT work while recording, etc.) pushed every
    /// following click later too, compounding beat after beat rather than
    /// the tempo just recovering on the next beat. Anchoring every beat's
    /// target to a fixed start time keeps that from accumulating — an
    /// individual click can still land a touch late if the main thread is
    /// busy right when it's due, but it won't drag the whole rest of the
    /// take's tempo down with it.
    private func scheduleSteadyClick(anchor: Date, beatInterval: TimeInterval, beatIndex: Int) {
        let targetDelay = max(0, anchor.addingTimeInterval(beatInterval * Double(beatIndex)).timeIntervalSinceNow)

        let onItem = DispatchWorkItem { [weak self] in
            self?.fireClick()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + targetDelay, execute: onItem)
        scheduledWorkItems.append(onItem)

        let nextItem = DispatchWorkItem { [weak self] in
            self?.scheduleSteadyClick(anchor: anchor, beatInterval: beatInterval, beatIndex: beatIndex + 1)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + targetDelay, execute: nextItem)
        scheduledWorkItems.append(nextItem)
    }
}
