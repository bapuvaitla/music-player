import SwiftUI
import MusicPlayerKit

struct QueuePopoverView: View {
    @EnvironmentObject private var coordinator: PlaybackCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Playing Next")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Clear") {
                    coordinator.clearUpNext()
                }
                .buttonStyle(.link)
                .disabled(coordinator.upNext.isEmpty)
                .help("Clear the manually queued tracks")
            }
            .padding(12)

            Divider()

            if coordinator.upNext.isEmpty && coordinator.upcomingFromQueue.isEmpty {
                Text("Nothing queued")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if !coordinator.upNext.isEmpty {
                            ForEach(Array(coordinator.upNext.enumerated()), id: \.offset) { offset, track in
                                row(track, removeAction: { coordinator.removeFromUpNext(at: offset) })
                            }
                            if !coordinator.upcomingFromQueue.isEmpty {
                                Divider().padding(.vertical, 4)
                            }
                        }

                        ForEach(Array(coordinator.upcomingFromQueue.prefix(40).enumerated()), id: \.offset) { _, track in
                            row(track, removeAction: nil)
                        }
                    }
                }
            }
        }
        .frame(width: 280, height: 360)
    }

    @ViewBuilder
    private func row(_ track: Track, removeAction: (() -> Void)?) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Text(track.artist)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let removeAction {
                Button(action: removeAction) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}
