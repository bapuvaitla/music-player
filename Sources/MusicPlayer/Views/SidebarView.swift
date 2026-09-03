import SwiftUI
import MusicPlayerKit

struct SidebarView: View {
    @EnvironmentObject private var library: LibraryModel

    @State private var showingNewPlaylistSheet = false
    @State private var showingNewSmartPlaylistSheet = false
    @State private var editingSmartPlaylist: Playlist?
    @State private var renamingPlaylist: Playlist?

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    quickFilterRow(title: "All Tracks", systemImage: "music.note.list", isActive: isAllTracksActive) {
                        library.resetAllFilters()
                    }
                    quickFilterRow(title: "Unrated", systemImage: "star.slash", isActive: library.showUnratedOnly) {
                        library.toggleUnratedOnly()
                    }
                } header: {
                    if !isAllTracksActive {
                        HStack {
                            Text("Library")
                            Spacer()
                            Button("Clear All") {
                                library.resetAllFilters()
                            }
                            .buttonStyle(.link)
                            .font(.caption2)
                        }
                    }
                }

                if !library.artists.isEmpty {
                    Section {
                        SidebarFacetSection(
                            title: "Artists",
                            systemImage: "music.mic",
                            items: library.artists,
                            counts: library.artistTrackCounts,
                            selected: library.selectedArtists,
                            onSelectionChange: library.setArtists,
                            onClear: { library.selectedArtists.removeAll() }
                        )
                    }
                }

                if !library.albums.isEmpty {
                    Section {
                        SidebarFacetSection(
                            title: "Albums",
                            systemImage: "opticaldisc",
                            items: library.albums,
                            counts: [:],
                            ratings: library.albumAverageRatings,
                            partiallyRatedItems: library.partiallyRatedAlbums,
                            selected: library.selectedAlbums,
                            onSelectionChange: library.setAlbums,
                            onClear: { library.selectedAlbums.removeAll() },
                            onShowAllTracks: { library.unhideAllTracks(inAlbum: $0) }
                        )
                    }
                }

                if !library.genres.isEmpty {
                    Section {
                        SidebarFacetSection(
                            title: "Genres",
                            systemImage: "guitars",
                            items: library.genres,
                            counts: [:],
                            selected: library.selectedGenres,
                            onSelectionChange: library.setGenres,
                            onClear: { library.selectedGenres.removeAll() }
                        )
                    }
                }

                Section {
                    ForEach(library.playlists) { playlist in
                        playlistRow(playlist)
                    }
                    Menu {
                        Button("New Playlist…") { showingNewPlaylistSheet = true }
                        Button("New Smart Playlist…") { showingNewSmartPlaylistSheet = true }
                    } label: {
                        Label("Add Playlist", systemImage: "plus.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                } header: {
                    Text("Playlists")
                }
            }
            .listStyle(.sidebar)

            SidebarNowPlayingArt()
        }
        .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 340)
        .sheet(isPresented: $showingNewPlaylistSheet) {
            NewPlaylistSheet()
        }
        .sheet(isPresented: $showingNewSmartPlaylistSheet) {
            SmartPlaylistSheet(existing: nil)
        }
        .sheet(item: $editingSmartPlaylist) { playlist in
            SmartPlaylistSheet(existing: playlist)
        }
        .sheet(item: $renamingPlaylist) { playlist in
            RenamePlaylistSheet(playlist: playlist)
        }
    }

    private var isAllTracksActive: Bool {
        library.selectedArtists.isEmpty
            && library.selectedAlbums.isEmpty
            && library.selectedGenres.isEmpty
            && !library.showUnratedOnly
            && library.selectedPlaylistID == nil
    }

    private func quickFilterRow(title: String, systemImage: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(isActive ? Color.accentColor.opacity(0.18) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func playlistRow(_ playlist: Playlist) -> some View {
        PlaylistRow(
            playlist: playlist,
            isSelected: library.selectedPlaylistID == playlist.id,
            trackCount: library.resolvedTracks(for: playlist).count,
            onSelect: { library.selectPlaylist(playlist.id) },
            onDropPaths: { paths in
                guard !playlist.isSmart else { return false }
                var added = false
                for path in paths {
                    guard let track = library.visibleTracks.first(where: { $0.path == path }) else { continue }
                    library.addTrack(track, toPlaylistID: playlist.id)
                    added = true
                }
                return added
            },
            onEditSmart: { editingSmartPlaylist = playlist },
            onRename: { renamingPlaylist = playlist },
            onDelete: { library.deletePlaylist(playlist.id) }
        )
    }
}

/// One playlist row in the sidebar. A real (non-smart) playlist accepts
/// tracks dropped onto it — dragged from the main track list — adding
/// each to the end of the playlist; a smart playlist ignores drops since
/// its contents are computed from tag matches, not manual membership.
private struct PlaylistRow: View {
    let playlist: Playlist
    let isSelected: Bool
    let trackCount: Int
    let onSelect: () -> Void
    /// Returns true if at least one dropped path was added.
    let onDropPaths: ([String]) -> Bool
    let onEditSmart: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    @State private var isDropTargeted = false

    var body: some View {
        Button(action: onSelect) {
            HStack {
                Image(systemName: playlist.isSmart ? "gearshape.2" : "music.note.list")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(playlist.name)
                    .lineLimit(1)
                Spacer()
                Text("\(trackCount)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(rowBackground)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dropDestination(for: String.self) { items, _ in
            onDropPaths(items)
        } isTargeted: { targeted in
            isDropTargeted = targeted && !playlist.isSmart
        }
        .contextMenu {
            if playlist.isSmart {
                Button("Edit Smart Playlist…", action: onEditSmart)
            }
            Button("Rename…", action: onRename)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    private var rowBackground: Color {
        if isDropTargeted { return Color.accentColor.opacity(0.35) }
        if isSelected { return Color.accentColor.opacity(0.18) }
        return Color.clear
    }
}
