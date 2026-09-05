import Foundation
import AVFoundation

/// Plays a `NoteSequence` (a parsed tab or vocal melody) audibly, using
/// the General MIDI sound bank macOS already ships — no bundled samples,
/// no extra dependency. Independent of song playback (`PlayerController`)
/// by design: the tab/melody and the song are meant to run on their own
/// clocks, not stay in sync.
///
/// Scheduling uses `DispatchQueue.main.asyncAfter`, which isn't
/// sample-accurate — fine here since this is a practice reference tone,
/// not something that needs to line up with other audio to the millisecond.
@MainActor
public final class NotePlaybackEngine: ObservableObject {
    @Published public private(set) var isPlaying = false
    @Published public private(set) var currentTime: TimeInterval = 0

    /// 0...1. Zero mutes output but playback keeps running — so you can
    /// follow along silently (e.g. while being evaluated) without needing
    /// a separate pause state.
    public var volume: Float = 0.8 {
        didSet { engine.mainMixerNode.outputVolume = volume }
    }

    /// Same idea as `PlayerController.loopRegion` — loops a section of
    /// this tab/melody while practicing, independent of the song's own
    /// loop. Cleared automatically whenever a new sequence is loaded.
    public var loopRegion: ClosedRange<TimeInterval>?

    /// Fraction of normal speed, e.g. 0.5 = half speed — for slowing a
    /// passage down while practicing. Pitch is unaffected (notes are
    /// re-scheduled further apart, not resampled), which is what a
    /// practice tool wants. Re-schedules from the current position if
    /// changed mid-playback.
    public var playbackRate: Double = 1.0 {
        didSet {
            guard playbackRate != oldValue, isPlaying else { return }
            let position = currentTime
            cancelScheduledAndSilence()
            pausedAt = position
            schedule(from: position)
            startWallClock = Date().addingTimeInterval(-position / playbackRate)
        }
    }

    private let engine = AVAudioEngine()
    private let sampler = AVAudioUnitSampler()
    // `nonisolated(unsafe)`, not actor-isolated like the rest of this
    // class's state: it's written once at init and read once at deinit,
    // which Swift 6 doesn't consider guaranteed to run on the main actor —
    // there's no actual concurrent access to guard against here.
    private nonisolated(unsafe) var configChangeObserver: NSObjectProtocol?

    private var sequence = NoteSequence(notes: [])
    private var scheduledWorkItems: [DispatchWorkItem] = []
    private var activeMIDINotes: Set<UInt8> = []
    private var startWallClock: Date?
    private var pausedAt: TimeInterval = 0
    private var timer: Timer?

    private static let systemSoundBankURL = URL(
        fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls"
    )

    /// General MIDI program number — 24 = nylon acoustic guitar (the
    /// default, for tab playback), 0 = acoustic grand piano (a clear,
    /// neutral choice for following a vocal melody line).
    public init(midiProgram: UInt8 = 24) {
        engine.attach(sampler)
        engine.connect(sampler, to: engine.mainMixerNode, format: nil)
        engine.mainMixerNode.outputVolume = volume
        startEngine()
        do {
            try sampler.loadSoundBankInstrument(
                at: Self.systemSoundBankURL,
                program: midiProgram,
                bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB),
                bankLSB: UInt8(kAUSampler_DefaultBankLSB)
            )
        } catch {
            print("NotePlaybackEngine: failed to load instrument: \(error)")
        }
        observeConfigurationChanges()
    }

    deinit {
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
        }
    }

    private func startEngine() {
        // Re-establishing the connection, not just restarting — see
        // MetronomeEngine's identical fix for why a bare `engine.start()`
        // after a hardware reconfiguration isn't reliably enough on its
        // own. `connect` is safe to call again on an existing connection.
        engine.connect(sampler, to: engine.mainMixerNode, format: nil)
        do {
            try engine.start()
        } catch {
            print("NotePlaybackEngine: failed to start audio engine: \(error)")
        }
    }

    /// `AudioRecorder` adding a microphone input tap forces Core Audio to
    /// reconfigure the shared hardware device — which silently stops every
    /// other engine already running against it, this one included. This
    /// is what caused playback/metronome audio to go quiet on takes after
    /// the first Record press. Apple's documented recovery is simply to
    /// restart the engine once notified.
    private func observeConfigurationChanges() {
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.startEngine()
            }
        }
    }

    /// Loads a new sequence, stopping whatever was previously playing.
    public func load(_ newSequence: NoteSequence) {
        stop()
        sequence = newSequence
        loopRegion = nil
    }

    public func play() {
        guard !isPlaying, !sequence.notes.isEmpty else { return }
        isPlaying = true
        schedule(from: pausedAt)
        startWallClock = Date().addingTimeInterval(-pausedAt / playbackRate)
        startTimer()
    }

    public func pause() {
        guard isPlaying else { return }
        pausedAt = currentTime
        cancelScheduledAndSilence()
        isPlaying = false
        stopTimer()
    }

    public func stop() {
        cancelScheduledAndSilence()
        isPlaying = false
        pausedAt = 0
        currentTime = 0
        stopTimer()
    }

    public func seek(to time: TimeInterval) {
        let wasPlaying = isPlaying
        if wasPlaying { pause() }
        pausedAt = max(0, min(time, sequence.duration))
        currentTime = pausedAt
        if wasPlaying { play() }
    }

    private func schedule(from offset: TimeInterval) {
        for note in sequence.notes where note.startTime + note.duration > offset {
            let midiNote = UInt8(clamping: note.midiPitch)
            // A hammer-on/pull-off/slide is quieter than a freshly picked
            // note — softer velocity is a simple, safe way to make that
            // audible without attempting true legato/pitch-bend synthesis.
            let velocity: UInt8 = note.incomingArticulation == nil ? 100 : 70
            let onDelay = max(0, (note.startTime - offset) / playbackRate)
            let onItem = DispatchWorkItem { [weak self] in
                self?.activeMIDINotes.insert(midiNote)
                self?.sampler.startNote(midiNote, withVelocity: velocity, onChannel: 0)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + onDelay, execute: onItem)
            scheduledWorkItems.append(onItem)

            let offDelay = max(0, (note.startTime + note.duration - offset) / playbackRate)
            let offItem = DispatchWorkItem { [weak self] in
                self?.activeMIDINotes.remove(midiNote)
                self?.sampler.stopNote(midiNote, onChannel: 0)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + offDelay, execute: offItem)
            scheduledWorkItems.append(offItem)
        }
    }

    private func cancelScheduledAndSilence() {
        for item in scheduledWorkItems { item.cancel() }
        scheduledWorkItems.removeAll()
        for midiNote in activeMIDINotes {
            sampler.stopNote(midiNote, onChannel: 0)
        }
        activeMIDINotes.removeAll()
    }

    private func startTimer() {
        stopTimer()
        // .common, not .default — see PlayerController's identical fix
        // earlier this session: a .default-mode timer stalls during any
        // mouse-tracking loop (dragging a slider, resizing a window).
        let newTimer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.startWallClock else { return }
                self.currentTime = Date().timeIntervalSince(start) * self.playbackRate
                if let loopRegion = self.loopRegion, self.currentTime >= loopRegion.upperBound {
                    self.seek(to: loopRegion.lowerBound)
                    return
                }
                if self.currentTime >= self.sequence.duration {
                    self.stop()
                }
            }
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
