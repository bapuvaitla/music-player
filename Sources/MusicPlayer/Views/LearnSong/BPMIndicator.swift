import SwiftUI

/// Shows a sequence's tempo — its base BPM, or (when `playbackRate` is
/// anything other than 1.0) the *effective* BPM at the current practice
/// speed. Meant to be read against a real metronome while practicing away
/// from the computer, so the number shown is always the one that matters
/// right now, not just the file's nominal tempo.
struct BPMIndicator: View {
    let baseTempo: Double
    var playbackRate: Double = 1.0

    private var effectiveBPM: Int {
        Int((baseTempo * playbackRate).rounded())
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "metronome")
                .font(.system(size: 13))
            Text("\(effectiveBPM) BPM")
                .font(.system(size: 13))
                .monospacedDigit()
        }
        .foregroundStyle(playbackRate != 1.0 ? Color.primary : Color.secondary)
        .help(
            playbackRate == 1.0
                ? "Tempo: \(effectiveBPM) BPM"
                : "Tempo at \(Int((playbackRate * 100).rounded()))% speed: \(effectiveBPM) BPM (base \(Int(baseTempo.rounded())) BPM)"
        )
    }
}
