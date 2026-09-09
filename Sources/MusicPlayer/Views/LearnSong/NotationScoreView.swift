import SwiftUI
import MusicPlayerKit

/// A practice pane's content rendered as real engraved staff notation —
/// used for both the Guitar Notation and Vocal Melody staves (unlike
/// `TabGridView`'s fret grid, which stays purpose-built for tab). Rendered
/// via OpenSheetMusicDisplay in an embedded `WKWebView` (`OSMDWebView`)
/// rather than natively — there's no staff-notation renderer in this app,
/// and building one from scratch (noteheads, beams, clefs, chord
/// diagrams) was explicitly out of scope for this pass. A future native
/// replacement should be able to drop in here without `LearnSongView`'s
/// call sites changing, since this matches `TabGridView`/`PitchLineView`'s
/// `sequence`/`currentTime`/`onSeek`/`evaluation` contract —
/// `musicXMLData` is the one addition, needed because OSMD parses the raw
/// file itself rather than consuming this app's `NoteSequence`.
struct NotationScoreView: View {
    let sequence: NoteSequence
    let currentTime: TimeInterval
    var onSeek: (TimeInterval) -> Void = { _ in }
    var evaluation: PerformanceEvaluator.Result?
    let musicXMLData: Data

    var body: some View {
        Group {
            if musicXMLData.isEmpty {
                Text("Couldn't read this file for notation display.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                OSMDWebView(
                    musicXMLData: musicXMLData,
                    currentTime: currentTime,
                    sequence: sequence,
                    evaluation: evaluation,
                    onSeek: onSeek
                )
            }
        }
    }
}
