import SwiftUI
import MusicPlayerKit

/// Transport for one `NotePlaybackEngine` — reused for both the tab and
/// vocal-melody practice views, each backed by its own engine instance,
/// entirely independent of the song's own playback. Sits above the score
/// now (the primary controls for practicing), so sized up accordingly.
/// Play/pause, rewind to start, back/forward one bar (from the sequence's
/// own measure boundaries), volume, and a BPM readout live here. Tapping
/// the BPM readout opens the practice-speed control (see `BPMIndicator`
/// and the `showingSpeedPopover` popover below) — it used to live in the
/// "Play Along"/"Sing Along" row instead, but the BPM number is the
/// actual target you're changing when you drag that slider, so it's the
/// more natural thing to tap. The readout stays visible (and live-updates
/// through any tempo change) on every staff without needing to open
/// anything — useful for setting a real metronome while practicing away
/// from the computer.
struct InstrumentTransportView: View {
    @ObservedObject var engine: NotePlaybackEngine
    let sequence: NoteSequence
    /// Shifts the whole row right to match wherever the score's own
    /// content actually starts — the tab grid reserves a string-label
    /// column before its bar lines begin, so without this the transport's
    /// leading button sits noticeably left of the grid's real left edge.
    var leadingInset: CGFloat = 0
    /// Owned by `LearnSongView` rather than local `@State` — the tab and
    /// vocal-melody panes each get their own `InstrumentTransportView`
    /// instance, but only one is ever on screen at a time, so sharing a
    /// single binding just keeps the tuner popover's open/closed state
    /// from resetting when you switch panes mid-session.
    @Binding var showingTuner: Bool
    /// A tuner's not relevant to following a vocal melody the way it is
    /// for the two guitar staves — hidden there rather than shown as a
    /// dead-feeling no-op button.
    var showsTuner: Bool = true
    /// Milliseconds, not seconds — `NotePlaybackEngine.syncOffset`
    /// is a `TimeInterval`, but a slider in whole milliseconds is a much
    /// more natural unit to actually drag. Owned by `LearnSongView` (like
    /// `showingTuner`) and pushed into every engine there, not read
    /// directly from `engine` here, since one offset should apply
    /// consistently across every pane rather than needing to be re-tuned
    /// per staff.
    @Binding var syncOffsetMs: Double

    @State private var showingSpeedPopover = false
    @State private var showingTransposePopover = false

    var body: some View {
        // Grouped into tight clusters (playback / volume) with generous
        // space between the clusters themselves — flat 16pt spacing
        // across every element read as one undifferentiated row; this
        // makes "these four buttons are one control, that's a separate
        // one" visible at a glance. No "Tab"/"Melody"/"Notation" label
        // here either — the always-visible stave switcher above already
        // says which one you're on.
        HStack(spacing: 28) {
            HStack(spacing: 16) {
                // Play is the one action reached for constantly, so it's
                // the only one at full size/contrast — rewind/back/forward
                // are secondary and recede accordingly (smaller, muted).
                Button {
                    engine.seek(to: 0)
                } label: {
                    Image(systemName: "backward.end.fill").font(.system(size: 17))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Rewind to the beginning")

                Button {
                    engine.seek(to: sequence.barStart(before: engine.currentTime))
                } label: {
                    Image(systemName: "backward.fill").font(.system(size: 17))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Back one bar")

                Button {
                    engine.isPlaying ? engine.pause() : engine.play()
                } label: {
                    Image(systemName: engine.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 38))
                }
                .buttonStyle(.plain)

                Button {
                    engine.seek(to: sequence.barStart(after: engine.currentTime))
                } label: {
                    Image(systemName: "forward.fill").font(.system(size: 17))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Forward one bar")
            }

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
                showingSpeedPopover = true
            } label: {
                BPMIndicator(baseTempo: sequence.tempo(atTime: engine.currentTime), playbackRate: engine.playbackRate)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingSpeedPopover, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("Speed")
                            .font(.body)
                            .foregroundStyle(.secondary)
                        Slider(
                            value: Binding(
                                get: { engine.playbackRate },
                                set: { engine.playbackRate = $0 }
                            ),
                            in: 0.25...1.25
                        )
                        .frame(width: 140)
                        Text("\(Int((engine.playbackRate * 100).rounded()))%")
                            .font(.body)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .leading)
                    }
                    // What that percentage actually means for a real
                    // metronome — the whole point of showing it here
                    // rather than making you do the math from the
                    // percentage yourself.
                    HStack(spacing: 4) {
                        Text("→")
                            .foregroundStyle(.secondary)
                        BPMIndicator(baseTempo: sequence.tempo(atTime: engine.currentTime), playbackRate: engine.playbackRate)
                    }
                    .font(.body)
                }
                .padding(14)
            }

            // A capo, effectively — the tab/notation stays exactly as
            // written, this only shifts what's *heard*, so you can sing
            // or play along in a different key. Re-deriving tab fret
            // positions or re-engraved notation for a transposed key
            // isn't something this can do well automatically (which
            // string a shifted note falls on isn't recoverable from pitch
            // alone), so this is playback-only by design.
            Button {
                showingTransposePopover = true
            } label: {
                // Height-only frame, matching the tuner/sync-offset icons
                // either side of it for vertical alignment — a fixed
                // *width* of 20 truncated "♯/♭" to an ellipsis, since
                // three characters at 17pt semibold don't fit in a square
                // the SF Symbols either side of it are happy with. Letting
                // the width size to the text avoids that; a plain-text
                // glyph at the same point size as an SF Symbol also tends
                // to read smaller, hence the larger size to actually match
                // its neighbors' weight.
                Text("♯/♭")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(height: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(engine.transposition != 0 ? Color.primary : Color.secondary)
            .help(engine.transposition == 0 ? "Transpose (playback only)" : "Transposed \(engine.transposition > 0 ? "+" : "")\(engine.transposition) semitones (playback only)")
            .popover(isPresented: $showingTransposePopover, arrowEdge: .bottom) {
                HStack(spacing: 10) {
                    Stepper(
                        value: Binding(
                            get: { engine.transposition },
                            set: { engine.transposition = $0 }
                        ),
                        in: -12...12
                    ) {
                        Text(engine.transposition == 0 ? "No transposition" : "\(engine.transposition > 0 ? "+" : "")\(engine.transposition) semitones")
                            .font(.body)
                            .monospacedDigit()
                            .frame(width: 150, alignment: .leading)
                    }
                }
                .padding(14)
            }

            if showsTuner {
                Button {
                    showingTuner = true
                } label: {
                    Image(systemName: "tuningfork")
                        .font(.system(size: 16))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Tuner")
                .popover(isPresented: $showingTuner, arrowEdge: .top) {
                    TunerPopoverView()
                }
            }

            // A single, transparent sync offset (see
            // `NotePlaybackEngine.syncOffset`) — drag until the playhead
            // lines up with what you're actually hearing, once, and it's
            // remembered from then on.
            SyncOffsetButton(syncOffsetMs: $syncOffsetMs)
        }
        .padding(.leading, leadingInset)
    }
}
