import Foundation
import AVFoundation

/// Plays several `NoteSequence`s simultaneously, each on its own
/// instrument — for the Full Score view, where a combined multi-part
/// MusicXML file (e.g. Voice + Guitar Notation + Guitar Tab) needs to
/// sound like Voice and Guitar together, not the same guitar line played
/// twice. `NotePlaybackEngine` plays exactly one `NoteSequence` on one
/// sampler; this generalizes that to N sequences on N samplers sharing
/// one `AVAudioEngine`, with each track individually mutable so a
/// duplicate part (Guitar Notation vs. Guitar Tab) can be silenced
/// without removing it from the score.
///
/// Same scheduling approach as `NotePlaybackEngine`
/// (`DispatchQueue.main.asyncAfter`, not sample-accurate — fine for a
/// practice reference tone) and the same engine-start/instrument-load
/// ordering fix (deferred to first `play()`, instrument loaded only
/// after the engine has actually started).
@MainActor
public final class MultiTrackPlaybackEngine: ObservableObject {
    public struct Track {
        public var name: String
        public var sequence: NoteSequence
        public var midiProgram: UInt8
        public var isEnabled: Bool

        public init(name: String, sequence: NoteSequence, midiProgram: UInt8, isEnabled: Bool = true) {
            self.name = name
            self.sequence = sequence
            self.midiProgram = midiProgram
            self.isEnabled = isEnabled
        }
    }

    @Published public private(set) var isPlaying = false
    @Published public private(set) var currentTime: TimeInterval = 0
    @Published public private(set) var tracks: [Track] = []

    public var volume: Float = 0.8 {
        didSet { engine.mainMixerNode.outputVolume = volume }
    }
    public var loopRegion: ClosedRange<TimeInterval>?
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

    /// The longest of the loaded tracks' own durations — so a shorter
    /// part (e.g. Voice resting for stretches) doesn't cut playback short
    /// while a longer one (e.g. Guitar) is still going.
    public var duration: TimeInterval {
        tracks.map { $0.sequence.duration }.max() ?? 0
    }

    private let engine = AVAudioEngine()
    private var samplers: [AVAudioUnitSampler] = []
    private nonisolated(unsafe) var configChangeObserver: NSObjectProtocol?

    private var scheduledWorkItems: [DispatchWorkItem] = []
    private var startWallClock: Date?
    private var pausedAt: TimeInterval = 0
    private var timer: Timer?
    /// See `NotePlaybackEngine.hasLoadedInstrument` — same fix, same
    /// reason: loading an instrument before the engine has ever started
    /// left samplers producing raw beeping instead of their patch's tone.
    private var hasLoadedInstruments = false

    private static let systemSoundBankURL = URL(
        fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls"
    )

    public init() {
        observeConfigurationChanges()
    }

    deinit {
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
        }
    }

    /// Replaces the full set of tracks — one sampler per track, attached
    /// fresh each time since each needs its own instrument loaded.
    /// Stops whatever was previously playing.
    public func load(_ newTracks: [Track]) {
        stop()
        for sampler in samplers {
            engine.disconnectNodeOutput(sampler)
            engine.detach(sampler)
        }
        samplers.removeAll()
        tracks = newTracks
        for _ in newTracks {
            let sampler = AVAudioUnitSampler()
            engine.attach(sampler)
            engine.connect(sampler, to: engine.mainMixerNode, format: nil)
            samplers.append(sampler)
        }
        hasLoadedInstruments = false
        loopRegion = nil
    }

    /// Mutes/unmutes one track without re-loading anything — used for the
    /// Full Score view's per-part toggles (e.g. muting Guitar Tab when
    /// Guitar Notation is already sounding the same line). Re-schedules
    /// from the current position if already playing, so the change is
    /// heard immediately rather than on the next seek.
    public func setTrack(at index: Int, enabled: Bool) {
        guard tracks.indices.contains(index), tracks[index].isEnabled != enabled else { return }
        tracks[index].isEnabled = enabled
        if isPlaying {
            let position = currentTime
            cancelScheduledAndSilence()
            schedule(from: position)
        }
    }

    private func startEngineAndLoadInstruments() {
        // Re-establishing every sampler's connection, not just restarting
        // the engine — see `NotePlaybackEngine.startEngine`'s identical
        // comment on why a bare `engine.start()` after a hardware
        // reconfiguration isn't reliably enough on its own.
        for sampler in samplers {
            engine.connect(sampler, to: engine.mainMixerNode, format: nil)
        }
        do {
            try engine.start()
        } catch {
            print("MultiTrackPlaybackEngine: failed to start audio engine: \(error)")
        }
        guard !hasLoadedInstruments else { return }
        for (index, sampler) in samplers.enumerated() {
            guard tracks.indices.contains(index) else { continue }
            do {
                try sampler.loadSoundBankInstrument(
                    at: Self.systemSoundBankURL,
                    program: tracks[index].midiProgram,
                    bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB),
                    bankLSB: UInt8(kAUSampler_DefaultBankLSB)
                )
            } catch {
                print("MultiTrackPlaybackEngine: failed to load instrument for track \(index): \(error)")
            }
        }
        hasLoadedInstruments = true
    }

    /// Same fix as `NotePlaybackEngine`/`MetronomeEngine` — a microphone
    /// input tap elsewhere in the app reconfigures the shared hardware
    /// device and silently stops every engine already running against it.
    private func observeConfigurationChanges() {
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.startEngineAndLoadInstruments()
            }
        }
    }

    public func play() {
        guard !isPlaying, !tracks.isEmpty else { return }
        // Not just `if !engine.isRunning` — `load()` (a Replace…) attaches
        // fresh samplers and resets `hasLoadedInstruments` to false, but
        // leaves the shared engine running if it already was. Gating
        // solely on `engine.isRunning` skipped this call entirely in that
        // case, so the newly attached samplers never got their instrument
        // loaded and fell back to raw beeping. Both checks route through
        // the same function, which already no-ops whichever half doesn't
        // need doing.
        if !engine.isRunning || !hasLoadedInstruments { startEngineAndLoadInstruments() }
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
        pausedAt = max(0, min(time, duration))
        currentTime = pausedAt
        if wasPlaying { play() }
    }

    private func schedule(from offset: TimeInterval) {
        for (index, track) in tracks.enumerated() where track.isEnabled {
            guard samplers.indices.contains(index) else { continue }
            let sampler = samplers[index]
            for note in track.sequence.notes where note.startTime + note.duration > offset {
                let midiNote = UInt8(clamping: note.midiPitch)
                // A hammer-on/pull-off/slide is quieter than a freshly
                // picked note — same convention as NotePlaybackEngine.
                let velocity: UInt8 = note.incomingArticulation == nil ? 100 : 70
                let onDelay = max(0, (note.startTime - offset) / playbackRate)
                let onItem = DispatchWorkItem { [weak sampler] in
                    sampler?.startNote(midiNote, withVelocity: velocity, onChannel: 0)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + onDelay, execute: onItem)
                scheduledWorkItems.append(onItem)

                let offDelay = max(0, (note.startTime + note.duration - offset) / playbackRate)
                let offItem = DispatchWorkItem { [weak sampler] in
                    sampler?.stopNote(midiNote, onChannel: 0)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + offDelay, execute: offItem)
                scheduledWorkItems.append(offItem)
            }
        }
    }

    private func cancelScheduledAndSilence() {
        for item in scheduledWorkItems { item.cancel() }
        scheduledWorkItems.removeAll()
        // Simpler than NotePlaybackEngine's exact-active-note tracking —
        // with N samplers each needing their own active-note bookkeeping,
        // just silencing every possible note on every sampler on
        // pause/stop (a few hundred harmless no-op calls) was less
        // machinery for the same result.
        for sampler in samplers {
            for note: UInt8 in 0...127 {
                sampler.stopNote(note, onChannel: 0)
            }
        }
    }

    private func startTimer() {
        stopTimer()
        let newTimer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.startWallClock else { return }
                self.currentTime = Date().timeIntervalSince(start) * self.playbackRate
                if let loopRegion = self.loopRegion, self.currentTime >= loopRegion.upperBound {
                    self.seek(to: loopRegion.lowerBound)
                    return
                }
                if self.currentTime >= self.duration {
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
