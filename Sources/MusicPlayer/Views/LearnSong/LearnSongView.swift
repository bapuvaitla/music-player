import SwiftUI
import AppKit
import MusicPlayerKit

/// The "Learn Song" practice view for one track: import a guitar tab
/// and/or vocal melody (MusicXML), hear either played back independently
/// of the song, and loop a section of the song itself while practicing.
/// Takes over the main window (see `ContentView`) rather than opening as
/// a small sheet, since there's a lot to show at once.
struct LearnSongView: View {
    @EnvironmentObject private var library: LibraryModel
    let track: Track

    @StateObject private var tabEngine = NotePlaybackEngine(midiProgram: 24) // nylon acoustic guitar
    @StateObject private var vocalEngine = NotePlaybackEngine(midiProgram: 0) // acoustic grand piano
    @StateObject private var notationEngine = NotePlaybackEngine(midiProgram: 24) // nylon acoustic guitar
    @StateObject private var fullScoreEngine = MultiTrackPlaybackEngine()
    @StateObject private var tabRecorder = AudioRecorder()
    @StateObject private var vocalRecorder = AudioRecorder()
    @StateObject private var notationRecorder = AudioRecorder()

    @State private var tabSequence: NoteSequence?
    @State private var vocalSequence: NoteSequence?
    @State private var notationSequence: NoteSequence?
    @State private var tabFilePath: String?
    @State private var vocalFilePath: String?
    @State private var notationFilePath: String?
    @State private var fullScoreFilePath: String?
    /// Set alongside `fullScoreEngine`'s loaded tracks — `FullScoreView`
    /// needs each part's name/tab-ness for its per-part toggle row.
    @State private var fullScoreParts: [MusicXMLParser.MusicXMLPart] = []
    /// Raw MusicXML bytes for whichever panes render via `NotationScoreView`
    /// (Vocal Melody, Guitar Notation) plus the full-score landing screen —
    /// OpenSheetMusicDisplay parses the file itself rather than consuming
    /// this app's own `NoteSequence`.
    @State private var vocalRawData: Data?
    @State private var notationRawData: Data?
    @State private var fullScoreRawData: Data?
    /// A region can be selected independent of whether it loops — see
    /// `isLoopEnabled`. Shared by every practice pane, the song's own
    /// transport, and Play Along/Sing Along alike (see
    /// `applyLoopRegionToEngines`).
    @State private var selectedRegion: ClosedRange<TimeInterval>?
    /// The one shared loop toggle. When on, both normal playback (every
    /// engine auto-loops `selectedRegion`, see `applyLoopRegionToEngines`)
    /// and Play Along/Sing Along (each take auto-restarts at the region's
    /// start, see `RecordEvaluateControl`) repeat it; when off, both still
    /// use `selectedRegion` to scope playback/scoring, they just don't
    /// repeat. Previously two separate toggles meant different things —
    /// one looped normal playback, the other only auto-repeated takes —
    /// which is exactly the confusion this unifies away.
    @State private var isLoopEnabled = false
    @State private var tabEvaluation: PerformanceEvaluator.Result?
    @State private var vocalEvaluation: PerformanceEvaluator.Result?
    @State private var notationEvaluation: PerformanceEvaluator.Result?

    @State private var importErrorMessage: String?
    @State private var showingTuner = false
    /// Manual last-mile trim on top of each engine's own automatic
    /// output-latency compensation — see `InstrumentTransportView`'s sync
    /// popover. One shared value applied to every engine (tab/vocal/
    /// notation/full-score) rather than tuned per-staff, and persisted
    /// so it's set once per setup, not every session.
    // Key changed from the old "learnSongSyncOffsetMs" (not just renamed)
    // deliberately — that key held a value under the old two-layer
    // automatic-plus-manual scheme (a manual trim of 75ms, layered on top
    // of an automatic ~106ms estimate that's now gone), which isn't a
    // valid value under this single-number scheme. The default here,
    // 31ms, is the actual net compensation the two old values worked out
    // to together (106 subtracted, 75 added back) — empirically correct,
    // still a starting point to re-drag from on new hardware, not an
    // authority to trust blindly.
    @AppStorage("learnSongSyncOffsetMsV2") private var syncOffsetMs: Double = 31
    /// Which of the three staves is currently shown filling the window, or
    /// the full-score landing screen if none has been picked yet. See
    /// `PracticeSelection` (declared alongside `FullScoreView`, which also
    /// needs to name it).
    @State private var practiceSelection: PracticeSelection = .fullScore

    private enum ImportKind {
        case tab, vocal, notation, fullScore
    }


    var body: some View {
        VStack(spacing: 16) {
            header
            staveSwitcher

            Group {
                switch practiceSelection {
                case .fullScore:
                    FullScoreView(musicXMLData: fullScoreRawData, parts: fullScoreParts, engine: fullScoreEngine, onImportFile: { presentImporter(kind: .fullScore) }, showingTuner: $showingTuner, syncOffsetMs: $syncOffsetMs, selectedRegion: $selectedRegion, isLoopEnabled: $isLoopEnabled)
                case .tab:
                    pane(title: "Guitar Tab", sequence: tabSequence, filePath: tabFilePath, engine: tabEngine, recorder: tabRecorder, isVocal: false, evaluation: $tabEvaluation, showingTuner: $showingTuner) {
                        presentImporter(kind: .tab)
                    } content: { sequence in
                        TabGridView(sequence: sequence, currentTime: tabEngine.currentTime, onSeek: { tabEngine.seek(to: $0) }, evaluation: tabEvaluation)
                    }
                case .vocal:
                    pane(title: "Vocal Melody", sequence: vocalSequence, filePath: vocalFilePath, engine: vocalEngine, recorder: vocalRecorder, isVocal: true, evaluation: $vocalEvaluation, showingTuner: $showingTuner) {
                        presentImporter(kind: .vocal)
                    } content: { sequence in
                        NotationScoreView(sequence: sequence, currentTime: vocalEngine.currentTime, onSeek: { vocalEngine.seek(to: $0) }, evaluation: vocalEvaluation, musicXMLData: vocalRawData ?? Data())
                    }
                case .notation:
                    pane(title: "Guitar Notation", sequence: notationSequence, filePath: notationFilePath, engine: notationEngine, recorder: notationRecorder, isVocal: false, evaluation: $notationEvaluation, showingTuner: $showingTuner) {
                        presentImporter(kind: .notation)
                    } content: { sequence in
                        NotationScoreView(sequence: sequence, currentTime: notationEngine.currentTime, onSeek: { notationEngine.seek(to: $0) }, evaluation: notationEvaluation, musicXMLData: notationRawData ?? Data())
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            LargeNowPlayingBarView(track: track, selectedRegion: $selectedRegion, isLoopEnabled: $isLoopEnabled)
        }
        .padding(.top, 20)
        .padding(.bottom, 56)
        .padding(.horizontal, 56)
        .frame(minWidth: 900, minHeight: 560)
        // Blank rather than the track title: the header just below
        // already shows title/artist prominently, so repeating it in the
        // native title bar was pure duplication. (Leaving this unset
        // entirely would instead show whatever artist/album/playlist you
        // were last browsing in the library — stale and irrelevant here —
        // so it still needs to be overridden, just to nothing.)
        .navigationTitle("")
        .onAppear {
            loadSavedSession()
            prewarmCurrentRecorder()
            applySyncOffsetToEngines()
            applyLoopRegionToEngines()
        }
        .onChange(of: syncOffsetMs) { _, _ in applySyncOffsetToEngines() }
        .onChange(of: selectedRegion) { _, _ in
            saveSession()
            applyLoopRegionToEngines()
        }
        .onChange(of: isLoopEnabled) { _, _ in
            saveSession()
            applyLoopRegionToEngines()
        }
        .onChange(of: practiceSelection) { oldValue, _ in
            pauseEngine(for: oldValue)
            saveSession()
            prewarmCurrentRecorder()
        }
        .alert(
            "Couldn't Import File",
            isPresented: Binding(
                get: { importErrorMessage != nil },
                set: { if !$0 { importErrorMessage = nil } }
            )
        ) {
            Button("OK") { importErrorMessage = nil }
        } message: {
            Text(importErrorMessage ?? "")
        }
    }

    // Artwork/title/artist live here now, at the top.
    private var header: some View {
        HStack(spacing: 14) {
            ArtworkView(track: track, size: 76, cornerRadius: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(.system(size: 19, weight: .semibold)).lineLimit(1)
                Text(track.artist).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button(action: finishLearning) {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Done")
            .keyboardShortcut(.cancelAction)
        }
    }

    /// All four destinations stay visible and clickable everywhere — not
    /// just the three you're not currently on — so it doubles as an
    /// always-present indicator of where you are, not only a way to leave.
    private var staveSwitcher: some View {
        HStack(spacing: 12) {
            ForEach(PracticeSelection.allCases, id: \.self) { destination in
                if destination == practiceSelection {
                    Button(destination.displayName) { practiceSelection = destination }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(destination.displayName) { practiceSelection = destination }
                        .buttonStyle(.bordered)
                }
            }
        }
        .controlSize(.large)
    }

    private func finishLearning() {
        tabEngine.stop()
        vocalEngine.stop()
        notationEngine.stop()
        fullScoreEngine.stop()
        tabRecorder.stop()
        vocalRecorder.stop()
        notationRecorder.stop()
        library.learningTrack = nil
    }

    /// Each recorder's `prewarm()` briefly opens its own `AVAudioEngine`'s
    /// mic input, which forces Core Audio to reconfigure the shared
    /// hardware device (see `AudioRecorder.prewarm`'s doc comment) —
    /// harmless once, but calling it for all three recorders back-to-back
    /// at launch chains three of those reconfigurations in quick
    /// succession, which was corrupting every `NotePlaybackEngine`'s
    /// sampler output into raw beeping instead of the intended instrument
    /// tone. Only one stave is ever practiced at a time, so only warming
    /// up that one's recorder — on appear, and again whenever the
    /// selected stave changes — avoids the pile-up while still avoiding
    /// the first-take reconfiguration glitch `prewarm()` exists for.
    /// Pushes the persisted `syncOffsetMs` into every engine's own
    /// `syncOffset` — each engine keeps its own copy rather than reading
    /// `syncOffsetMs` live, so this has to be called whenever the value
    /// changes (see the `onChange` above) as well as once at launch,
    /// since a freshly-constructed engine otherwise starts at its own
    /// default of 0 regardless of what's persisted.
    private func applySyncOffsetToEngines() {
        let offsetSeconds = syncOffsetMs / 1000.0
        tabEngine.syncOffset = offsetSeconds
        vocalEngine.syncOffset = offsetSeconds
        notationEngine.syncOffset = offsetSeconds
        fullScoreEngine.syncOffset = offsetSeconds
    }

    /// Pushes the one loop region set on the song's own transport
    /// (`LargeNowPlayingBarView`, bound to `selectedRegion`/`isLoopEnabled`
    /// here) into every practice engine too, so it's a single region
    /// shared across the song, every stave's reference playback, and
    /// "Play Along"/"Sing Along" — not a separate one re-drawn per pane.
    /// `selectedRegion` is always pushed to every engine's own
    /// `loopRegion` regardless of `isLoopEnabled` — a region can be
    /// selected purely to scope where playback stops, played through
    /// once, without repeating it (see `NotePlaybackEngine.loopsRegion`,
    /// which is what `isLoopEnabled` maps onto here). `RecordEvaluateControl`
    /// still momentarily clears its own engine's copy while actively
    /// recording (see its `startRecording`/`finishRecording`) so its own
    /// timer — not the engine's built-in region handling — is what
    /// decides when a take ends; this is what that copy resets back to
    /// once a take finishes. A freshly-constructed engine otherwise
    /// starts at its own default of nil/true regardless of what's already
    /// set here, so this also has to run once at launch, same as
    /// `applySyncOffsetToEngines`.
    private func applyLoopRegionToEngines() {
        tabEngine.loopRegion = effectiveLoopRegion(duration: tabSequence?.duration ?? 0)
        tabEngine.loopsRegion = isLoopEnabled
        vocalEngine.loopRegion = effectiveLoopRegion(duration: vocalSequence?.duration ?? 0)
        vocalEngine.loopsRegion = isLoopEnabled
        notationEngine.loopRegion = effectiveLoopRegion(duration: notationSequence?.duration ?? 0)
        notationEngine.loopsRegion = isLoopEnabled
        fullScoreEngine.loopRegion = effectiveLoopRegion(duration: fullScoreEngine.duration)
        fullScoreEngine.loopsRegion = isLoopEnabled
    }

    /// With no region selected but looping on, the *whole* sequence loops
    /// — so an engine still needs a concrete range, not `nil`, to actually
    /// repeat anything (see `NotePlaybackEngine.loopRegion`'s own
    /// end-of-region check, which does nothing when it's `nil`). Each
    /// engine gets its *own* duration here rather than one shared value —
    /// the tab/vocal/notation sequences and the full score aren't
    /// guaranteed to all run the same length.
    private func effectiveLoopRegion(duration: TimeInterval) -> ClosedRange<TimeInterval>? {
        if let selectedRegion { return selectedRegion }
        return isLoopEnabled ? 0...duration : nil
    }

    private func prewarmCurrentRecorder() {
        switch practiceSelection {
        case .fullScore: break
        case .tab: tabRecorder.prewarm()
        case .vocal: vocalRecorder.prewarm()
        case .notation: notationRecorder.prewarm()
        }
    }

    /// Switching staves leaves the pane you left mounted-but-hidden, not
    /// torn down (each keeps its own engine/recorder instance so its
    /// state survives a round trip) — without this, playback started on
    /// one stave would just keep going, unheard but still running, under
    /// whichever one you switched to.
    private func pauseEngine(for selection: PracticeSelection) {
        switch selection {
        case .fullScore: fullScoreEngine.pause()
        case .tab: tabEngine.pause()
        case .vocal: vocalEngine.pause()
        case .notation: notationEngine.pause()
        }
    }

    @ViewBuilder
    private func pane<Content: View>(
        title: String,
        sequence: NoteSequence?,
        filePath: String?,
        engine: NotePlaybackEngine,
        recorder: AudioRecorder,
        isVocal: Bool,
        evaluation: Binding<PerformanceEvaluator.Result?>,
        showingTuner: Binding<Bool>,
        onImport: @escaping () -> Void,
        @ViewBuilder content: (NoteSequence) -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // No repeated title here — the segmented picker above already
            // says "Guitar Tab" / "Vocal Melody".
            HStack {
                Spacer()
                Button(sequence == nil ? "Import…" : "Replace…", action: onImport)
                    .buttonStyle(.link)
                    .font(.body)
            }

            if let sequence {
                // Play/rewind/volume/speed sits above the score, not
                // below it — it's the thing you reach for constantly
                // while following along, not an afterthought under the
                // tab. Given its own room above/below rather than sitting
                // flush against the Import row and loop control, now that
                // it's a wider, multi-cluster row in its own right.
                InstrumentTransportView(engine: engine, sequence: sequence, leadingInset: isVocal ? 0 : 22, showingTuner: showingTuner, showsTuner: !isVocal, syncOffsetMs: $syncOffsetMs)
                    .padding(.vertical, 4)
                // Bound to the one shared `$selectedRegion`/`$isLoopEnabled`
                // (also settable from the song's own transport below), not
                // a per-pane region of its own — kept here too, not just
                // down there, because this is the convenient place to
                // actually see and drag it against this stave's own bars
                // while practicing, without scrolling away from the score.
                PlaybackLoopControl(
                    selectedRegion: $selectedRegion,
                    isLoopEnabled: $isLoopEnabled,
                    duration: sequence.duration,
                    currentTime: engine.currentTime,
                    onSeek: { engine.seek(to: $0) },
                    barTimes: sequence.barStartTimes,
                    snapPoints: sequence.beatTimes
                )
                .id(filePath)
                .padding(.bottom, 10)
                content(sequence)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                RecordEvaluateControl(
                    engine: engine,
                    recorder: recorder,
                    sequence: sequence,
                    selectedRegion: selectedRegion,
                    isLoopEnabled: isLoopEnabled,
                    isVocal: isVocal,
                    result: evaluation
                )
                .id(filePath)
            } else {
                Text("No \(title.lowercased()) imported yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
        .background(Color.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadSavedSession() {
        Task {
            guard let saved = await library.loadLearnSession(for: track) else { return }
            // `loopStart`/`loopEnd` are still persisted (see
            // `saveLearnSession` below) but deliberately not restored here
            // — the region-select toggle should always start off when
            // Learn Song opens, not silently reactivate whatever section
            // happened to be selected last time. `isLoopEnabled` alone is
            // still worth restoring: with no region selected, on just
            // means "loop the whole song," a preference worth keeping.
            isLoopEnabled = saved.isLoopEnabled
            if let tabPath = saved.tabFilePath {
                importFile(at: URL(fileURLWithPath: tabPath), kind: .tab, persist: false)
            }
            if let vocalPath = saved.vocalFilePath {
                importFile(at: URL(fileURLWithPath: vocalPath), kind: .vocal, persist: false)
            }
            if let notationPath = saved.notationFilePath {
                importFile(at: URL(fileURLWithPath: notationPath), kind: .notation, persist: false)
            }
            if let fullScorePath = saved.fullScoreFilePath {
                importFile(at: URL(fileURLWithPath: fullScorePath), kind: .fullScore, persist: false)
            }
            // Resuming straight onto whichever stave was last being
            // practiced, rather than back on the full-score picker every
            // time — same "pick up where you left off" as the loop region.
            practiceSelection = PracticeSelection(persistedValue: saved.practiceTarget)
        }
    }

    /// Uses `NSOpenPanel` directly rather than SwiftUI's `.fileImporter` —
    /// after two rounds of it silently failing to deliver a picked file
    /// (no error, nothing imported), driving the panel here avoids
    /// depending on SwiftUI state timing entirely: `kind` is captured
    /// straight into the completion closure, with nothing shared to race.
    private func presentImporter(kind: ImportKind) {
        let panel = NSOpenPanel()
        switch kind {
        case .tab:
            panel.title = "Import Guitar Tab"
        case .vocal:
            panel.title = "Import Vocal Melody"
        case .notation:
            panel.title = "Import Guitar Notation"
        case .fullScore:
            panel.title = "Import Full Score"
        }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            importFile(at: url, kind: kind, persist: true)
        }
    }

    private func importFile(at url: URL, kind: ImportKind, persist: Bool) {
        // A URL handed back by a file picker may need this even in a
        // non-sandboxed app — harmless (just returns false) if it doesn't.
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer { if didStartAccess { url.stopAccessingSecurityScopedResource() } }

        if kind == .fullScore {
            importFullScore(at: url, persist: persist)
            return
        }

        do {
            let sequence = try MusicXMLParser.parse(fileAt: url)
            switch kind {
            case .tab:
                tabSequence = sequence
                tabFilePath = url.path
                tabEngine.load(sequence)
                tabEvaluation = nil
            case .vocal:
                vocalSequence = sequence
                vocalFilePath = url.path
                vocalRawData = try? Data(contentsOf: url)
                vocalEngine.load(sequence)
                vocalEvaluation = nil
            case .notation:
                notationSequence = sequence
                notationFilePath = url.path
                notationRawData = try? Data(contentsOf: url)
                notationEngine.load(sequence)
                notationEvaluation = nil
            case .fullScore:
                break // handled above
            }
            if persist { saveSession() }
        } catch {
            // A previously-saved file that's since moved/been deleted
            // fails silently on load (persist: false) rather than
            // greeting the user with an alert on every reopen — a fresh
            // user-initiated import (persist: true) still surfaces it.
            guard persist else { return }
            importErrorMessage = "Couldn't read \u{201C}\(url.lastPathComponent)\u{201D} as MusicXML (\(error.localizedDescription)). Make sure it's exported as uncompressed MusicXML (.musicxml/.xml), not the compressed .mxl variant."
        }
    }

    /// The full score is a multi-part file (Voice + Guitar Notation +
    /// Guitar Tab in one document), parsed with `parseAllParts` instead
    /// of the single-sequence `parse` the other three kinds use — each
    /// part becomes its own `MultiTrackPlaybackEngine` track so they can
    /// play together (Voice + Guitar Notation, by default) without
    /// Guitar Notation and Guitar Tab doubling the same line. Guitar
    /// parts get the nylon-guitar patch, everything else the neutral
    /// piano patch already used for `vocalEngine`.
    private func importFullScore(at url: URL, persist: Bool) {
        do {
            let parts = try MusicXMLParser.parseAllParts(fileAt: url)
            fullScoreFilePath = url.path
            fullScoreRawData = try? Data(contentsOf: url)
            fullScoreParts = parts
            fullScoreEngine.load(parts.map { part in
                MultiTrackPlaybackEngine.Track(
                    name: part.name,
                    sequence: part.sequence,
                    midiProgram: part.isTabPart ? 24 : 0,
                    isEnabled: !part.isTabPart
                )
            })
            if persist { saveSession() }
        } catch {
            guard persist else { return }
            importErrorMessage = "Couldn't read \u{201C}\(url.lastPathComponent)\u{201D} as MusicXML (\(error.localizedDescription)). Make sure it's exported as uncompressed MusicXML (.musicxml/.xml), not the compressed .mxl variant."
        }
    }

    private func saveSession() {
        let data = LearnSessionData(
            tabFilePath: tabFilePath,
            vocalFilePath: vocalFilePath,
            notationFilePath: notationFilePath,
            fullScoreFilePath: fullScoreFilePath,
            practiceTarget: practiceSelection.persistedValue,
            loopStart: selectedRegion?.lowerBound,
            loopEnd: selectedRegion?.upperBound,
            isLoopEnabled: isLoopEnabled
        )
        library.saveLearnSession(data, for: track)
    }
}
