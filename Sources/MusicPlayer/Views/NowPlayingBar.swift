import SwiftUI
import MusicPlayerKit

struct NowPlayingBar: View {
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var coordinator: PlaybackCoordinator
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.openWindow) private var openWindow

    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0
    @State private var showingQueue = false

    var body: some View {
        HStack(spacing: 24) {
            trackInfo
                .frame(width: 230, alignment: .leading)

            transportControls

            scrubber

            volumeControl
                .frame(width: 130)

            queueControls

            Button {
                openWindow(id: "miniPlayer")
            } label: {
                Image(systemName: "pip")
                    .font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Open the floating mini player")
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 20)
        .background(Color.sidebarBackground)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var trackInfo: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(player.currentTrack?.title ?? "Not Playing")
                .font(.system(size: 21, weight: .semibold))
                .lineLimit(1)
            Text(player.currentTrack?.artist ?? " ")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var transportControls: some View {
        HStack(spacing: 26) {
            Button {
                coordinator.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .foregroundStyle(player.currentTrack == nil ? Color.secondary.opacity(0.4) : Color.primary)
            .disabled(player.currentTrack == nil)

            Button {
                coordinator.togglePlayPause(fallbackQueue: library.visibleTracks)
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 40))
            }
            .buttonStyle(.plain)
            .disabled(player.currentTrack == nil && library.visibleTracks.isEmpty)

            Button {
                coordinator.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .foregroundStyle(player.currentTrack == nil ? Color.secondary.opacity(0.4) : Color.primary)
            .disabled(player.currentTrack == nil)
        }
    }

    private var scrubber: some View {
        HStack(spacing: 8) {
            Text(timeString(isScrubbing ? scrubValue : player.currentTime))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 38, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubValue : player.currentTime },
                    set: { scrubValue = $0 }
                ),
                in: 0...max(player.duration, 0.1),
                onEditingChanged: { editing in
                    if editing {
                        isScrubbing = true
                        scrubValue = player.currentTime
                    } else {
                        player.seek(to: scrubValue)
                        isScrubbing = false
                    }
                }
            )
            .disabled(player.currentTrack == nil)

            Text(timeString(player.duration))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 38, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    private var volumeControl: some View {
        HStack(spacing: 6) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Slider(value: $player.volume, in: 0...1)
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    // Landed here (rather than the toolbar, with Columns/Font/Add
    // Music/Rescan) since BrowsingHeaderBar — which used to hold these —
    // was removed; nowhere else in the stated layout for them was named,
    // so this is a judgment call. Easy to relocate if it doesn't read
    // right in practice.
    private var shuffleForegroundColor: Color {
        switch coordinator.shuffleMode {
        case .off: return .secondary
        case .random: return .accentColor
        case .weighted: return .orange
        }
    }

    private var shuffleHelpText: String {
        switch coordinator.shuffleMode {
        case .off: return "Shuffle"
        case .random: return "Shuffle"
        case .weighted: return "Weighted Shuffle (favors higher-rated and unrated tracks)"
        }
    }

    private var queueControls: some View {
        HStack(spacing: 14) {
            Button {
                coordinator.cycleShuffleMode()
            } label: {
                Image(systemName: "shuffle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(shuffleForegroundColor)
            .help(shuffleHelpText)

            Button {
                coordinator.cycleRepeatMode()
            } label: {
                Image(systemName: coordinator.repeatMode == .one ? "repeat.1" : "repeat")
            }
            .buttonStyle(.plain)
            .foregroundStyle(coordinator.repeatMode == .off ? Color.secondary : Color.accentColor)
            .help(repeatHelpText)

            Button {
                showingQueue.toggle()
            } label: {
                Image(systemName: "list.bullet")
            }
            .buttonStyle(.plain)
            .foregroundStyle(coordinator.upNext.isEmpty ? Color.secondary : Color.accentColor)
            .help("Playing next")
            .popover(isPresented: $showingQueue, arrowEdge: .bottom) {
                QueuePopoverView()
            }
        }
        .font(.system(size: 14))
    }

    private var repeatHelpText: String {
        switch coordinator.repeatMode {
        case .off: return "Repeat: off"
        case .all: return "Repeat: all"
        case .one: return "Repeat: one"
        }
    }

    private func timeString(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let total = Int(time.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
