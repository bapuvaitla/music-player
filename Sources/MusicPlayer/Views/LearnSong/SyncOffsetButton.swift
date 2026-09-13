import SwiftUI

/// The playhead-sync button + popover, shared by `InstrumentTransportView`
/// and `FullScoreView` — sets `NotePlaybackEngine.syncOffset` directly, in
/// milliseconds. Real audio output always becomes audible somewhat after
/// the playhead's own wall-clock estimate says it should (buffer priming,
/// driver/hardware delay — worse over Bluetooth); this is dragged into
/// place once, by ear, against what's actually heard, and remembered from
/// then on.
struct SyncOffsetButton: View {
    @Binding var syncOffsetMs: Double
    @State private var showingPopover = false

    var body: some View {
        Button {
            showingPopover = true
        } label: {
            Image(systemName: "timer")
                .font(.system(size: 15))
        }
        .buttonStyle(.plain)
        .foregroundStyle(syncOffsetMs == 0 ? Color.secondary : Color.primary)
        .help("Playhead sync offset")
        .popover(isPresented: $showingPopover, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Playhead Sync")
                    .font(.headline)
                Text("If the on-screen playhead doesn't quite match what you hear, nudge it here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 220, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text("Earlier")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Slider(value: $syncOffsetMs, in: -150...150, step: 5)
                        .frame(width: 160)
                    Text("Later")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("\(Int(syncOffsetMs))ms")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Spacer()
                    if syncOffsetMs != 0 {
                        Button("Reset") { syncOffsetMs = 0 }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }
            .padding(14)
        }
    }
}
