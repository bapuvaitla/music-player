import SwiftUI
import MusicPlayerKit

/// Transport for one `NotePlaybackEngine` — reused for both the tab and
/// vocal-melody practice views, each backed by its own engine instance,
/// entirely independent of the song's own playback. Sits above the score
/// now (the primary controls for practicing), so sized up accordingly.
/// Play/pause, rewind to start, back/forward one bar (from the sequence's
/// own measure boundaries), and volume stay on the main row; practice
/// speed (which slows playback down without changing pitch) is tucked
/// behind a small icon since it's reached far less often.
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

    @State private var showingSpeedPopover = false

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
                Image(systemName: "speedometer")
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .foregroundStyle(engine.playbackRate != 1.0 ? Color.primary : Color.secondary)
            .help("Practice speed")
            .popover(isPresented: $showingSpeedPopover, arrowEdge: .bottom) {
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
                .padding(14)
            }

            if showsTuner {
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
            }
        }
        .padding(.leading, leadingInset)
    }
}
