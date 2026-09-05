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
    @StateObject private var tabRecorder = AudioRecorder()
    @StateObject private var vocalRecorder = AudioRecorder()

    @State private var tabSequence: NoteSequence?
    @State private var vocalSequence: NoteSequence?
    @State private var tabFilePath: String?
    @State private var vocalFilePath: String?
    @State private var loopRegion: ClosedRange<TimeInterval>?
    @State private var tabEvaluation: PerformanceEvaluator.Result?
    @State private var vocalEvaluation: PerformanceEvaluator.Result?

    @State private var importErrorMessage: String?
    @State private var showingTuner = false
    /// Which of tab/vocal is currently shown, filling the window — rather
    /// than the two side by side, which left both cramped.
    @State private var practiceTarget: PracticeTarget = .tab

    private enum PracticeTarget: Hashable {
        case tab, vocal
    }

    var body: some View {
        VStack(spacing: 16) {
            header

            Picker("", selection: $practiceTarget) {
                Text("Guitar Tab").tag(PracticeTarget.tab)
                Text("Vocal Melody").tag(PracticeTarget.vocal)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)
            .frame(maxWidth: 320)

            Group {
                if practiceTarget == .tab {
                    pane(title: "Guitar Tab", sequence: tabSequence, filePath: tabFilePath, engine: tabEngine, recorder: tabRecorder, isVocal: false, evaluation: $tabEvaluation, transportLabel: "Tab", showingTuner: $showingTuner) {
                        presentImporter(isTab: true)
                    } content: { sequence in
                        TabGridView(sequence: sequence, currentTime: tabEngine.currentTime, onSeek: { tabEngine.seek(to: $0) }, evaluation: tabEvaluation)
                    }
                } else {
                    pane(title: "Vocal Melody", sequence: vocalSequence, filePath: vocalFilePath, engine: vocalEngine, recorder: vocalRecorder, isVocal: true, evaluation: $vocalEvaluation, transportLabel: "Melody", showingTuner: $showingTuner) {
                        presentImporter(isTab: false)
                    } content: { sequence in
                        PitchLineView(sequence: sequence, currentTime: vocalEngine.currentTime, onSeek: { vocalEngine.seek(to: $0) }, evaluation: vocalEvaluation)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            LargeNowPlayingBarView(track: track, loopRegion: $loopRegion)
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
            tabRecorder.prewarm()
            vocalRecorder.prewarm()
        }
        .onChange(of: loopRegion) { _, _ in saveSession() }
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

    private func finishLearning() {
        tabEngine.stop()
        vocalEngine.stop()
        tabRecorder.stop()
        vocalRecorder.stop()
        library.learningTrack = nil
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
        transportLabel: String,
        showingTuner: Binding<Bool>,
        onImport: @escaping () -> Void,
        @ViewBuilder content: (NoteSequence) -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
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
                // tab.
                InstrumentTransportView(engine: engine, sequence: sequence, label: transportLabel, leadingInset: isVocal ? 0 : 22, showingTuner: showingTuner)
                // Keyed on the file path so replacing this pane's file
                // gets a fresh loop control instead of reusing stale
                // start/end values sized for the old sequence. Sits above
                // the score — you set up the section you're looping before
                // following along, not after.
                PlaybackLoopControl(
                    loopRegion: Binding(get: { engine.loopRegion }, set: { engine.loopRegion = $0 }),
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
                    loopRegion: engine.loopRegion,
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
            if let start = saved.loopStart, let end = saved.loopEnd, end > start {
                loopRegion = start...end
            }
            if let tabPath = saved.tabFilePath {
                importFile(at: URL(fileURLWithPath: tabPath), isTab: true, persist: false)
            }
            if let vocalPath = saved.vocalFilePath {
                importFile(at: URL(fileURLWithPath: vocalPath), isTab: false, persist: false)
            }
        }
    }

    /// Uses `NSOpenPanel` directly rather than SwiftUI's `.fileImporter` —
    /// after two rounds of it silently failing to deliver a picked file
    /// (no error, nothing imported), driving the panel here avoids
    /// depending on SwiftUI state timing entirely: `isTab` is captured
    /// straight into the completion closure, with nothing shared to race.
    private func presentImporter(isTab: Bool) {
        let panel = NSOpenPanel()
        panel.title = isTab ? "Import Guitar Tab" : "Import Vocal Melody"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            importFile(at: url, isTab: isTab, persist: true)
        }
    }

    private func importFile(at url: URL, isTab: Bool, persist: Bool) {
        // A URL handed back by a file picker may need this even in a
        // non-sandboxed app — harmless (just returns false) if it doesn't.
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer { if didStartAccess { url.stopAccessingSecurityScopedResource() } }

        do {
            let sequence = try MusicXMLParser.parse(fileAt: url)
            if isTab {
                tabSequence = sequence
                tabFilePath = url.path
                tabEngine.load(sequence)
                tabEvaluation = nil
            } else {
                vocalSequence = sequence
                vocalFilePath = url.path
                vocalEngine.load(sequence)
                vocalEvaluation = nil
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

    private func saveSession() {
        let data = LearnSessionData(
            tabFilePath: tabFilePath,
            vocalFilePath: vocalFilePath,
            loopStart: loopRegion?.lowerBound,
            loopEnd: loopRegion?.upperBound
        )
        library.saveLearnSession(data, for: track)
    }
}
