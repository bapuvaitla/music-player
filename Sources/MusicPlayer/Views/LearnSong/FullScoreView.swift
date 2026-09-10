import SwiftUI
import MusicPlayerKit

/// The Learn Song landing screen: renders the *original* combined score —
/// every stave (vocal, guitar notation, guitar tab) in one MusicXML file,
/// exactly as arranged — via the same `NotationScoreView`/OSMD pipeline
/// used for the individual practice panes, now with real playback across
/// every part at once via `MultiTrackPlaybackEngine`.
///
/// Lighter than the three practice panes: loop region, yes, but no
/// Record/Evaluate — scoring a take against a multi-part mix doesn't map
/// to a single stave's pass/fail evaluation the way the others do. Guitar
/// Notation and Guitar Tab are the same guitar line in two notations, so
/// both audible at once would double it — `engine`'s tracks start with
/// Guitar Tab muted (see `LearnSongView.importFullScore`), toggleable
/// per-part here.
///
/// Simpler than a PDF preview would have been to keep in sync (a
/// separately-exported file the user would need to re-export by hand
/// whenever the score changes) — this reuses the one combined file
/// directly, and OSMD renders it the same way regardless of how many
/// parts/staves it contains.
struct FullScoreView: View {
    let musicXMLData: Data?
    let parts: [MusicXMLParser.MusicXMLPart]
    @ObservedObject var engine: MultiTrackPlaybackEngine
    let onImportFile: () -> Void
    /// Shared with the three practice panes (same binding, passed down
    /// from `LearnSongView`) so the tuner popover's open/closed state
    /// doesn't reset when switching screens — same reasoning as
    /// `InstrumentTransportView.showingTuner`. The full score's guitar
    /// parts are as tuning-relevant as the individual Guitar Tab/Notation
    /// panes, so this gets its own tuner button rather than going without.
    @Binding var showingTuner: Bool
    /// Same shared value as the three practice panes — see
    /// `InstrumentTransportView.syncOffsetMs`.
    @Binding var syncOffsetMs: Double
    /// The one loop region shared with the song's own transport and every
    /// practice pane (see `LearnSongView.applyLoopRegionToEngines`) — not
    /// a region of this screen's own.
    @Binding var loopRegion: ClosedRange<TimeInterval>?

    /// Used for click-to-seek/evaluation-coloring correlation in
    /// `NotationScoreView` (it needs *a* `NoteSequence` to map a clicked
    /// note's OSMD cursor-step index back to a timestamp) — the longest
    /// part gives the most complete index coverage. OSMD's own cursor
    /// steps through the whole multi-part score as one combined timeline,
    /// so a click whose step index falls beyond this one part's own note
    /// count just doesn't seek (safely — `OSMDWebView` already guards
    /// that index) rather than seeking to the wrong place; this is a
    /// known rough edge, not a crash risk. `seekToTime`-driven cursor
    /// following (i.e. anything the transport below drives) has no such
    /// limitation, since it matches by time, not index.
    private var longestPartSequence: NoteSequence {
        parts.max(by: { $0.sequence.notes.count < $1.sequence.notes.count })?.sequence ?? NoteSequence(notes: [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Spacer()
                Button(musicXMLData == nil ? "Import…" : "Replace…", action: onImportFile)
                    .buttonStyle(.link)
                    .font(.body)
            }

            if musicXMLData != nil, !parts.isEmpty {
                transport
                PlaybackLoopControl(
                    loopRegion: $loopRegion,
                    duration: engine.duration,
                    currentTime: engine.currentTime,
                    onSeek: { engine.seek(to: $0) },
                    barTimes: longestPartSequence.barStartTimes,
                    snapPoints: longestPartSequence.beatTimes
                )
                partToggles
            }

            Group {
                if let musicXMLData, !musicXMLData.isEmpty {
                    NotationScoreView(
                        sequence: longestPartSequence,
                        currentTime: engine.currentTime,
                        onSeek: { engine.seek(to: $0) },
                        evaluation: nil,
                        musicXMLData: musicXMLData
                    )
                } else {
                    Text("No full score imported yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.panelBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var transport: some View {
        HStack(spacing: 28) {
            Button {
                engine.seek(to: 0)
            } label: {
                Image(systemName: "backward.end.fill").font(.system(size: 17))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Rewind to the beginning")

            Button {
                engine.isPlaying ? engine.pause() : engine.play()
            } label: {
                Image(systemName: engine.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 38))
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                Image(systemName: "speaker.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { Double(engine.volume) },
                        set: { engine.volume = Float($0) }
                    ),
                    in: 0...1
                )
                .frame(maxWidth: 150)
                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Button {
                showingTuner = true
            } label: {
                Image(systemName: "tuningfork")
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Tuner")
            .popover(isPresented: $showingTuner, arrowEdge: .top) {
                TunerPopoverView()
            }

            SyncOffsetButton(syncOffsetMs: $syncOffsetMs)

            Spacer()
        }
    }

    /// Which parts sound during playback — Voice and Guitar Notation start
    /// on, Guitar Tab starts off (see `LearnSongView.importFullScore`),
    /// all freely toggleable, and none of this is persisted (resets to
    /// that default each time Learn Song reopens).
    private var partToggles: some View {
        HStack(spacing: 16) {
            ForEach(Array(engine.tracks.enumerated()), id: \.offset) { index, track in
                Toggle(track.name, isOn: Binding(
                    get: { track.isEnabled },
                    set: { engine.setTrack(at: index, enabled: $0) }
                ))
                .toggleStyle(.checkbox)
            }
        }
    }
}

/// Which of the full score or one of its three staves is currently shown
/// filling `LearnSongView`'s window.
enum PracticeSelection: Hashable, CaseIterable {
    // Declaration order drives `allCases`, which `staveSwitcher` renders
    // in order — matched to the full score's own top-to-bottom staff
    // order (Voice, then Acoustic Guitar notation, then Guitar tab), so
    // the switcher's left-to-right order reads the same way.
    case fullScore, vocal, notation, tab

    var displayName: String {
        switch self {
        case .fullScore: return "Full Score"
        case .tab: return "Guitar Tab"
        case .vocal: return "Vocal Melody"
        case .notation: return "Guitar Notation"
        }
    }

    init(persistedValue: String?) {
        switch persistedValue {
        case "tab": self = .tab
        case "vocal": self = .vocal
        case "notation": self = .notation
        default: self = .fullScore
        }
    }

    var persistedValue: String? {
        switch self {
        case .fullScore: return nil
        case .tab: return "tab"
        case .vocal: return "vocal"
        case .notation: return "notation"
        }
    }
}
