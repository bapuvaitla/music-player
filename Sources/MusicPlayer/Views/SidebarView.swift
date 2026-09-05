import SwiftUI
import MusicPlayerKit

struct SidebarView: View {
    @EnvironmentObject private var library: LibraryModel

    @State private var showingNewPlaylistSheet = false
    @State private var showingNewSmartPlaylistSheet = false
    @State private var editingSmartPlaylist: Playlist?
    @State private var renamingPlaylist: Playlist?
    @AppStorage("sidebarExpanded_Playlists") private var isPlaylistsExpanded = false
    /// Same List/DisclosureGroup font-inheritance issue `SidebarFacetSection`
    /// works around — applied here too so playlist rows/Unrated match.
    @AppStorage("appFontPostscriptName") private var appFontPostscriptName: String = ""
    @AppStorage("appFontSize") private var appFontSize: Double = 13

    private var bodyFont: Font {
        appFontPostscriptName.isEmpty ? .system(size: appFontSize) : .custom(appFontPostscriptName, size: appFontSize)
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                // One shared Section for all five — List adds visible
                // breathing room *between* sections regardless of content,
                // which read as "random" gaps between collapsed rows that
                // should sit exactly as tight as any other row.
                Section {
                    // Clicking this already clears every filter, so a
                    // separate "Clear All" affordance elsewhere is
                    // redundant now — this row does that job on its own.
                    Button {
                        library.resetAllFilters()
                    } label: {
                        HStack(spacing: 6) {
                            SidebarHeadingText("All Tracks")
                                .foregroundStyle(Color.appAccent)
                            Spacer()
                            Text("\(library.visibleTracks.count)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(isAllTracksActive ? Color.appAccent.opacity(0.18) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if !library.artists.isEmpty {
                        SidebarFacetSection(
                            title: "Artists",
                            items: library.artists,
                            counts: library.artistTrackCounts,
                            selected: library.selectedArtists,
                            onSelectionChange: library.setArtists,
                            onClear: { library.selectedArtists.removeAll() }
                        )
                    }

                    if !library.albums.isEmpty {
                        SidebarFacetSection(
                            title: "Albums",
                            items: library.albums,
                            counts: [:],
                            ratings: library.albumAverageRatings,
                            partiallyRatedItems: library.partiallyRatedAlbums,
                            selected: library.selectedAlbums,
                            onSelectionChange: library.setAlbums,
                            onClear: { library.selectedAlbums.removeAll() },
                            onShowAllTracks: { library.unhideAllTracks(inAlbum: $0) },
                            incompleteRatingItems: library.incompleteRatingAlbums,
                            onToggleIncompleteRating: { library.toggleIncompleteRating(forAlbum: $0) }
                        )
                    }

                    if !library.genres.isEmpty {
                        SidebarFacetSection(
                            title: "Genres",
                            items: library.genres,
                            counts: library.genreTrackCounts,
                            selected: library.selectedGenres,
                            onSelectionChange: library.setGenres,
                            onClear: { library.selectedGenres.removeAll() }
                        )
                    }
                    // Collapsible, same as Artists/Albums/Genres above, and
                    // in the same shared Section — no gap before it either.
                    DisclosureGroup(isExpanded: $isPlaylistsExpanded) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(library.playlists) { playlist in
                                playlistRow(playlist)
                            }
                            // Unrated lives here, not in its own section —
                            // it's really just another named subset of the
                            // library, the same way a playlist is.
                            quickFilterRow(title: "Unrated", isActive: library.showUnratedOnly, count: library.unratedTrackCount) {
                                library.toggleUnratedOnly()
                            }
                            Menu {
                                Button("New Playlist…") { showingNewPlaylistSheet = true }
                                Button("New Smart Playlist…") { showingNewSmartPlaylistSheet = true }
                            } label: {
                                Text("Add Playlist")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary.opacity(0.6))
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                        }
                    } label: {
                        SidebarHeadingText("Playlists")
                    }
                    .disclosureGroupStyle(RightChevronDisclosureGroupStyle())
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            SidebarNowPlayingArt()
        }
        // `.ignoresSafeArea()` on the color, not the whole VStack — full
        // screen mode changes how much of the window's top the system
        // reserves (the menu-bar reveal zone), and without this the
        // sidebar's background didn't extend into that area, leaving a
        // plain white strip above the actual content there.
        .background(Color.sidebarBackground.ignoresSafeArea())
        .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 600)
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

    private func quickFilterRow(title: String, isActive: Bool, count: Int? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(bodyFont)
                    .foregroundStyle(isActive ? Color.primary : Color.secondary)
                Spacer()
                if let count {
                    Text("\(count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
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
    @AppStorage("appFontPostscriptName") private var appFontPostscriptName: String = ""
    @AppStorage("appFontSize") private var appFontSize: Double = 13

    private var bodyFont: Font {
        appFontPostscriptName.isEmpty ? .system(size: appFontSize) : .custom(appFontPostscriptName, size: appFontSize)
    }

    var body: some View {
        Button(action: onSelect) {
            HStack {
                Text(playlist.name)
                    .font(bodyFont)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                Spacer()
                Text("\(trackCount)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
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
