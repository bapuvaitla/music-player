import SwiftUI
import MusicPlayerKit

/// Drives one pane's "Record" workflow: plays the reference sequence as a
/// guide (mute it via the pane's own volume slider to play along silently)
/// while capturing microphone/instrument input, running `PerformanceEvaluator`
/// against each expected note as soon as enough of the take has been
/// captured to score it — the caller (`LearnSongView`) feeds the growing
/// result back into `TabGridView`/`PitchLineView` as a hit/miss overlay
/// that fills in live, note by note, rather than only appearing once
/// recording stops. Optionally prefaces the take with a 4-beat count-in
/// and/or clicks a steady metronome beat for its duration, both at the
/// sequence's own tempo.
struct RecordEvaluateControl: View {
    @ObservedObject var engine: NotePlaybackEngine
    @ObservedObject var recorder: AudioRecorder
    let sequence: NoteSequence
    /// A region can be selected independent of whether it loops — see
    /// `isLoopEnabled`. Always used to scope a take's start/end when set,
    /// regardless of looping.
    let selectedRegion: ClosedRange<TimeInterval>?
    /// The one shared loop toggle (see the loop control above the score,
    /// or the song's own transport at the bottom of the window — both set
    /// this and `selectedRegion` together). When on, reaching the end of
    /// `selectedRegion` during a take doesn't stop it — a fresh take
    /// starts right back up at `regionStart` automatically, over and
    /// over, until "Stop" is pressed. With no region selected, `regionStart`/
    /// `regionEnd` span the whole sequence, so this loops entire takes of
    /// the full song instead. Each lap is a genuinely new,
    /// independently-scored take (see the `liveEvaluationTimer` closure
    /// below), not one long recording spanning every lap — simpler, and
    /// it keeps a very long drill session from growing one unbounded
    /// in-memory buffer.
    let isLoopEnabled: Bool
    let isVocal: Bool
    @Binding var result: PerformanceEvaluator.Result?

    @StateObject private var metronome = MetronomeEngine()
    @State private var leadInEnabled = true
    @State private var metronomeEnabled = true
    @State private var isRecordingSession = false
    @State private var isCountingIn = false
    @State private var savedLoopRegion: ClosedRange<TimeInterval>?
    @State private var showingOptionsPopover = false
    @State private var liveEvaluationTimer: Timer?
    /// How far a detected onset may fall from a note's expected time and
    /// still count as an attempt at it — user-adjustable so a run of
    /// "miss"/"wrong" results that's actually a recording-latency mismatch
    /// (not genuinely bad playing) can be told apart: widen this and see
    /// if they turn into hits. Persisted, since it's as much a difficulty
    /// setting as a diagnostic one.
    @AppStorage("recordOnsetTolerance") private var onsetTolerance: Double = PerformanceEvaluator.onsetTolerance
    /// How far (in cents) a detected pitch may sit from a note's exact
    /// expected frequency and still count as that note — user-adjustable
    /// for the same reason `onsetTolerance` is, but for pitch instead of
    /// timing: some strings (a wound low string is a common culprit) or
    /// instruments drift out of tune more than others, and no single
    /// fixed tolerance suits every setup. Persisted alongside
    /// `onsetTolerance` as a difficulty/calibration setting, not just a
    /// diagnostic one.
    @AppStorage("recordPitchTolerance") private var pitchTolerance: Double = PerformanceEvaluator.pitchTolerance
    /// Notes already scored by the live in-progress pass — `finishRecording`
    /// only needs to catch whatever's left (typically the last note or two
    /// near the end of the take), not redo the whole thing.
    @State private var evaluatedNotes: Set<ScoreNote> = []
    /// The real wall-clock moment `recorder.start()` was called — paired
    /// with `engine.startWallClock` (set once playback's own anchor is
    /// captured) to *measure* `captureLeadTime` instead of assuming it.
    @State private var recordingStartedAt: Date?

    /// How much earlier than `regionStart` the recording buffer actually
    /// begins — the count-in's own duration, when there is one. Recording
    /// starts alongside the count-in rather than after it (see
    /// `startRecording`), so this offset has to be subtracted out when
    /// telling `PerformanceEvaluator` what `samples[0]` corresponds to.
    ///
    /// *Measured* against `engine.startWallClock` — the actual wall-clock
    /// moment playback's own anchor was captured — rather than assumed
    /// from `beatInterval * 4` (the count-in's nominal duration). Those
    /// two aren't guaranteed to match: `engine.play()` deliberately
    /// captures its anchor from *inside* a dispatched closure specifically
    /// to absorb any real scheduling/cold-start delay between being asked
    /// to play and audio actually starting (worst right after a cold
    /// engine start, still loading its instrument) — see that doc comment
    /// for the full story. That delay was already being correctly kept
    /// out of the engine's own `currentTime`/playhead; it just wasn't
    /// being kept out of *this* number, which is exactly what was making
    /// the very first note or two of a take (right after the count-in, or
    /// right after a cold start) misalign against the actual recording —
    /// a fixed theoretical guess doesn't know about a delay that only
    /// really shows up on, say, the very first take of a session.
    private var captureLeadTime: TimeInterval {
        guard let recordingStartedAt, let anchor = engine.startWallClock else {
            // Anchor not captured yet (a runloop tick hasn't passed since
            // `play()`) — falls back to the theoretical value for that
            // brief window rather than reading 0, which would be a worse
            // guess than the nominal count-in duration.
            return leadInEnabled ? beatInterval * 4 : 0
        }
        let dateAtRegionStart = anchor.addingTimeInterval(regionStart / engine.playbackRate)
        return dateAtRegionStart.timeIntervalSince(recordingStartedAt)
    }

    private var regionStart: TimeInterval { selectedRegion?.lowerBound ?? 0 }
    private var regionEnd: TimeInterval { selectedRegion?.upperBound ?? sequence.duration }
    /// Uses `sequence.tempo(atTime:)`, not the flat `sequence.tempo` —
    /// for a piece with more than one `<sound tempo>` marking, the flat
    /// value is just whichever one parsing saw last, which raced ahead
    /// of (or lagged) a loop region using a different, earlier tempo even
    /// though each note's own timing was always resolved correctly. Also
    /// scaled by the practice-speed slider (`engine.playbackRate`) — the
    /// metronome previously always clicked at the piece's nominal tempo
    /// regardless of that slider, so slowing playback down to practice a
    /// hard passage left the click racing ahead of the actual notes
    /// instead of staying with them. Dividing (not multiplying) is
    /// correct: half the rate means double the time between beats.
    private var beatInterval: TimeInterval { 60.0 / max(sequence.tempo(atTime: regionStart), 1) / engine.playbackRate }
    /// Drives the settings icon's filled/outline state — true when
    /// anything in that popover is set away from its plain default, so
    /// glancing at the icon says whether something's been customized
    /// without opening it.
    private var settingsActive: Bool { leadInEnabled || metronomeEnabled }

    var body: some View {
        HStack(spacing: 12) {
            Button(isRecordingSession ? "Stop" : (isVocal ? "Sing Along…" : "Play Along…")) {
                isRecordingSession ? finishRecording() : startRecording()
            }
            .controlSize(.large)
            .tint(isRecordingSession ? .red : nil)

            // The loop toggle itself lives above the score now (see the
            // loop control there, or the song's own transport at the
            // bottom of the window — both set the same one shared
            // `isLoopEnabled`/`selectedRegion` pair) — no separate toggle
            // here anymore, since "loop this region" meant two different
            // things depending which one you touched (this one only
            // repeated takes; the other only looped normal playback).

            // Smaller and more muted than "Play Along…" so it doesn't
            // compete with the primary action — but not so faint it's
            // hard to notice. Everything about how a take runs and is
            // scored lives in here — count-in/metronome and timing/pitch
            // tolerance — one icon and one popover, since none of these
            // get touched often enough mid-session to earn a dedicated
            // icon of their own. Practice speed lives on the BPM readout
            // above the score instead (see `InstrumentTransportView`).
            Button {
                showingOptionsPopover = true
            } label: {
                Image(systemName: settingsActive ? "gearshape.fill" : "gearshape")
                    .font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(isRecordingSession)
            .help("Count-in, metronome, and tolerance settings")
            .popover(isPresented: $showingOptionsPopover, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    settingsSectionHeader("Count-In & Metronome")
                    Toggle("4-beat lead-in", isOn: $leadInEnabled)
                        .toggleStyle(.checkbox)
                    Toggle("Metronome", isOn: $metronomeEnabled)
                        .toggleStyle(.checkbox)
                    if metronomeEnabled {
                        HStack(spacing: 8) {
                            Image(systemName: "speaker.fill").font(.system(size: 11))
                            Slider(
                                value: Binding(
                                    get: { Double(metronome.volume) },
                                    set: { metronome.volume = Float($0) }
                                ),
                                in: 0...1
                            )
                            .frame(width: 110)
                        }
                    }

                    Divider()

                    settingsSectionHeader("Tolerance")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Timing")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Slider(value: $onsetTolerance, in: 0.05...0.4, step: 0.01)
                                .frame(width: 140)
                            Text("\(Int((onsetTolerance * 1000).rounded()))ms")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .leading)
                        }
                    }
                    .help("How far off-time a note can land and still count as an attempt at it. Widen it if notes near the very start of a take keep showing miss/wrong.")

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Pitch")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            // Capped at 50 (half a semitone) — past that,
                            // the window starts to overlap a neighboring
                            // note's own territory rather than just
                            // accommodating tuning drift.
                            Slider(value: $pitchTolerance, in: 10...50, step: 1)
                                .frame(width: 140)
                            Text("\(Int(pitchTolerance.rounded()))¢")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .leading)
                        }
                    }
                    .help("How far out of tune a note can land and still count. Widen it if a particular string keeps showing miss/wrong even when played cleanly.")
                }
                .padding(.leading, 22)
                .padding(.trailing, 18)
                .padding(.vertical, 18)
                .frame(width: 230)
            }

            if isCountingIn {
                Label("Count-in…", systemImage: "metronome")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else if recorder.isRecording {
                Label("Recording — play along now", systemImage: "circle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            } else if let result {
                Text(resultMessage(result))
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .onChange(of: engine.isPlaying) { _, isPlaying in
            guard isRecordingSession, !isCountingIn, !isPlaying else { return }
            // This is playback reaching the *natural* end of the whole
            // sequence on its own (the path below only matters when a
            // narrower region needs to stop early) — with no region
            // selected, that also means "reached the end of a lap," so a
            // loop-enabled take needs to restart here too, the same as the
            // narrower-region case below does. Pressing "Stop" by hand
            // can't double up with this: `finishRecording()` clears
            // `isRecordingSession` before it pauses the engine, so the
            // guard above already excludes that path.
            let shouldLoop = selectedRegion == nil && isLoopEnabled
            finishRecording()
            if shouldLoop {
                startRecording()
            }
        }
    }

    private func startRecording() {
        result = nil
        evaluatedNotes = []
        savedLoopRegion = engine.loopRegion
        engine.loopRegion = nil
        engine.seek(to: regionStart)
        isRecordingSession = true

        // Capture starts now, alongside the count-in, not after it —
        // anticipating the beat and picking a hair early is completely
        // normal playing, not a mistake, and the previous behavior meant
        // that attack simply never made it into the recording at all: no
        // amount of onset-detection tuning or timing tolerance can find
        // an onset that was never captured in the first place. The whole
        // lead-in gets recorded as a result (and just as harmlessly
        // ignored, since no expected note falls in that stretch).
        recordingStartedAt = Date()
        recorder.start()

        if leadInEnabled {
            isCountingIn = true
            metronome.playClicks(count: 4, beatInterval: beatInterval) {
                isCountingIn = false
                beginPlayback()
            }
        } else {
            beginPlayback()
        }
    }

    private func beginPlayback() {
        engine.play()
        if metronomeEnabled {
            metronome.startSteadyClick(beatInterval: beatInterval)
        }
        liveEvaluationTimer?.invalidate()
        // `Timer(timeInterval:repeats:)` + `RunLoop.main.add(_:forMode:
        // .common)`, not the plain `Timer.scheduledTimer` convenience
        // initializer — that schedules on the run loop's `.default` mode
        // only, which stalls during any mouse-tracking interaction
        // (dragging a slider, resizing the window). Since this timer is
        // what actually stops "Play Along" at the end of a loop region,
        // that stall meant the region's stop marker could get missed
        // entirely — not just late — if you so much as dragged something
        // while a take was running. Same fix already applied to
        // `PlayerController`/`NotePlaybackEngine`/`MultiTrackPlaybackEngine`'s
        // own timers; this one had been missed.
        let newTimer = Timer(timeInterval: 0.3, repeats: true) { _ in
            Task { @MainActor in
                // With no region selected, `regionEnd` is the whole
                // sequence's own duration and `engine` already stops
                // itself there (see the `engine.isPlaying` handler above,
                // which now also restarts a loop-enabled take in that
                // case) — this only fires early when a selected region is
                // actually narrower than the full sequence, so "Play
                // Along" stops (and scores) right at the end of the
                // selected region instead of playing on through the rest
                // of the song.
                if selectedRegion != nil, engine.currentTime >= regionEnd {
                    let shouldLoop = isLoopEnabled
                    finishRecording()
                    // Checked here, not inside `finishRecording` itself —
                    // that function also runs when "Stop" is pressed by
                    // hand, which must never auto-restart a take. Only
                    // this specific "reached the end of a lap on its own"
                    // path should.
                    if shouldLoop {
                        startRecording()
                    }
                    return
                }
                evaluateSettledNotes()
            }
        }
        RunLoop.main.add(newTimer, forMode: .common)
        liveEvaluationTimer = newTimer
    }

    /// Scores whichever expected notes are far enough behind the playhead
    /// that their analysis window has definitely finished being captured,
    /// coloring each one in on the score right away instead of waiting for
    /// the whole take to end — the point being you can actually see the
    /// checker respond as you play, not just trust it worked afterward.
    private func evaluateSettledNotes() {
        // Clears the onset-tolerance window plus enough extra for the
        // ~0.2s forward-analysis frame to be fully inside what's captured.
        let settleMargin: TimeInterval = 0.4
        let notesInRegion = sequence.notes.filter { $0.startTime >= regionStart && $0.startTime < regionEnd }
        let settledNotes = notesInRegion.filter {
            !evaluatedNotes.contains($0)
                && $0.startTime + onsetTolerance + settleMargin < engine.currentTime
        }
        guard !settledNotes.isEmpty else { return }

        let evaluated = PerformanceEvaluator.evaluate(
            samples: recorder.peek(),
            sampleRate: recorder.sampleRate,
            against: NoteSequence(notes: settledNotes),
            isVocal: isVocal,
            regionStart: regionStart - captureLeadTime,
            onsetTolerance: onsetTolerance,
            pitchTolerance: pitchTolerance
        )
        evaluatedNotes.formUnion(settledNotes)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
            result = PerformanceEvaluator.Result(perNote: (result?.perNote ?? []) + evaluated.perNote)
        }
    }

    private func finishRecording() {
        guard isRecordingSession else { return }
        isRecordingSession = false
        isCountingIn = false
        metronome.cancel()
        liveEvaluationTimer?.invalidate()
        liveEvaluationTimer = nil
        engine.pause()
        engine.loopRegion = savedLoopRegion
        guard recorder.isRecording else { return }
        // `engine.currentTime` right after `pause()` (a few lines up)
        // still holds wherever playback actually reached — pausing only
        // stops the timer, it doesn't reset the value. A note past that
        // point was never actually attempted (this is a "Stop" partway
        // through, not a full pass through the region), so `samples`
        // simply doesn't cover it — without this cutoff, every one of
        // those future notes got evaluated anyway, against whatever real
        // audio happened to be at the very *end* of the recording (see
        // `PerformanceEvaluator.forwardFrame`'s clamping), landing on a
        // hit/miss/wrong verdict that had nothing to do with that note at
        // all. That's what showed up as unplayed notes lighting up
        // green/orange/red at random after stopping a take early.
        let playedUpTo = engine.currentTime
        let samples = recorder.stop()
        let notesInRegion = sequence.notes.filter { $0.startTime >= regionStart && $0.startTime < regionEnd }
        // The live pass above already scored everything it had time to —
        // this just catches whatever's left, typically the last note or
        // two near the end of the take.
        let remainingNotes = notesInRegion.filter { !evaluatedNotes.contains($0) && $0.startTime <= playedUpTo }
        let evaluated = PerformanceEvaluator.evaluate(
            samples: samples,
            sampleRate: recorder.sampleRate,
            against: NoteSequence(notes: remainingNotes),
            isVocal: isVocal,
            regionStart: regionStart - captureLeadTime,
            onsetTolerance: onsetTolerance,
            pitchTolerance: pitchTolerance
        )
        // Springs the hit/miss markers' colors in on the score view
        // (bound via `result`) instead of a hard instant swap.
        withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
            result = PerformanceEvaluator.Result(perNote: (result?.perNote ?? []) + evaluated.perNote)
        }
    }

    /// Shared heading style for each labeled group in the settings
    /// popover — small, uppercase, muted, same treatment SwiftUI's own
    /// grouped `Form` sections use, so Speed/Count-In & Metronome/
    /// Tolerance read as three distinct clusters rather than one long
    /// undifferentiated list of controls.
    @ViewBuilder
    private func settingsSectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func resultMessage(_ result: PerformanceEvaluator.Result) -> String {
        let percent = Int((result.accuracy * 100).rounded())
        let band: String
        switch result.accuracy {
        case 0.95...: band = "Clean pass!"
        case 0.75..<0.95: band = "Nice, almost there"
        case 0.5..<0.75: band = "Getting there"
        default: band = "Keep at it"
        }
        return "\(band) — \(result.correctCount)/\(result.perNote.count) (\(percent)%)"
    }
}
