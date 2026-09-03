import SwiftUI
import AppKit
import MusicPlayerKit

struct TrackListView: View {
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var coordinator: PlaybackCoordinator

    @State private var selection: Set<Track.ID> = []
    @State private var sortOrder: [KeyPathComparator<Track>] = [
        KeyPathComparator(\.title, order: .forward)
    ]
    @State private var editingSelection: EditingSelection?
    @State private var locateRowIndex: Int?
    @State private var locateTrigger = 0
    /// Tracks awaiting the delete confirmation below — only populated when
    /// the selection includes at least one real, file-backed track (a
    /// placeholder alone deletes immediately, no confirmation needed,
    /// since it's just a manually-entered stand-in with nothing at stake).
    @State private var tracksPendingDeletion: [Track] = []

    /// A `.sheet(isPresented:)` reuses the presented view's `@State`
    /// across separate presentations whenever SwiftUI treats them as "the
    /// same" view identity — which a bare Bool can't distinguish between
    /// "open the sheet again for the same track" and "open it for a
    /// different one." That's what made Cmd+I intermittently show stale
    /// (sometimes blank) fields from whatever was edited previously.
    /// `.sheet(item:)` keyed on a fresh id every time sidesteps this
    /// entirely: a new identity always means a fresh `TrackEditSheet`.
    private struct EditingSelection: Identifiable {
        let id = UUID()
        let tracks: [Track]
        let navigationContext: [Track]
    }

    /// Rows allowed to act as a drag source right now. Deliberately lags
    /// `selection` by a beat: arming a row as draggable the instant it's
    /// selected means the *second* click of a double-click can land on a
    /// freshly drag-enabled view and get eaten by drag-gesture recognition
    /// instead of registering as the double-click. Waiting past the
    /// double-click window before arming it avoids that race, at the cost
    /// of needing a short pause between "select" and "drag" — matching the
    /// click-then-drag convention this already followed.
    @State private var dragArmedIDs: Set<Track.ID> = []

    /// Mirrors the sidebar Albums section's A–Z/rating toggle (same
    /// `@AppStorage` key — see `SidebarFacetSection`) so the main table can
    /// match it: browsing All Tracks with albums sorted by rating reads far
    /// better grouped by album (in that rating order) and ordered by track
    /// number within each album than plain alphabetically-by-title.
    @AppStorage("sidebarFacetSortByRating") private var albumsSortedByRating = false

    private var isAllTracksView: Bool {
        library.selectedArtists.isEmpty
            && library.selectedAlbums.isEmpty
            && library.selectedGenres.isEmpty
            && !library.showUnratedOnly
            && library.selectedPlaylistID == nil
    }

    /// Each album's rank in the sidebar's current rating-sorted order
    /// (0 = highest-rated), for grouping the main table the same way.
    private var albumRatingRank: [String: Int] {
        let ranked = library.albums.sorted { lhs, rhs in
            let left = library.albumAverageRatings[lhs] ?? -1
            let right = library.albumAverageRatings[rhs] ?? -1
            if left != right { return left > right }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        return Dictionary(uniqueKeysWithValues: ranked.enumerated().map { ($1, $0) })
    }

    /// The disc/track order album-rank grouping defaults to when it turns
    /// on (see the `albumsSortedByRating` onChange below) — comparing
    /// against this is how `sortedTracks` tells "still the smart default"
    /// apart from "the user clicked a header since then."
    private static let albumGroupingDefaultOrder: [KeyPathComparator<Track>] = [
        KeyPathComparator(\.discNumberSortKey, order: .forward),
        KeyPathComparator(\.trackNumberSortKey, order: .forward)
    ]

    private var sortedTracks: [Track] {
        let base = library.filteredTracks.sorted(using: sortOrder)
        // Album-rank grouping is a default view, not a lock — clicking any
        // header is a deliberate, explicit request to sort the whole list
        // by that column, so it must always fully win, not just become a
        // tiebreak within each album's group (which read as "sorting does
        // nothing" — you'd click a header and the list would still look
        // grouped by album). Comparing sortOrder against the exact default
        // this mode sets is how a header click is detected: any other
        // value means the user chose it, so grouping steps aside.
        guard isAllTracksView, albumsSortedByRating, sortOrder == Self.albumGroupingDefaultOrder else {
            return base
        }

        let rank = albumRatingRank
        return base.sorted { lhs, rhs in
            (rank[lhs.album] ?? Int.max) < (rank[rhs.album] ?? Int.max)
        }
    }

    private var activePlaylist: Playlist? {
        guard let id = library.selectedPlaylistID else { return nil }
        return library.playlists.first(where: { $0.id == id })
    }

    var body: some View {
        Group {
            if library.isScanning {
                scanningPlaceholder
            } else if library.tracks.isEmpty {
                emptyLibraryPlaceholder
            } else if sortedTracks.isEmpty {
                Text("No tracks match this filter")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table
            }
        }
        .navigationTitle(library.currentViewTitle)
        .onChange(of: selection) { _, newValue in
            library.selectedTrackIDs = newValue
            dragArmedIDs.removeAll()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if selection == newValue {
                    dragArmedIDs = newValue
                }
            }
        }
        .onChange(of: library.selectedAlbums) { _, newValue in
            // Browsing an album reads far better in disc/track order than
            // alphabetically; you can still click a header to override it.
            if !newValue.isEmpty {
                sortOrder = [
                    KeyPathComparator(\.discNumberSortKey, order: .forward),
                    KeyPathComparator(\.trackNumberSortKey, order: .forward)
                ]
            } else {
                sortOrder = [KeyPathComparator(\.title, order: .forward)]
            }
        }
        .onChange(of: albumsSortedByRating) { _, newValue in
            // Same idea as browsing a single album above: switching on
            // "sort albums by rating" reads better with each album's
            // tracks in disc/track order — still just a default, a header
            // click after this still wins (see sortedTracks).
            guard isAllTracksView else { return }
            sortOrder = newValue ? Self.albumGroupingDefaultOrder : [KeyPathComparator(\.title, order: .forward)]
        }
    }

    private var table: some View {
        Table(sortedTracks, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("") { track in
                if track.id == player.currentTrack?.id {
                    Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                        .foregroundStyle(Color.accentColor)
                        .font(.system(size: 11))
                }
            }
            .width(18)

            TableColumn("") { track in
                if track.rating >= 10 {
                    Image(systemName: "star")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.secondary.opacity(0.55))
                }
            }
            .width(14)

            columnSlotsGroup1

            columnSlotsGroup2

            columnSlotsGroup3

            columnSlotsGroup4
        }
        // Forces Table to fully rebuild its column set when visibility or
        // order changes — SwiftUI's Table doesn't always pick up column
        // set/order changes from state alone.
        .id(library.orderedVisibleColumns)
        .background(TableScrollController(rowIndex: locateRowIndex, trigger: locateTrigger))
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: Track.ID.self) { ids in
            let selectedTracks = sortedTracks.filter { ids.contains($0.id) }
            if !selectedTracks.isEmpty {
                if selectedTracks.count == 1, let track = selectedTracks.first {
                    // Placeholder tracks (see Track.isPlaceholder) have no
                    // file to play, so playback actions don't apply.
                    if !track.isPlaceholder {
                        Button("Play") {
                            coordinator.play(track: track, in: sortedTracks)
                        }
                        Button("Play Next") {
                            coordinator.playNext(track)
                        }
                        Button("Add to Queue") {
                            coordinator.addToQueue(track)
                        }
                    }
                } else {
                    Button("Play Next") {
                        for track in selectedTracks.reversed() {
                            coordinator.playNext(track)
                        }
                    }
                    Button("Add to Queue") {
                        for track in selectedTracks {
                            coordinator.addToQueue(track)
                        }
                    }
                }

                // No .keyboardShortcut here — Cmd+I is handled once, below,
                // by the Table's own .onKeyPress("i"), which always
                // recomputes the current selection fresh. Also binding the
                // shortcut to this button meant two competing Cmd+I
                // registrations: this one's `selectedTracks` is captured
                // when contextMenu's closure last ran (typically when the
                // menu was last opened), not on every keystroke, so it
                // could go stale and fire with an empty/outdated selection
                // — exactly the "first press shows an empty record" bug.
                Button(selectedTracks.count == 1 ? "Edit Info…" : "Edit Info (\(selectedTracks.count) Tracks)…") {
                    editingSelection = EditingSelection(tracks: selectedTracks, navigationContext: sortedTracks)
                }

                let regularPlaylists = library.playlists.filter { !$0.isSmart }
                if !regularPlaylists.isEmpty {
                    Menu("Add to Playlist") {
                        ForEach(regularPlaylists) { playlist in
                            Button(playlist.name) {
                                for track in selectedTracks {
                                    library.addTrack(track, toPlaylistID: playlist.id)
                                }
                            }
                        }
                    }
                }

                if let playlist = activePlaylist, !playlist.isSmart {
                    Button("Remove from Playlist", role: .destructive) {
                        for track in selectedTracks {
                            library.removeTrack(track, fromPlaylistID: playlist.id)
                        }
                    }
                }

                Divider()
                if selectedTracks.count == 1, let track = selectedTracks.first {
                    Button("Copy Artwork") {
                        copyArtwork(for: track)
                    }
                }
                Button(selectedTracks.count == 1 ? "Paste Artwork" : "Paste Artwork for \(selectedTracks.count) Tracks") {
                    pasteArtwork(for: selectedTracks)
                }

                Divider()
                Button(selectedTracks.count == 1 ? "Hide Track" : "Hide \(selectedTracks.count) Tracks") {
                    library.setHidden(true, for: selectedTracks)
                }
                Button(
                    selectedTracks.count == 1 ? "Delete Track" : "Delete \(selectedTracks.count) Tracks",
                    role: .destructive
                ) {
                    requestDelete(selectedTracks)
                }

                Divider()
                // Table headers don't support a right-click menu on macOS
                // (no public SwiftUI API for it), so this submenu doubles
                // as the right-click path to the same column toggles the
                // toolbar's Columns popover offers.
                Menu("Columns") {
                    ForEach(TrackColumn.allCases.filter { !$0.isAlwaysVisible }) { column in
                        Button {
                            library.toggleColumn(column)
                        } label: {
                            if library.visibleColumns.contains(column) {
                                Label(column.title, systemImage: "checkmark")
                            } else {
                                Text(column.title)
                            }
                        }
                    }
                }
            }
        } primaryAction: { ids in
            // The documented, reliable way to get double-click on a Table
            // row on macOS — plain onTapGesture(count: 2) fights Table's
            // own single-click selection handling and was landing
            // inconsistently.
            if let id = ids.first, let track = sortedTracks.first(where: { $0.id == id }) {
                coordinator.play(track: track, in: sortedTracks)
            }
        }
        .onKeyPress(.return) {
            guard selection.count == 1, let id = selection.first,
                  let track = sortedTracks.first(where: { $0.id == id }) else { return .ignored }
            coordinator.play(track: track, in: sortedTracks)
            return .handled
        }
        // Cmd+I and Cmd+L are owned by the menu bar's commands (see
        // MusicPlayerApp), not bound here directly — this view only reacts
        // to the resulting notification. Keeping the shortcut in exactly
        // one place avoids the double-registration bug that used to make
        // Cmd+I intermittently open an empty edit sheet.
        .onReceive(NotificationCenter.default.publisher(for: .requestEditInfo)) { _ in
            let selectedTracks = sortedTracks.filter { selection.contains($0.id) }
            guard !selectedTracks.isEmpty else { return }
            editingSelection = EditingSelection(tracks: selectedTracks, navigationContext: sortedTracks)
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestLocatePlayingTrack)) { _ in
            guard let currentID = player.currentTrack?.id,
                  let index = sortedTracks.firstIndex(where: { $0.id == currentID }) else { return }
            selection = [currentID]
            locateRowIndex = index
            locateTrigger += 1
        }
        .sheet(item: $editingSelection) { editing in
            TrackEditSheet(tracks: editing.tracks, navigationContext: editing.navigationContext)
        }
        .confirmationDialog(
            tracksPendingDeletion.count == 1
                ? "Delete “\(tracksPendingDeletion.first?.title ?? "")”?"
                : "Delete \(tracksPendingDeletion.count) Tracks?",
            isPresented: Binding(
                get: { !tracksPendingDeletion.isEmpty },
                set: { if !$0 { tracksPendingDeletion = [] } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                for track in tracksPendingDeletion {
                    library.deleteTrack(track)
                }
                tracksPendingDeletion = []
            }
        } message: {
            Text("This removes \(tracksPendingDeletion.count == 1 ? "it" : "them") from the library. The audio file itself isn't touched, but — unlike Hide — a rescan won't bring \(tracksPendingDeletion.count == 1 ? "it" : "them") back.")
        }
    }

    /// Placeholders delete immediately; a selection with any real,
    /// file-backed track goes through confirmation first, since — unlike
    /// Hide — a rescan won't undo it.
    private func requestDelete(_ tracksToDelete: [Track]) {
        guard !tracksToDelete.allSatisfy(\.isPlaceholder) else {
            for track in tracksToDelete { library.deletePlaceholderTrack(track) }
            return
        }
        tracksPendingDeletion = tracksToDelete
    }

    // Every column — including Title/Artist/Album/Time/Rating — is now
    // user-orderable. TableColumnBuilder only accepts literal TableColumn
    // values (no ForEach, confirmed via a standalone compile test), so
    // order is expressed as 14 fixed "slots", each checking which column
    // the user placed there. Grouped into four properties since a single
    // builder block caps out at 10 items.
    @TableColumnBuilder<Track, KeyPathComparator<Track>>
    private var columnSlotsGroup1: some TableColumnContent<Track, KeyPathComparator<Track>> {
        columnSlot0
        columnSlot1
        columnSlot2
        columnSlot3
    }

    @TableColumnBuilder<Track, KeyPathComparator<Track>>
    private var columnSlotsGroup2: some TableColumnContent<Track, KeyPathComparator<Track>> {
        columnSlot4
        columnSlot5
        columnSlot6
        columnSlot7
    }

    @TableColumnBuilder<Track, KeyPathComparator<Track>>
    private var columnSlotsGroup3: some TableColumnContent<Track, KeyPathComparator<Track>> {
        columnSlot8
        columnSlot9
        columnSlot10
        columnSlot11
    }

    @TableColumnBuilder<Track, KeyPathComparator<Track>>
    private var columnSlotsGroup4: some TableColumnContent<Track, KeyPathComparator<Track>> {
        columnSlot12
        columnSlot13
    }

    /// Accent color for the currently-playing track's text, across every
    /// column — a plain per-cell background looked broken (Table has no
    /// real row-background API, and the padding gaps between cells showed),
    /// but coloring the text itself doesn't have that problem.
    ///
    /// A selected row gets Table's native blue highlight behind it, and
    /// neither `.primary` nor `.accentColor` text has enough contrast
    /// against that — so a selected row's text goes white regardless of
    /// whether it's also the playing track (the speaker icon and bold
    /// title weight already carry that distinction on their own).
    private func rowTextColor(_ track: Track) -> Color {
        if selection.contains(track.id) { return .white }
        if track.isPlaceholder { return .secondary }
        return track.id == player.currentTrack?.id ? Color.accentColor : Color.primary
    }

    private func copyArtwork(for track: Track) {
        Task {
            guard let image = await ArtworkLoader.shared.artwork(for: track) else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([image])
        }
    }

    private func pasteArtwork(for tracks: [Track]) {
        guard let image = NSImage(pasteboard: .general), let data = image.pngData else { return }
        library.setArtworkOverride(data, for: tracks)
    }

    @TableColumnBuilder<Track, KeyPathComparator<Track>>
    private var columnSlot0: some TableColumnContent<Track, KeyPathComparator<Track>> {
        if library.orderedVisibleColumns.indices.contains(0), library.orderedVisibleColumns[0] == .title {
            TableColumn("Title", value: \.title) { track in
                Text(track.title)
                    .fontWeight(track.id == player.currentTrack?.id ? .semibold : .regular)
                    .foregroundStyle(rowTextColor(track))
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .modifier(ReorderModifier(track: track, playlist: activePlaylist, library: library, isDragArmed: dragArmedIDs.contains(track.id)))
            }
            .width(min: 160, ideal: 260)
        } else if library.orderedVisibleColumns.indices.contains(0), library.orderedVisibleColumns[0] == .artist {
            TableColumn("Artist", value: \.artist) { track in
                Text(track.artist).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(0), library.orderedVisibleColumns[0] == .album {
            TableColumn("Album", value: \.album) { track in
                Text(track.album).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 100, ideal: 180)
        } else if library.orderedVisibleColumns.indices.contains(0), library.orderedVisibleColumns[0] == .genre {
            TableColumn("Genre", value: \.genre) { track in
                Text(track.genre).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 70, ideal: 100)
        } else if library.orderedVisibleColumns.indices.contains(0), library.orderedVisibleColumns[0] == .year {
            TableColumn("Year", value: \.yearSortKey) { track in
                Text(track.year.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(0), library.orderedVisibleColumns[0] == .trackNumber {
            TableColumn("Track #", value: \.trackNumberSortKey) { track in
                Text(track.trackNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(50)
        } else if library.orderedVisibleColumns.indices.contains(0), library.orderedVisibleColumns[0] == .discNumber {
            TableColumn("Disc #", value: \.discNumberSortKey) { track in
                Text(track.discNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(50)
        } else if library.orderedVisibleColumns.indices.contains(0), library.orderedVisibleColumns[0] == .bpm {
            TableColumn("BPM", value: \.bpmSortKey) { track in
                Text(track.bpm.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(0), library.orderedVisibleColumns[0] == .key {
            TableColumn("Key", value: \.keySortKey) { track in
                Text(track.key ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(0), library.orderedVisibleColumns[0] == .comments {
            TableColumn("Comments", value: \.commentsSortKey) { track in
                Text(track.comments ?? "").foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(0), library.orderedVisibleColumns[0] == .plays {
            TableColumn("Plays", value: \.playCount) { track in
                Text(track.playCount > 0 ? String(format: "%.1f", track.playCount) : "–").foregroundStyle(rowTextColor(track)).monospacedDigit()
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(0), library.orderedVisibleColumns[0] == .tags {
            TableColumn("Tags", value: \.tagsSortKey) { track in
                Text(track.tags.joined(separator: ", ")).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 80, ideal: 140)
        } else if library.orderedVisibleColumns.indices.contains(0), library.orderedVisibleColumns[0] == .time {
            TableColumn("Time", value: \.duration) { track in
                Text(track.durationString).foregroundStyle(rowTextColor(track)).monospacedDigit()
            }
            .width(50)
        } else if library.orderedVisibleColumns.indices.contains(0), library.orderedVisibleColumns[0] == .rating {
            TableColumn("Rating", value: \.rating) { track in
                RatingCellView(
                    rating: Binding(
                        get: { track.rating },
                        set: { library.setRating($0, for: track) }
                    ),
                    isSelected: selection.count == 1 && selection.contains(track.id)
                )
            }
            .width(min: 110, ideal: 130)
        }
    }

    @TableColumnBuilder<Track, KeyPathComparator<Track>>
    private var columnSlot1: some TableColumnContent<Track, KeyPathComparator<Track>> {
        if library.orderedVisibleColumns.indices.contains(1), library.orderedVisibleColumns[1] == .title {
            TableColumn("Title", value: \.title) { track in
                Text(track.title)
                    .fontWeight(track.id == player.currentTrack?.id ? .semibold : .regular)
                    .foregroundStyle(rowTextColor(track))
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .modifier(ReorderModifier(track: track, playlist: activePlaylist, library: library, isDragArmed: dragArmedIDs.contains(track.id)))
            }
            .width(min: 160, ideal: 260)
        } else if library.orderedVisibleColumns.indices.contains(1), library.orderedVisibleColumns[1] == .artist {
            TableColumn("Artist", value: \.artist) { track in
                Text(track.artist).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(1), library.orderedVisibleColumns[1] == .album {
            TableColumn("Album", value: \.album) { track in
                Text(track.album).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 100, ideal: 180)
        } else if library.orderedVisibleColumns.indices.contains(1), library.orderedVisibleColumns[1] == .genre {
            TableColumn("Genre", value: \.genre) { track in
                Text(track.genre).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 70, ideal: 100)
        } else if library.orderedVisibleColumns.indices.contains(1), library.orderedVisibleColumns[1] == .year {
            TableColumn("Year", value: \.yearSortKey) { track in
                Text(track.year.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(1), library.orderedVisibleColumns[1] == .trackNumber {
            TableColumn("Track #", value: \.trackNumberSortKey) { track in
                Text(track.trackNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(50)
        } else if library.orderedVisibleColumns.indices.contains(1), library.orderedVisibleColumns[1] == .discNumber {
            TableColumn("Disc #", value: \.discNumberSortKey) { track in
                Text(track.discNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(50)
        } else if library.orderedVisibleColumns.indices.contains(1), library.orderedVisibleColumns[1] == .bpm {
            TableColumn("BPM", value: \.bpmSortKey) { track in
                Text(track.bpm.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(1), library.orderedVisibleColumns[1] == .key {
            TableColumn("Key", value: \.keySortKey) { track in
                Text(track.key ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(1), library.orderedVisibleColumns[1] == .comments {
            TableColumn("Comments", value: \.commentsSortKey) { track in
                Text(track.comments ?? "").foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(1), library.orderedVisibleColumns[1] == .plays {
            TableColumn("Plays", value: \.playCount) { track in
                Text(track.playCount > 0 ? String(format: "%.1f", track.playCount) : "–").foregroundStyle(rowTextColor(track)).monospacedDigit()
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(1), library.orderedVisibleColumns[1] == .tags {
            TableColumn("Tags", value: \.tagsSortKey) { track in
                Text(track.tags.joined(separator: ", ")).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 80, ideal: 140)
        } else if library.orderedVisibleColumns.indices.contains(1), library.orderedVisibleColumns[1] == .time {
            TableColumn("Time", value: \.duration) { track in
                Text(track.durationString).foregroundStyle(rowTextColor(track)).monospacedDigit()
            }
            .width(50)
        } else if library.orderedVisibleColumns.indices.contains(1), library.orderedVisibleColumns[1] == .rating {
            TableColumn("Rating", value: \.rating) { track in
                RatingCellView(
                    rating: Binding(
                        get: { track.rating },
                        set: { library.setRating($0, for: track) }
                    ),
                    isSelected: selection.count == 1 && selection.contains(track.id)
                )
            }
            .width(min: 110, ideal: 130)
        }
    }

    @TableColumnBuilder<Track, KeyPathComparator<Track>>
    private var columnSlot2: some TableColumnContent<Track, KeyPathComparator<Track>> {
        if library.orderedVisibleColumns.indices.contains(2), library.orderedVisibleColumns[2] == .title {
            TableColumn("Title", value: \.title) { track in
                Text(track.title)
                    .fontWeight(track.id == player.currentTrack?.id ? .semibold : .regular)
                    .foregroundStyle(rowTextColor(track))
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .modifier(ReorderModifier(track: track, playlist: activePlaylist, library: library, isDragArmed: dragArmedIDs.contains(track.id)))
            }
            .width(min: 160, ideal: 260)
        } else if library.orderedVisibleColumns.indices.contains(2), library.orderedVisibleColumns[2] == .artist {
            TableColumn("Artist", value: \.artist) { track in
                Text(track.artist).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(2), library.orderedVisibleColumns[2] == .album {
            TableColumn("Album", value: \.album) { track in
                Text(track.album).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 100, ideal: 180)
        } else if library.orderedVisibleColumns.indices.contains(2), library.orderedVisibleColumns[2] == .genre {
            TableColumn("Genre", value: \.genre) { track in
                Text(track.genre).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 70, ideal: 100)
        } else if library.orderedVisibleColumns.indices.contains(2), library.orderedVisibleColumns[2] == .year {
            TableColumn("Year", value: \.yearSortKey) { track in
                Text(track.year.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(2), library.orderedVisibleColumns[2] == .trackNumber {
            TableColumn("Track #", value: \.trackNumberSortKey) { track in
                Text(track.trackNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(50)
        } else if library.orderedVisibleColumns.indices.contains(2), library.orderedVisibleColumns[2] == .discNumber {
            TableColumn("Disc #", value: \.discNumberSortKey) { track in
                Text(track.discNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(50)
        } else if library.orderedVisibleColumns.indices.contains(2), library.orderedVisibleColumns[2] == .bpm {
            TableColumn("BPM", value: \.bpmSortKey) { track in
                Text(track.bpm.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(2), library.orderedVisibleColumns[2] == .key {
            TableColumn("Key", value: \.keySortKey) { track in
                Text(track.key ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(2), library.orderedVisibleColumns[2] == .comments {
            TableColumn("Comments", value: \.commentsSortKey) { track in
                Text(track.comments ?? "").foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(2), library.orderedVisibleColumns[2] == .plays {
            TableColumn("Plays", value: \.playCount) { track in
                Text(track.playCount > 0 ? String(format: "%.1f", track.playCount) : "–").foregroundStyle(rowTextColor(track)).monospacedDigit()
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(2), library.orderedVisibleColumns[2] == .tags {
            TableColumn("Tags", value: \.tagsSortKey) { track in
                Text(track.tags.joined(separator: ", ")).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 80, ideal: 140)
        } else if library.orderedVisibleColumns.indices.contains(2), library.orderedVisibleColumns[2] == .time {
            TableColumn("Time", value: \.duration) { track in
                Text(track.durationString).foregroundStyle(rowTextColor(track)).monospacedDigit()
            }
            .width(50)
        } else if library.orderedVisibleColumns.indices.contains(2), library.orderedVisibleColumns[2] == .rating {
            TableColumn("Rating", value: \.rating) { track in
                RatingCellView(
                    rating: Binding(
                        get: { track.rating },
                        set: { library.setRating($0, for: track) }
                    ),
                    isSelected: selection.count == 1 && selection.contains(track.id)
                )
            }
            .width(min: 110, ideal: 130)
        }
    }

    @TableColumnBuilder<Track, KeyPathComparator<Track>>
    private var columnSlot3: some TableColumnContent<Track, KeyPathComparator<Track>> {
        if library.orderedVisibleColumns.indices.contains(3), library.orderedVisibleColumns[3] == .title {
            TableColumn("Title", value: \.title) { track in
                Text(track.title)
                    .fontWeight(track.id == player.currentTrack?.id ? .semibold : .regular)
                    .foregroundStyle(rowTextColor(track))
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .modifier(ReorderModifier(track: track, playlist: activePlaylist, library: library, isDragArmed: dragArmedIDs.contains(track.id)))
            }
            .width(min: 160, ideal: 260)
        } else if library.orderedVisibleColumns.indices.contains(3), library.orderedVisibleColumns[3] == .artist {
            TableColumn("Artist", value: \.artist) { track in
                Text(track.artist).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(3), library.orderedVisibleColumns[3] == .album {
            TableColumn("Album", value: \.album) { track in
                Text(track.album).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 100, ideal: 180)
        } else if library.orderedVisibleColumns.indices.contains(3), library.orderedVisibleColumns[3] == .genre {
            TableColumn("Genre", value: \.genre) { track in
                Text(track.genre).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 70, ideal: 100)
        } else if library.orderedVisibleColumns.indices.contains(3), library.orderedVisibleColumns[3] == .year {
            TableColumn("Year", value: \.yearSortKey) { track in
                Text(track.year.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(3), library.orderedVisibleColumns[3] == .trackNumber {
            TableColumn("Track #", value: \.trackNumberSortKey) { track in
                Text(track.trackNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(50)
        } else if library.orderedVisibleColumns.indices.contains(3), library.orderedVisibleColumns[3] == .discNumber {
            TableColumn("Disc #", value: \.discNumberSortKey) { track in
                Text(track.discNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(50)
        } else if library.orderedVisibleColumns.indices.contains(3), library.orderedVisibleColumns[3] == .bpm {
            TableColumn("BPM", value: \.bpmSortKey) { track in
                Text(track.bpm.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(3), library.orderedVisibleColumns[3] == .key {
            TableColumn("Key", value: \.keySortKey) { track in
                Text(track.key ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(3), library.orderedVisibleColumns[3] == .comments {
            TableColumn("Comments", value: \.commentsSortKey) { track in
                Text(track.comments ?? "").foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(3), library.orderedVisibleColumns[3] == .plays {
            TableColumn("Plays", value: \.playCount) { track in
                Text(track.playCount > 0 ? String(format: "%.1f", track.playCount) : "–").foregroundStyle(rowTextColor(track)).monospacedDigit()
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(3), library.orderedVisibleColumns[3] == .tags {
            TableColumn("Tags", value: \.tagsSortKey) { track in
                Text(track.tags.joined(separator: ", ")).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 80, ideal: 140)
        } else if library.orderedVisibleColumns.indices.contains(3), library.orderedVisibleColumns[3] == .time {
            TableColumn("Time", value: \.duration) { track in
                Text(track.durationString).foregroundStyle(rowTextColor(track)).monospacedDigit()
            }
            .width(50)
        } else if library.orderedVisibleColumns.indices.contains(3), library.orderedVisibleColumns[3] == .rating {
            TableColumn("Rating", value: \.rating) { track in
                RatingCellView(
                    rating: Binding(
                        get: { track.rating },
                        set: { library.setRating($0, for: track) }
                    ),
                    isSelected: selection.count == 1 && selection.contains(track.id)
                )
            }
            .width(min: 110, ideal: 130)
        }
    }

    @TableColumnBuilder<Track, KeyPathComparator<Track>>
    private var columnSlot4: some TableColumnContent<Track, KeyPathComparator<Track>> {
        if library.orderedVisibleColumns.indices.contains(4), library.orderedVisibleColumns[4] == .title {
            TableColumn("Title", value: \.title) { track in
                Text(track.title)
                    .fontWeight(track.id == player.currentTrack?.id ? .semibold : .regular)
                    .foregroundStyle(rowTextColor(track))
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .modifier(ReorderModifier(track: track, playlist: activePlaylist, library: library, isDragArmed: dragArmedIDs.contains(track.id)))
            }
            .width(min: 160, ideal: 260)
        } else if library.orderedVisibleColumns.indices.contains(4), library.orderedVisibleColumns[4] == .artist {
            TableColumn("Artist", value: \.artist) { track in
                Text(track.artist).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(4), library.orderedVisibleColumns[4] == .album {
            TableColumn("Album", value: \.album) { track in
                Text(track.album).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 100, ideal: 180)
        } else if library.orderedVisibleColumns.indices.contains(4), library.orderedVisibleColumns[4] == .genre {
            TableColumn("Genre", value: \.genre) { track in
                Text(track.genre).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 70, ideal: 100)
        } else if library.orderedVisibleColumns.indices.contains(4), library.orderedVisibleColumns[4] == .year {
            TableColumn("Year", value: \.yearSortKey) { track in
                Text(track.year.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(4), library.orderedVisibleColumns[4] == .trackNumber {
            TableColumn("Track #", value: \.trackNumberSortKey) { track in
                Text(track.trackNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(50)
        } else if library.orderedVisibleColumns.indices.contains(4), library.orderedVisibleColumns[4] == .discNumber {
            TableColumn("Disc #", value: \.discNumberSortKey) { track in
                Text(track.discNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(50)
        } else if library.orderedVisibleColumns.indices.contains(4), library.orderedVisibleColumns[4] == .bpm {
            TableColumn("BPM", value: \.bpmSortKey) { track in
                Text(track.bpm.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(4), library.orderedVisibleColumns[4] == .key {
            TableColumn("Key", value: \.keySortKey) { track in
                Text(track.key ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(4), library.orderedVisibleColumns[4] == .comments {
            TableColumn("Comments", value: \.commentsSortKey) { track in
                Text(track.comments ?? "").foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(4), library.orderedVisibleColumns[4] == .plays {
            TableColumn("Plays", value: \.playCount) { track in
                Text(track.playCount > 0 ? String(format: "%.1f", track.playCount) : "–").foregroundStyle(rowTextColor(track)).monospacedDigit()
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(4), library.orderedVisibleColumns[4] == .tags {
            TableColumn("Tags", value: \.tagsSortKey) { track in
                Text(track.tags.joined(separator: ", ")).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 80, ideal: 140)
        } else if library.orderedVisibleColumns.indices.contains(4), library.orderedVisibleColumns[4] == .time {
            TableColumn("Time", value: \.duration) { track in
                Text(track.durationString).foregroundStyle(rowTextColor(track)).monospacedDigit()
            }
            .width(50)
        } else if library.orderedVisibleColumns.indices.contains(4), library.orderedVisibleColumns[4] == .rating {
            TableColumn("Rating", value: \.rating) { track in
                RatingCellView(
                    rating: Binding(
                        get: { track.rating },
                        set: { library.setRating($0, for: track) }
                    ),
                    isSelected: selection.count == 1 && selection.contains(track.id)
                )
            }
            .width(min: 110, ideal: 130)
        }
    }

    @TableColumnBuilder<Track, KeyPathComparator<Track>>
    private var columnSlot5: some TableColumnContent<Track, KeyPathComparator<Track>> {
        if library.orderedVisibleColumns.indices.contains(5), library.orderedVisibleColumns[5] == .title {
            TableColumn("Title", value: \.title) { track in
                Text(track.title)
                    .fontWeight(track.id == player.currentTrack?.id ? .semibold : .regular)
                    .foregroundStyle(rowTextColor(track))
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .modifier(ReorderModifier(track: track, playlist: activePlaylist, library: library, isDragArmed: dragArmedIDs.contains(track.id)))
            }
            .width(min: 160, ideal: 260)
        } else if library.orderedVisibleColumns.indices.contains(5), library.orderedVisibleColumns[5] == .artist {
            TableColumn("Artist", value: \.artist) { track in
                Text(track.artist).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(5), library.orderedVisibleColumns[5] == .album {
            TableColumn("Album", value: \.album) { track in
                Text(track.album).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 100, ideal: 180)
        } else if library.orderedVisibleColumns.indices.contains(5), library.orderedVisibleColumns[5] == .genre {
            TableColumn("Genre", value: \.genre) { track in
                Text(track.genre).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 70, ideal: 100)
        } else if library.orderedVisibleColumns.indices.contains(5), library.orderedVisibleColumns[5] == .year {
            TableColumn("Year", value: \.yearSortKey) { track in
                Text(track.year.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(5), library.orderedVisibleColumns[5] == .trackNumber {
            TableColumn("Track #", value: \.trackNumberSortKey) { track in
                Text(track.trackNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(50)
        } else if library.orderedVisibleColumns.indices.contains(5), library.orderedVisibleColumns[5] == .discNumber {
            TableColumn("Disc #", value: \.discNumberSortKey) { track in
                Text(track.discNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(50)
        } else if library.orderedVisibleColumns.indices.contains(5), library.orderedVisibleColumns[5] == .bpm {
            TableColumn("BPM", value: \.bpmSortKey) { track in
                Text(track.bpm.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(5), library.orderedVisibleColumns[5] == .key {
            TableColumn("Key", value: \.keySortKey) { track in
                Text(track.key ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(5), library.orderedVisibleColumns[5] == .comments {
            TableColumn("Comments", value: \.commentsSortKey) { track in
                Text(track.comments ?? "").foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(5), library.orderedVisibleColumns[5] == .plays {
            TableColumn("Plays", value: \.playCount) { track in
                Text(track.playCount > 0 ? String(format: "%.1f", track.playCount) : "–").foregroundStyle(rowTextColor(track)).monospacedDigit()
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(5), library.orderedVisibleColumns[5] == .tags {
            TableColumn("Tags", value: \.tagsSortKey) { track in
                Text(track.tags.joined(separator: ", ")).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 80, ideal: 140)
        } else if library.orderedVisibleColumns.indices.contains(5), library.orderedVisibleColumns[5] == .time {
            TableColumn("Time", value: \.duration) { track in
                Text(track.durationString).foregroundStyle(rowTextColor(track)).monospacedDigit()
            }
            .width(50)
        } else if library.orderedVisibleColumns.indices.contains(5), library.orderedVisibleColumns[5] == .rating {
            TableColumn("Rating", value: \.rating) { track in
                RatingCellView(
                    rating: Binding(
                        get: { track.rating },
                        set: { library.setRating($0, for: track) }
                    ),
                    isSelected: selection.count == 1 && selection.contains(track.id)
                )
            }
            .width(min: 110, ideal: 130)
        }
    }

    @TableColumnBuilder<Track, KeyPathComparator<Track>>
    private var columnSlot6: some TableColumnContent<Track, KeyPathComparator<Track>> {
        if library.orderedVisibleColumns.indices.contains(6), library.orderedVisibleColumns[6] == .title {
            TableColumn("Title", value: \.title) { track in
                Text(track.title)
                    .fontWeight(track.id == player.currentTrack?.id ? .semibold : .regular)
                    .foregroundStyle(rowTextColor(track))
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .modifier(ReorderModifier(track: track, playlist: activePlaylist, library: library, isDragArmed: dragArmedIDs.contains(track.id)))
            }
            .width(min: 160, ideal: 260)
        } else if library.orderedVisibleColumns.indices.contains(6), library.orderedVisibleColumns[6] == .artist {
            TableColumn("Artist", value: \.artist) { track in
                Text(track.artist).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(6), library.orderedVisibleColumns[6] == .album {
            TableColumn("Album", value: \.album) { track in
                Text(track.album).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 100, ideal: 180)
        } else if library.orderedVisibleColumns.indices.contains(6), library.orderedVisibleColumns[6] == .genre {
            TableColumn("Genre", value: \.genre) { track in
                Text(track.genre).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 70, ideal: 100)
        } else if library.orderedVisibleColumns.indices.contains(6), library.orderedVisibleColumns[6] == .year {
            TableColumn("Year", value: \.yearSortKey) { track in
                Text(track.year.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(6), library.orderedVisibleColumns[6] == .trackNumber {
            TableColumn("Track #", value: \.trackNumberSortKey) { track in
                Text(track.trackNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(50)
        } else if library.orderedVisibleColumns.indices.contains(6), library.orderedVisibleColumns[6] == .discNumber {
            TableColumn("Disc #", value: \.discNumberSortKey) { track in
                Text(track.discNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(50)
        } else if library.orderedVisibleColumns.indices.contains(6), library.orderedVisibleColumns[6] == .bpm {
            TableColumn("BPM", value: \.bpmSortKey) { track in
                Text(track.bpm.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(6), library.orderedVisibleColumns[6] == .key {
            TableColumn("Key", value: \.keySortKey) { track in
                Text(track.key ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(6), library.orderedVisibleColumns[6] == .comments {
            TableColumn("Comments", value: \.commentsSortKey) { track in
                Text(track.comments ?? "").foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(6), library.orderedVisibleColumns[6] == .plays {
            TableColumn("Plays", value: \.playCount) { track in
                Text(track.playCount > 0 ? String(format: "%.1f", track.playCount) : "–").foregroundStyle(rowTextColor(track)).monospacedDigit()
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(6), library.orderedVisibleColumns[6] == .tags {
            TableColumn("Tags", value: \.tagsSortKey) { track in
                Text(track.tags.joined(separator: ", ")).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 80, ideal: 140)
        } else if library.orderedVisibleColumns.indices.contains(6), library.orderedVisibleColumns[6] == .time {
            TableColumn("Time", value: \.duration) { track in
                Text(track.durationString).foregroundStyle(rowTextColor(track)).monospacedDigit()
            }
            .width(50)
        } else if library.orderedVisibleColumns.indices.contains(6), library.orderedVisibleColumns[6] == .rating {
            TableColumn("Rating", value: \.rating) { track in
                RatingCellView(
                    rating: Binding(
                        get: { track.rating },
                        set: { library.setRating($0, for: track) }
                    ),
                    isSelected: selection.count == 1 && selection.contains(track.id)
                )
            }
            .width(min: 110, ideal: 130)
        }
    }

    @TableColumnBuilder<Track, KeyPathComparator<Track>>
    private var columnSlot7: some TableColumnContent<Track, KeyPathComparator<Track>> {
        if library.orderedVisibleColumns.indices.contains(7), library.orderedVisibleColumns[7] == .title {
            TableColumn("Title", value: \.title) { track in
                Text(track.title)
                    .fontWeight(track.id == player.currentTrack?.id ? .semibold : .regular)
                    .foregroundStyle(rowTextColor(track))
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .modifier(ReorderModifier(track: track, playlist: activePlaylist, library: library, isDragArmed: dragArmedIDs.contains(track.id)))
            }
            .width(min: 160, ideal: 260)
        } else if library.orderedVisibleColumns.indices.contains(7), library.orderedVisibleColumns[7] == .artist {
            TableColumn("Artist", value: \.artist) { track in
                Text(track.artist).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(7), library.orderedVisibleColumns[7] == .album {
            TableColumn("Album", value: \.album) { track in
                Text(track.album).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 100, ideal: 180)
        } else if library.orderedVisibleColumns.indices.contains(7), library.orderedVisibleColumns[7] == .genre {
            TableColumn("Genre", value: \.genre) { track in
                Text(track.genre).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 70, ideal: 100)
        } else if library.orderedVisibleColumns.indices.contains(7), library.orderedVisibleColumns[7] == .year {
            TableColumn("Year", value: \.yearSortKey) { track in
                Text(track.year.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(7), library.orderedVisibleColumns[7] == .trackNumber {
            TableColumn("Track #", value: \.trackNumberSortKey) { track in
                Text(track.trackNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(50)
        } else if library.orderedVisibleColumns.indices.contains(7), library.orderedVisibleColumns[7] == .discNumber {
            TableColumn("Disc #", value: \.discNumberSortKey) { track in
                Text(track.discNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(50)
        } else if library.orderedVisibleColumns.indices.contains(7), library.orderedVisibleColumns[7] == .bpm {
            TableColumn("BPM", value: \.bpmSortKey) { track in
                Text(track.bpm.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(7), library.orderedVisibleColumns[7] == .key {
            TableColumn("Key", value: \.keySortKey) { track in
                Text(track.key ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(7), library.orderedVisibleColumns[7] == .comments {
            TableColumn("Comments", value: \.commentsSortKey) { track in
                Text(track.comments ?? "").foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(7), library.orderedVisibleColumns[7] == .plays {
            TableColumn("Plays", value: \.playCount) { track in
                Text(track.playCount > 0 ? String(format: "%.1f", track.playCount) : "–").foregroundStyle(rowTextColor(track)).monospacedDigit()
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(7), library.orderedVisibleColumns[7] == .tags {
            TableColumn("Tags", value: \.tagsSortKey) { track in
                Text(track.tags.joined(separator: ", ")).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 80, ideal: 140)
        } else if library.orderedVisibleColumns.indices.contains(7), library.orderedVisibleColumns[7] == .time {
            TableColumn("Time", value: \.duration) { track in
                Text(track.durationString).foregroundStyle(rowTextColor(track)).monospacedDigit()
            }
            .width(50)
        } else if library.orderedVisibleColumns.indices.contains(7), library.orderedVisibleColumns[7] == .rating {
            TableColumn("Rating", value: \.rating) { track in
                RatingCellView(
                    rating: Binding(
                        get: { track.rating },
                        set: { library.setRating($0, for: track) }
                    ),
                    isSelected: selection.count == 1 && selection.contains(track.id)
                )
            }
            .width(min: 110, ideal: 130)
        }
    }

    @TableColumnBuilder<Track, KeyPathComparator<Track>>
    private var columnSlot8: some TableColumnContent<Track, KeyPathComparator<Track>> {
        if library.orderedVisibleColumns.indices.contains(8), library.orderedVisibleColumns[8] == .title {
            TableColumn("Title", value: \.title) { track in
                Text(track.title)
                    .fontWeight(track.id == player.currentTrack?.id ? .semibold : .regular)
                    .foregroundStyle(rowTextColor(track))
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .modifier(ReorderModifier(track: track, playlist: activePlaylist, library: library, isDragArmed: dragArmedIDs.contains(track.id)))
            }
            .width(min: 160, ideal: 260)
        } else if library.orderedVisibleColumns.indices.contains(8), library.orderedVisibleColumns[8] == .artist {
            TableColumn("Artist", value: \.artist) { track in
                Text(track.artist).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(8), library.orderedVisibleColumns[8] == .album {
            TableColumn("Album", value: \.album) { track in
                Text(track.album).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 100, ideal: 180)
        } else if library.orderedVisibleColumns.indices.contains(8), library.orderedVisibleColumns[8] == .genre {
            TableColumn("Genre", value: \.genre) { track in
                Text(track.genre).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 70, ideal: 100)
        } else if library.orderedVisibleColumns.indices.contains(8), library.orderedVisibleColumns[8] == .year {
            TableColumn("Year", value: \.yearSortKey) { track in
                Text(track.year.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(8), library.orderedVisibleColumns[8] == .trackNumber {
            TableColumn("Track #", value: \.trackNumberSortKey) { track in
                Text(track.trackNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(50)
        } else if library.orderedVisibleColumns.indices.contains(8), library.orderedVisibleColumns[8] == .discNumber {
            TableColumn("Disc #", value: \.discNumberSortKey) { track in
                Text(track.discNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(50)
        } else if library.orderedVisibleColumns.indices.contains(8), library.orderedVisibleColumns[8] == .bpm {
            TableColumn("BPM", value: \.bpmSortKey) { track in
                Text(track.bpm.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(8), library.orderedVisibleColumns[8] == .key {
            TableColumn("Key", value: \.keySortKey) { track in
                Text(track.key ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(8), library.orderedVisibleColumns[8] == .comments {
            TableColumn("Comments", value: \.commentsSortKey) { track in
                Text(track.comments ?? "").foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(8), library.orderedVisibleColumns[8] == .plays {
            TableColumn("Plays", value: \.playCount) { track in
                Text(track.playCount > 0 ? String(format: "%.1f", track.playCount) : "–").foregroundStyle(rowTextColor(track)).monospacedDigit()
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(8), library.orderedVisibleColumns[8] == .tags {
            TableColumn("Tags", value: \.tagsSortKey) { track in
                Text(track.tags.joined(separator: ", ")).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 80, ideal: 140)
        } else if library.orderedVisibleColumns.indices.contains(8), library.orderedVisibleColumns[8] == .time {
            TableColumn("Time", value: \.duration) { track in
                Text(track.durationString).foregroundStyle(rowTextColor(track)).monospacedDigit()
            }
            .width(50)
        } else if library.orderedVisibleColumns.indices.contains(8), library.orderedVisibleColumns[8] == .rating {
            TableColumn("Rating", value: \.rating) { track in
                RatingCellView(
                    rating: Binding(
                        get: { track.rating },
                        set: { library.setRating($0, for: track) }
                    ),
                    isSelected: selection.count == 1 && selection.contains(track.id)
                )
            }
            .width(min: 110, ideal: 130)
        }
    }

    @TableColumnBuilder<Track, KeyPathComparator<Track>>
    private var columnSlot9: some TableColumnContent<Track, KeyPathComparator<Track>> {
        if library.orderedVisibleColumns.indices.contains(9), library.orderedVisibleColumns[9] == .title {
            TableColumn("Title", value: \.title) { track in
                Text(track.title)
                    .fontWeight(track.id == player.currentTrack?.id ? .semibold : .regular)
                    .foregroundStyle(rowTextColor(track))
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .modifier(ReorderModifier(track: track, playlist: activePlaylist, library: library, isDragArmed: dragArmedIDs.contains(track.id)))
            }
            .width(min: 160, ideal: 260)
        } else if library.orderedVisibleColumns.indices.contains(9), library.orderedVisibleColumns[9] == .artist {
            TableColumn("Artist", value: \.artist) { track in
                Text(track.artist).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(9), library.orderedVisibleColumns[9] == .album {
            TableColumn("Album", value: \.album) { track in
                Text(track.album).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 100, ideal: 180)
        } else if library.orderedVisibleColumns.indices.contains(9), library.orderedVisibleColumns[9] == .genre {
            TableColumn("Genre", value: \.genre) { track in
                Text(track.genre).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 70, ideal: 100)
        } else if library.orderedVisibleColumns.indices.contains(9), library.orderedVisibleColumns[9] == .year {
            TableColumn("Year", value: \.yearSortKey) { track in
                Text(track.year.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(9), library.orderedVisibleColumns[9] == .trackNumber {
            TableColumn("Track #", value: \.trackNumberSortKey) { track in
                Text(track.trackNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(50)
        } else if library.orderedVisibleColumns.indices.contains(9), library.orderedVisibleColumns[9] == .discNumber {
            TableColumn("Disc #", value: \.discNumberSortKey) { track in
                Text(track.discNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(50)
        } else if library.orderedVisibleColumns.indices.contains(9), library.orderedVisibleColumns[9] == .bpm {
            TableColumn("BPM", value: \.bpmSortKey) { track in
                Text(track.bpm.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(9), library.orderedVisibleColumns[9] == .key {
            TableColumn("Key", value: \.keySortKey) { track in
                Text(track.key ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(9), library.orderedVisibleColumns[9] == .comments {
            TableColumn("Comments", value: \.commentsSortKey) { track in
                Text(track.comments ?? "").foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(9), library.orderedVisibleColumns[9] == .plays {
            TableColumn("Plays", value: \.playCount) { track in
                Text(track.playCount > 0 ? String(format: "%.1f", track.playCount) : "–").foregroundStyle(rowTextColor(track)).monospacedDigit()
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(9), library.orderedVisibleColumns[9] == .tags {
            TableColumn("Tags", value: \.tagsSortKey) { track in
                Text(track.tags.joined(separator: ", ")).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 80, ideal: 140)
        } else if library.orderedVisibleColumns.indices.contains(9), library.orderedVisibleColumns[9] == .time {
            TableColumn("Time", value: \.duration) { track in
                Text(track.durationString).foregroundStyle(rowTextColor(track)).monospacedDigit()
            }
            .width(50)
        } else if library.orderedVisibleColumns.indices.contains(9), library.orderedVisibleColumns[9] == .rating {
            TableColumn("Rating", value: \.rating) { track in
                RatingCellView(
                    rating: Binding(
                        get: { track.rating },
                        set: { library.setRating($0, for: track) }
                    ),
                    isSelected: selection.count == 1 && selection.contains(track.id)
                )
            }
            .width(min: 110, ideal: 130)
        }
    }

    @TableColumnBuilder<Track, KeyPathComparator<Track>>
    private var columnSlot10: some TableColumnContent<Track, KeyPathComparator<Track>> {
        if library.orderedVisibleColumns.indices.contains(10), library.orderedVisibleColumns[10] == .title {
            TableColumn("Title", value: \.title) { track in
                Text(track.title)
                    .fontWeight(track.id == player.currentTrack?.id ? .semibold : .regular)
                    .foregroundStyle(rowTextColor(track))
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .modifier(ReorderModifier(track: track, playlist: activePlaylist, library: library, isDragArmed: dragArmedIDs.contains(track.id)))
            }
            .width(min: 160, ideal: 260)
        } else if library.orderedVisibleColumns.indices.contains(10), library.orderedVisibleColumns[10] == .artist {
            TableColumn("Artist", value: \.artist) { track in
                Text(track.artist).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(10), library.orderedVisibleColumns[10] == .album {
            TableColumn("Album", value: \.album) { track in
                Text(track.album).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 100, ideal: 180)
        } else if library.orderedVisibleColumns.indices.contains(10), library.orderedVisibleColumns[10] == .genre {
            TableColumn("Genre", value: \.genre) { track in
                Text(track.genre).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 70, ideal: 100)
        } else if library.orderedVisibleColumns.indices.contains(10), library.orderedVisibleColumns[10] == .year {
            TableColumn("Year", value: \.yearSortKey) { track in
                Text(track.year.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(10), library.orderedVisibleColumns[10] == .trackNumber {
            TableColumn("Track #", value: \.trackNumberSortKey) { track in
                Text(track.trackNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(50)
        } else if library.orderedVisibleColumns.indices.contains(10), library.orderedVisibleColumns[10] == .discNumber {
            TableColumn("Disc #", value: \.discNumberSortKey) { track in
                Text(track.discNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(50)
        } else if library.orderedVisibleColumns.indices.contains(10), library.orderedVisibleColumns[10] == .bpm {
            TableColumn("BPM", value: \.bpmSortKey) { track in
                Text(track.bpm.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(10), library.orderedVisibleColumns[10] == .key {
            TableColumn("Key", value: \.keySortKey) { track in
                Text(track.key ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(10), library.orderedVisibleColumns[10] == .comments {
            TableColumn("Comments", value: \.commentsSortKey) { track in
                Text(track.comments ?? "").foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(10), library.orderedVisibleColumns[10] == .plays {
            TableColumn("Plays", value: \.playCount) { track in
                Text(track.playCount > 0 ? String(format: "%.1f", track.playCount) : "–").foregroundStyle(rowTextColor(track)).monospacedDigit()
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(10), library.orderedVisibleColumns[10] == .tags {
            TableColumn("Tags", value: \.tagsSortKey) { track in
                Text(track.tags.joined(separator: ", ")).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 80, ideal: 140)
        } else if library.orderedVisibleColumns.indices.contains(10), library.orderedVisibleColumns[10] == .time {
            TableColumn("Time", value: \.duration) { track in
                Text(track.durationString).foregroundStyle(rowTextColor(track)).monospacedDigit()
            }
            .width(50)
        } else if library.orderedVisibleColumns.indices.contains(10), library.orderedVisibleColumns[10] == .rating {
            TableColumn("Rating", value: \.rating) { track in
                RatingCellView(
                    rating: Binding(
                        get: { track.rating },
                        set: { library.setRating($0, for: track) }
                    ),
                    isSelected: selection.count == 1 && selection.contains(track.id)
                )
            }
            .width(min: 110, ideal: 130)
        }
    }

    @TableColumnBuilder<Track, KeyPathComparator<Track>>
    private var columnSlot11: some TableColumnContent<Track, KeyPathComparator<Track>> {
        if library.orderedVisibleColumns.indices.contains(11), library.orderedVisibleColumns[11] == .title {
            TableColumn("Title", value: \.title) { track in
                Text(track.title)
                    .fontWeight(track.id == player.currentTrack?.id ? .semibold : .regular)
                    .foregroundStyle(rowTextColor(track))
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .modifier(ReorderModifier(track: track, playlist: activePlaylist, library: library, isDragArmed: dragArmedIDs.contains(track.id)))
            }
            .width(min: 160, ideal: 260)
        } else if library.orderedVisibleColumns.indices.contains(11), library.orderedVisibleColumns[11] == .artist {
            TableColumn("Artist", value: \.artist) { track in
                Text(track.artist).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(11), library.orderedVisibleColumns[11] == .album {
            TableColumn("Album", value: \.album) { track in
                Text(track.album).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 100, ideal: 180)
        } else if library.orderedVisibleColumns.indices.contains(11), library.orderedVisibleColumns[11] == .genre {
            TableColumn("Genre", value: \.genre) { track in
                Text(track.genre).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 70, ideal: 100)
        } else if library.orderedVisibleColumns.indices.contains(11), library.orderedVisibleColumns[11] == .year {
            TableColumn("Year", value: \.yearSortKey) { track in
                Text(track.year.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(11), library.orderedVisibleColumns[11] == .trackNumber {
            TableColumn("Track #", value: \.trackNumberSortKey) { track in
                Text(track.trackNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(50)
        } else if library.orderedVisibleColumns.indices.contains(11), library.orderedVisibleColumns[11] == .discNumber {
            TableColumn("Disc #", value: \.discNumberSortKey) { track in
                Text(track.discNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(50)
        } else if library.orderedVisibleColumns.indices.contains(11), library.orderedVisibleColumns[11] == .bpm {
            TableColumn("BPM", value: \.bpmSortKey) { track in
                Text(track.bpm.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(11), library.orderedVisibleColumns[11] == .key {
            TableColumn("Key", value: \.keySortKey) { track in
                Text(track.key ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(11), library.orderedVisibleColumns[11] == .comments {
            TableColumn("Comments", value: \.commentsSortKey) { track in
                Text(track.comments ?? "").foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(11), library.orderedVisibleColumns[11] == .plays {
            TableColumn("Plays", value: \.playCount) { track in
                Text(track.playCount > 0 ? String(format: "%.1f", track.playCount) : "–").foregroundStyle(rowTextColor(track)).monospacedDigit()
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(11), library.orderedVisibleColumns[11] == .tags {
            TableColumn("Tags", value: \.tagsSortKey) { track in
                Text(track.tags.joined(separator: ", ")).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 80, ideal: 140)
        } else if library.orderedVisibleColumns.indices.contains(11), library.orderedVisibleColumns[11] == .time {
            TableColumn("Time", value: \.duration) { track in
                Text(track.durationString).foregroundStyle(rowTextColor(track)).monospacedDigit()
            }
            .width(50)
        } else if library.orderedVisibleColumns.indices.contains(11), library.orderedVisibleColumns[11] == .rating {
            TableColumn("Rating", value: \.rating) { track in
                RatingCellView(
                    rating: Binding(
                        get: { track.rating },
                        set: { library.setRating($0, for: track) }
                    ),
                    isSelected: selection.count == 1 && selection.contains(track.id)
                )
            }
            .width(min: 110, ideal: 130)
        }
    }

    @TableColumnBuilder<Track, KeyPathComparator<Track>>
    private var columnSlot12: some TableColumnContent<Track, KeyPathComparator<Track>> {
        if library.orderedVisibleColumns.indices.contains(12), library.orderedVisibleColumns[12] == .title {
            TableColumn("Title", value: \.title) { track in
                Text(track.title)
                    .fontWeight(track.id == player.currentTrack?.id ? .semibold : .regular)
                    .foregroundStyle(rowTextColor(track))
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .modifier(ReorderModifier(track: track, playlist: activePlaylist, library: library, isDragArmed: dragArmedIDs.contains(track.id)))
            }
            .width(min: 160, ideal: 260)
        } else if library.orderedVisibleColumns.indices.contains(12), library.orderedVisibleColumns[12] == .artist {
            TableColumn("Artist", value: \.artist) { track in
                Text(track.artist).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(12), library.orderedVisibleColumns[12] == .album {
            TableColumn("Album", value: \.album) { track in
                Text(track.album).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 100, ideal: 180)
        } else if library.orderedVisibleColumns.indices.contains(12), library.orderedVisibleColumns[12] == .genre {
            TableColumn("Genre", value: \.genre) { track in
                Text(track.genre).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 70, ideal: 100)
        } else if library.orderedVisibleColumns.indices.contains(12), library.orderedVisibleColumns[12] == .year {
            TableColumn("Year", value: \.yearSortKey) { track in
                Text(track.year.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(12), library.orderedVisibleColumns[12] == .trackNumber {
            TableColumn("Track #", value: \.trackNumberSortKey) { track in
                Text(track.trackNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(50)
        } else if library.orderedVisibleColumns.indices.contains(12), library.orderedVisibleColumns[12] == .discNumber {
            TableColumn("Disc #", value: \.discNumberSortKey) { track in
                Text(track.discNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(50)
        } else if library.orderedVisibleColumns.indices.contains(12), library.orderedVisibleColumns[12] == .bpm {
            TableColumn("BPM", value: \.bpmSortKey) { track in
                Text(track.bpm.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(12), library.orderedVisibleColumns[12] == .key {
            TableColumn("Key", value: \.keySortKey) { track in
                Text(track.key ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(12), library.orderedVisibleColumns[12] == .comments {
            TableColumn("Comments", value: \.commentsSortKey) { track in
                Text(track.comments ?? "").foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(12), library.orderedVisibleColumns[12] == .plays {
            TableColumn("Plays", value: \.playCount) { track in
                Text(track.playCount > 0 ? String(format: "%.1f", track.playCount) : "–").foregroundStyle(rowTextColor(track)).monospacedDigit()
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(12), library.orderedVisibleColumns[12] == .tags {
            TableColumn("Tags", value: \.tagsSortKey) { track in
                Text(track.tags.joined(separator: ", ")).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 80, ideal: 140)
        } else if library.orderedVisibleColumns.indices.contains(12), library.orderedVisibleColumns[12] == .time {
            TableColumn("Time", value: \.duration) { track in
                Text(track.durationString).foregroundStyle(rowTextColor(track)).monospacedDigit()
            }
            .width(50)
        } else if library.orderedVisibleColumns.indices.contains(12), library.orderedVisibleColumns[12] == .rating {
            TableColumn("Rating", value: \.rating) { track in
                RatingCellView(
                    rating: Binding(
                        get: { track.rating },
                        set: { library.setRating($0, for: track) }
                    ),
                    isSelected: selection.count == 1 && selection.contains(track.id)
                )
            }
            .width(min: 110, ideal: 130)
        }
    }

    @TableColumnBuilder<Track, KeyPathComparator<Track>>
    private var columnSlot13: some TableColumnContent<Track, KeyPathComparator<Track>> {
        if library.orderedVisibleColumns.indices.contains(13), library.orderedVisibleColumns[13] == .title {
            TableColumn("Title", value: \.title) { track in
                Text(track.title)
                    .fontWeight(track.id == player.currentTrack?.id ? .semibold : .regular)
                    .foregroundStyle(rowTextColor(track))
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .modifier(ReorderModifier(track: track, playlist: activePlaylist, library: library, isDragArmed: dragArmedIDs.contains(track.id)))
            }
            .width(min: 160, ideal: 260)
        } else if library.orderedVisibleColumns.indices.contains(13), library.orderedVisibleColumns[13] == .artist {
            TableColumn("Artist", value: \.artist) { track in
                Text(track.artist).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(13), library.orderedVisibleColumns[13] == .album {
            TableColumn("Album", value: \.album) { track in
                Text(track.album).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 100, ideal: 180)
        } else if library.orderedVisibleColumns.indices.contains(13), library.orderedVisibleColumns[13] == .genre {
            TableColumn("Genre", value: \.genre) { track in
                Text(track.genre).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 70, ideal: 100)
        } else if library.orderedVisibleColumns.indices.contains(13), library.orderedVisibleColumns[13] == .year {
            TableColumn("Year", value: \.yearSortKey) { track in
                Text(track.year.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(13), library.orderedVisibleColumns[13] == .trackNumber {
            TableColumn("Track #", value: \.trackNumberSortKey) { track in
                Text(track.trackNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(50)
        } else if library.orderedVisibleColumns.indices.contains(13), library.orderedVisibleColumns[13] == .discNumber {
            TableColumn("Disc #", value: \.discNumberSortKey) { track in
                Text(track.discNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(50)
        } else if library.orderedVisibleColumns.indices.contains(13), library.orderedVisibleColumns[13] == .bpm {
            TableColumn("BPM", value: \.bpmSortKey) { track in
                Text(track.bpm.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(13), library.orderedVisibleColumns[13] == .key {
            TableColumn("Key", value: \.keySortKey) { track in
                Text(track.key ?? "").foregroundStyle(rowTextColor(track))
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(13), library.orderedVisibleColumns[13] == .comments {
            TableColumn("Comments", value: \.commentsSortKey) { track in
                Text(track.comments ?? "").foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(13), library.orderedVisibleColumns[13] == .plays {
            TableColumn("Plays", value: \.playCount) { track in
                Text(track.playCount > 0 ? String(format: "%.1f", track.playCount) : "–").foregroundStyle(rowTextColor(track)).monospacedDigit()
            }
            .width(46)
        } else if library.orderedVisibleColumns.indices.contains(13), library.orderedVisibleColumns[13] == .tags {
            TableColumn("Tags", value: \.tagsSortKey) { track in
                Text(track.tags.joined(separator: ", ")).foregroundStyle(rowTextColor(track)).lineLimit(1)
            }
            .width(min: 80, ideal: 140)
        } else if library.orderedVisibleColumns.indices.contains(13), library.orderedVisibleColumns[13] == .time {
            TableColumn("Time", value: \.duration) { track in
                Text(track.durationString).foregroundStyle(rowTextColor(track)).monospacedDigit()
            }
            .width(50)
        } else if library.orderedVisibleColumns.indices.contains(13), library.orderedVisibleColumns[13] == .rating {
            TableColumn("Rating", value: \.rating) { track in
                RatingCellView(
                    rating: Binding(
                        get: { track.rating },
                        set: { library.setRating($0, for: track) }
                    ),
                    isSelected: selection.count == 1 && selection.contains(track.id)
                )
            }
            .width(min: 110, ideal: 130)
        }
    }


    private var scanningPlaceholder: some View {
        VStack(spacing: 12) {
            ProgressView()
            if let progress = library.scanProgress, progress.total > 0 {
                Text("Reading metadata… \(progress.completed) / \(progress.total)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Scanning folder…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyLibraryPlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note.house")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No music yet")
                .font(.title3)
            Text("Choose a folder to build your library.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Adds drag support to a row's Title cell so tracks can be dragged onto a
/// playlist in the sidebar (or reordered within a regular playlist).
///
/// Only installs the drag source once the row has been selected for a
/// beat: SwiftUI installs `.draggable`'s drag-recognition on the very
/// first mouse-down, so arming it the instant a row is selected means the
/// *second* click of a double-click can land on a freshly drag-enabled
/// view and get eaten by drag-gesture recognition instead of registering
/// as the double-click — `isDragArmed` only goes true ~400ms after
/// selection settles (see `dragArmedIDs` in TrackListView), safely past
/// the double-click window, so a fast double-click never sees drag
/// installed while a deliberate select-then-drag still works.
private struct ReorderModifier: ViewModifier {
    let track: Track
    let playlist: Playlist?
    let library: LibraryModel
    let isDragArmed: Bool

    func body(content: Content) -> some View {
        // The drag *source* only goes on drag-armed rows (see doc comment
        // above) — but the drop *target*, for reordering within a regular
        // playlist, still needs to stay on every row regardless of arming,
        // since you drop onto whichever row you're reordering relative to.
        let dragSource: AnyView = isDragArmed ? AnyView(content.draggable(track.path)) : AnyView(content)

        if let playlist, !playlist.isSmart {
            return AnyView(
                dragSource
                    .dropDestination(for: String.self) { items, _ in
                        guard let droppedPath = items.first,
                              let fromIndex = playlist.trackPaths.firstIndex(of: droppedPath),
                              let toIndex = playlist.trackPaths.firstIndex(of: track.path),
                              fromIndex != toIndex else { return false }
                        let destination = fromIndex < toIndex ? toIndex + 1 : toIndex
                        library.moveTracks(inPlaylistID: playlist.id, from: IndexSet(integer: fromIndex), to: destination)
                        return true
                    }
            )
        } else {
            return AnyView(dragSource)
        }
    }
}
