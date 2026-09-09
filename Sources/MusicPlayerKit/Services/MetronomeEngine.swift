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
    private let sampler = AVAudioUnitSampler()
    private var scheduledWorkItems: [DispatchWorkItem] = []
    // `nonisolated(unsafe)` — see NotePlaybackEngine's identical property
    // for why: written once at init, read once at deinit, no concurrent
    // access to guard against despite Swift 6's default caution here.
    private nonisolated(unsafe) var configChangeObserver: NSObjectProtocol?

    private static let systemSoundBankURL = URL(
        fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls"
    )
    /// General MIDI's percussion kit (not a melodic instrument) loaded
    /// specifically so the click can be a low wood block — a real
    /// metronome/click-track tone — rather than a musical pitch.
    private static let clickNote: UInt8 = 77 // GM percussion: Low Wood Block
    /// How long each click note is held before its note-off. The actual
    /// silent-metronome bug was here, not the instrument: `startNote`
    /// immediately followed by `stopNote` in the same closure (zero
    /// duration) rendered as silence regardless of which patch was
    /// loaded — the sampler never got a chance to sound the note.
    private static let clickDuration: TimeInterval = 0.09

    /// Same fix as `NotePlaybackEngine.hasLoadedInstrument` — loading the
    /// sound bank instrument eagerly in `init()`, right after starting the
    /// engine, is the exact ordering that produced raw beeping instead of
    /// the loaded click tone there; deferring it to the first actual click
    /// (see `ensureEngineStarted()`) fixed it. This class never got that
    /// fix and used the old eager-load-in-init pattern, which is why the
    /// metronome can come back as a plain beep instead of the intended
    /// wood-block tone.
    private var hasLoadedInstrument = false

    public init() {
        engine.attach(sampler)
        engine.connect(sampler, to: engine.mainMixerNode, format: nil)
        engine.mainMixerNode.outputVolume = volume
        // Neither the engine start nor the instrument load happens here —
        // see `ensureEngineStarted()`, called from the first actual click.
        observeConfigurationChanges()
    }

    deinit {
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
        }
    }

    private func ensureEngineStarted() {
        // Re-establishing the connection, not just restarting, matters
        // here: a hardware reconfiguration can force the engine onto a
        // different internal processing format, and a bare `engine.start()`
        // after that would either throw or come back up with the sampler
        // not actually routed to the mixer — silence, or (worse) audio
        // that stops partway through a count-in already in flight, since
        // the reconnect never happened. `connect` is safe to call again on
        // an existing connection.
        engine.connect(sampler, to: engine.mainMixerNode, format: nil)
        do {
            try engine.start()
        } catch {
            print("MetronomeEngine: failed to start audio engine: \(error)")
        }
        // Loading the instrument only after the engine has actually
        // started (and reloading it after every *reconfiguration*, not
        // just the very first start — see `observeConfigurationChanges`)
        // is what avoids the raw-beeping failure mode.
        if !hasLoadedInstrument {
            do {
                try sampler.loadSoundBankInstrument(
                    at: Self.systemSoundBankURL,
                    program: 0,
                    bankMSB: UInt8(kAUSampler_DefaultPercussionBankMSB),
                    bankLSB: UInt8(kAUSampler_DefaultBankLSB)
                )
                hasLoadedInstrument = true
            } catch {
                print("MetronomeEngine: failed to load click instrument: \(error)")
            }
        }
    }

    /// Same fix as `NotePlaybackEngine` — `AudioRecorder` adding a
    /// microphone input tap reconfigures the shared hardware device and
    /// silently stops every other engine already running, this one
    /// included (the missing count-in/click audio on takes after the
    /// first Record press). Restarting once notified recovers it. Unlike
    /// a normal click-triggered start, a genuine hardware reconfiguration
    /// can leave the sampler connected but voiceless even though
    /// `hasLoadedInstrument` is already true — force a fresh reload here
    /// rather than skipping it, since this event is rare enough that the
    /// extra load is cheap either way.
    private func observeConfigurationChanges() {
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.hasLoadedInstrument = false
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
        sampler.stopNote(Self.clickNote, onChannel: 0)
    }

    private func scheduleClick(after delay: TimeInterval) {
        let onItem = DispatchWorkItem { [weak self] in
            self?.sampler.startNote(Self.clickNote, withVelocity: 110, onChannel: 0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: onItem)
        scheduledWorkItems.append(onItem)

        let offItem = DispatchWorkItem { [weak self] in
            self?.sampler.stopNote(Self.clickNote, onChannel: 0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + Self.clickDuration, execute: offItem)
        scheduledWorkItems.append(offItem)
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
            self?.sampler.startNote(Self.clickNote, withVelocity: 110, onChannel: 0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + targetDelay, execute: onItem)
        scheduledWorkItems.append(onItem)

        let offItem = DispatchWorkItem { [weak self] in
            self?.sampler.stopNote(Self.clickNote, onChannel: 0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + targetDelay + Self.clickDuration, execute: offItem)
        scheduledWorkItems.append(offItem)

        let nextItem = DispatchWorkItem { [weak self] in
            self?.scheduleSteadyClick(anchor: anchor, beatInterval: beatInterval, beatIndex: beatIndex + 1)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + targetDelay, execute: nextItem)
        scheduledWorkItems.append(nextItem)
    }
}
