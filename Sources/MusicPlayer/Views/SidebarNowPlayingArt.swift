import SwiftUI
import AppKit
import MusicPlayerKit

/// A larger, prominent artwork display pinned to the bottom of the sidebar.
/// No title/artist labels here — those already show in the now-playing bar
/// at the top of the window, so repeating them would be redundant.
///
/// Sizes itself off the sidebar's actual width rather than a fixed 208pt,
/// so dragging the sidebar wider (it's resizable, 210–340pt) grows the
/// artwork instead of leaving it stuck at one size.
struct SidebarNowPlayingArt: View {
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var library: LibraryModel

    @State private var showingAlbumEdit = false
    @State private var availableWidth: CGFloat = 208
    @State private var newPlaceholderTrack: Track?

    private var artSize: CGFloat {
        max(120, min(availableWidth - 32, 320))
    }

    /// A single selected row in the track table wins first (most specific
    /// signal — you clicked exactly this track), then the album being
    /// browsed (so clicking an album shows its cover immediately, with no
    /// track selected or playing), then whatever's currently playing.
    private var displayTrack: Track? {
        if library.selectedTrackIDs.count == 1, let id = library.selectedTrackIDs.first,
           let track = library.tracks.first(where: { $0.path == id }) {
            return track
        }
        if library.selectedAlbums.count == 1, let album = library.selectedAlbums.first {
            return library.tracks.first(where: { $0.album == album })
        }
        return player.currentTrack
    }

    /// "Add Track…" only when a single album is actually being browsed —
    /// that's the one case its target album is unambiguous.
    private var browsedAlbum: String? {
        library.selectedAlbums.count == 1 ? library.selectedAlbums.first : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            ArtworkView(track: displayTrack, size: artSize, cornerRadius: 12)
                .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard let album = displayTrack?.album else { return }
                    library.resetAllFilters()
                    library.setAlbums([album])
                }
                .contextMenu {
                    if displayTrack != nil {
                        Button("Edit Album Info…") {
                            showingAlbumEdit = true
                        }
                        Button("Copy Artwork") {
                            copyArtwork()
                        }
                        Button("Paste Artwork") {
                            pasteArtwork()
                        }
                        Button("Show All Tracks") {
                            if let album = displayTrack?.album {
                                library.unhideAllTracks(inAlbum: album)
                            }
                        }
                        if let album = displayTrack?.album {
                            Toggle("Incomplete Resonance", isOn: Binding(
                                get: { library.incompleteRatingAlbums.contains(album) },
                                set: { _ in library.toggleIncompleteRating(forAlbum: album) }
                            ))
                        }
                    }
                    if let browsedAlbum {
                        Divider()
                        Button("Add Track…") {
                            newPlaceholderTrack = library.createPlaceholderTrack(album: browsedAlbum)
                        }
                    }
                }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { availableWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, newValue in
                        availableWidth = newValue
                    }
            }
        )
        .overlay(alignment: .top) { Divider() }
        .sheet(isPresented: $showingAlbumEdit) {
            if let album = displayTrack?.album {
                TrackEditSheet(tracks: library.tracks.filter { $0.album == album })
            }
        }
        .sheet(item: $newPlaceholderTrack) { track in
            TrackEditSheet(tracks: [track], isNewlyCreatedPlaceholder: true)
        }
    }

    private func copyArtwork() {
        guard let track = displayTrack else { return }
        Task {
            guard let image = await ArtworkLoader.shared.artwork(for: track) else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([image])
        }
    }

    private func pasteArtwork() {
        guard let track = displayTrack, let image = NSImage(pasteboard: .general), let data = image.pngData else { return }
        let albumTracks = library.tracks.filter { $0.album == track.album }
        library.setArtworkOverride(data, for: albumTracks)
    }
}
