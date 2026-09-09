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
    let loopRegion: ClosedRange<TimeInterval>?
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
    /// Notes already scored by the live in-progress pass — `finishRecording`
    /// only needs to catch whatever's left (typically the last note or two
    /// near the end of the take), not redo the whole thing.
    @State private var evaluatedNotes: Set<ScoreNote> = []
    /// How much earlier than `regionStart` the recording buffer actually
    /// begins — the count-in's own duration, when there is one. Recording
    /// starts alongside the count-in rather than after it (see
    /// `startRecording`), so this offset has to be subtracted out when
    /// telling `PerformanceEvaluator` what `samples[0]` corresponds to.
    @State private var captureLeadTime: TimeInterval = 0

    private var regionStart: TimeInterval { loopRegion?.lowerBound ?? 0 }
    private var regionEnd: TimeInterval { loopRegion?.upperBound ?? sequence.duration }
    private var beatInterval: TimeInterval { 60.0 / max(sequence.tempo, 1) }
    private var optionsActive: Bool { leadInEnabled || metronomeEnabled }

    var body: some View {
        HStack(spacing: 12) {
            Button(isRecordingSession ? "Stop" : (isVocal ? "Sing Along…" : "Play Along…")) {
                isRecordingSession ? finishRecording() : startRecording()
            }
            .controlSize(.large)
            .tint(isRecordingSession ? .red : nil)

            // Smaller and more muted than "Play Along…" so it doesn't
            // compete with the primary action — but not so faint it's
            // hard to notice; the timing-tolerance slider lives in here
            // too, not just the count-in/metronome toggles.
            Button {
                showingOptionsPopover = true
            } label: {
                Image(systemName: optionsActive ? "gearshape.fill" : "gearshape")
                    .font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(isRecordingSession)
            .help("Count-in, metronome, and timing-tolerance options")
            .popover(isPresented: $showingOptionsPopover, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
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

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Timing Tolerance")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Slider(value: $onsetTolerance, in: 0.05...0.4, step: 0.01)
                                .frame(width: 140)
                            Text("\(Int((onsetTolerance * 1000).rounded()))ms")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 46, alignment: .leading)
                        }
                    }
                    .help("How far off-time a note can land and still count as an attempt at it. Widen it if notes near the very start of a take keep showing miss/wrong.")
                }
                .padding(14)
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
            finishRecording()
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
        recorder.start()
        captureLeadTime = leadInEnabled ? beatInterval * 4 : 0

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
        liveEvaluationTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            Task { @MainActor in
                evaluateSettledNotes()
            }
        }
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
            onsetTolerance: onsetTolerance
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
        let samples = recorder.stop()
        let notesInRegion = sequence.notes.filter { $0.startTime >= regionStart && $0.startTime < regionEnd }
        // The live pass above already scored everything it had time to —
        // this just catches whatever's left, typically the last note or
        // two near the end of the take.
        let remainingNotes = notesInRegion.filter { !evaluatedNotes.contains($0) }
        let evaluated = PerformanceEvaluator.evaluate(
            samples: samples,
            sampleRate: recorder.sampleRate,
            against: NoteSequence(notes: remainingNotes),
            isVocal: isVocal,
            regionStart: regionStart - captureLeadTime,
            onsetTolerance: onsetTolerance
        )
        // Springs the hit/miss markers' colors in on the score view
        // (bound via `result`) instead of a hard instant swap.
        withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
            result = PerformanceEvaluator.Result(perNote: (result?.perNote ?? []) + evaluated.perNote)
        }
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
        return "\(band) — \(result.hitCount)/\(result.perNote.count) (\(percent)%)"
    }
}
