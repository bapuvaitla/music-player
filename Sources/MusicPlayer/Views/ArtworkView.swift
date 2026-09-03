import SwiftUI
import MusicPlayerKit

struct ArtworkView: View {
    let track: Track?
    var size: CGFloat = 44
    var cornerRadius: CGFloat = 6

    @EnvironmentObject private var library: LibraryModel
    @State private var image: NSImage?

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.secondary.opacity(0.15))
            .frame(width: size, height: size)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.4))
                        .foregroundStyle(.secondary)
                }
            }
            // Keying on artworkVersion too (not just the track's path) is
            // what makes replacing/resetting a track's artwork actually
            // show up here — the path doesn't change when only the image
            // behind it does.
            .task(id: TaskID(path: track?.path, artworkVersion: library.artworkVersion)) {
                image = nil
                guard let track else { return }
                image = await ArtworkLoader.shared.artwork(for: track)
            }
    }

    private struct TaskID: Equatable {
        let path: String?
        let artworkVersion: Int
    }
}
