import SwiftUI
import AppKit
import Combine
import MusicPlayerKit
import UniformTypeIdentifiers

/// `Equatable`, with `.equatable()` applied at the call site in
/// `ContentView` — the real fix for the recurring "All Tracks" slowdown
/// (and very likely the intermittent double-click-doesn't-register issue
/// too). Diagnostic logging proved the previous two fixes wrong about the
/// actual cause: `ContentView.body` itself was re-evaluating on the same
/// ~0.22–0.25s cadence as `NowPlayingBar`'s legitimate `currentTime`
/// updates, even though `ContentView` never reads `player` directly —
/// `NowPlayingBar` and `TrackListView` are siblings inside the same
/// `VStack` in `ContentView`'s `detail` closure, and SwiftUI doesn't
/// guarantee it can skip reconstructing an unchanged sibling's `body` just
/// because *that* sibling's own inputs didn't change; by default it's
/// only willing to skip a subtree if the view itself says it's safe to,
/// via `Equatable`. That meant this view's full library re-filter/re-sort
/// and `Table` rebuild were happening every single time `NowPlayingBar`
/// legitimately needed to update its scrubber — continuously, the entire
/// time anything played — a plausible source of both the rendering
/// backlog behind "All Tracks" and of AppKit occasionally dropping a
/// click/double-click that landed mid-rebuild. `player` is always the
/// same instance for the app's lifetime, so comparing by reference makes
/// this always report "unchanged" to a parent re-render, while this
/// view's own `@State`/`@StateObject`/`@EnvironmentObject` reads still
/// drive updates normally — `.equatable()` only short-circuits
/// reconstruction triggered *from the parent*, not this view's own
/// reactivity.
struct TrackListView: View, Equatable {
    // `nonisolated`: comparing two references with `===` never touches
    // either `PlayerController`'s actor-isolated members, so this is safe
    // to satisfy `Equatable`'s nonisolated requirement directly.
    nonisolated static func == (lhs: TrackListView, rhs: TrackListView) -> Bool {
        lhs.player === rhs.player
    }

    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var coordinator: PlaybackCoordinator
    /// Deliberately *not* `@EnvironmentObject` — see `nowPlaying` just
    /// below for why.
    let player: PlayerController

    /// Mirrors `player.currentTrack?.id`/`player.isPlaying`, but only ever
    /// updates when one of *those* actually changes — not on every
    /// `currentTime` tick. `player` publishes `currentTime` on a ~0.25s
    /// timer while anything plays; holding `player` as `@EnvironmentObject`
    /// (as this used to) makes SwiftUI treat this whole view as a
    /// subscriber to *all* of its published changes, so every tick was
    /// re-running this view's `body` — including a full re-filter/re-sort
    /// of the entire library and a full `Table` rebuild — 4x/second,
    /// continuously, the whole time anything was playing.
    ///
    /// A `@StateObject`, not a `.onReceive` built from an inline Combine
    /// pipeline — the pipeline (`.map.combineLatest(...)`) was being
    /// reconstructed as a *new* publisher instance on every `body`
    /// evaluation, and `.onReceive` re-subscribing to a fresh publisher
    /// each time is exactly the kind of thing that can leave stale
    /// subscriptions live instead of cleanly replacing them — a plausible
    /// explanation for why the slowdown came back intermittently rather
    /// than staying fixed. `NowPlayingObserver` sets up its one Combine
    /// subscription exactly once, in `init`, and `@StateObject` guarantees
    /// this view keeps the same instance across every re-render.
    @StateObject private var nowPlaying: NowPlayingObserver

    init(player: PlayerController) {
        self.player = player
        _nowPlaying = StateObject(wrappedValue: NowPlayingObserver(player: player))
    }

    @State private var selection: Set<Track.ID> = []
    // Grouped by album (with each album's own tracks in track-number
    // order — see `sortedTracks`), not flat alphabetical by title — reads
    // far better as a default for browsing a whole library. Still just a
    // default: clicking "Title" (or any other header) overrides it exactly
    // like it always could.
    @State private var sortOrder: [KeyPathComparator<Track>] = Self.albumColumnOrder
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

    /// What clicking the "Album" header alone sets `sortOrder` to —
    /// compared against below so a plain album sort can get a meaningful
    /// within-album order without touching any other sort mode.
    private static let albumColumnOrder: [KeyPathComparator<Track>] = [
        KeyPathComparator(\.album, order: .forward)
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
        if isAllTracksView, albumsSortedByRating, sortOrder == Self.albumGroupingDefaultOrder {
            let rank = albumRatingRank
            return base.sorted { lhs, rhs in
                (rank[lhs.album] ?? Int.max) < (rank[rhs.album] ?? Int.max)
            }
        }

        // A plain click on "Album" only has one sort key, so ties (every
        // track in the same album) fall back to whatever order the
        // library happened to already be in — not necessarily the album's
        // own track order. This second, stable pass leaves the album-to-
        // album ordering `base` already established alone and only
        // refines *within* each album by disc/track number.
        if sortOrder == Self.albumColumnOrder {
            return base.sorted { lhs, rhs in
                guard lhs.album == rhs.album else { return false }
                if lhs.discNumberSortKey != rhs.discNumberSortKey {
                    return lhs.discNumberSortKey < rhs.discNumberSortKey
                }
                return lhs.trackNumberSortKey < rhs.trackNumberSortKey
            }
        }

        return base
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
        .onAppear {
            // Same default `.onChange(of: library.selectedAlbums)` below
            // applies on a click — but `.onChange` only fires on a
            // *transition*, so a launch that restores an already-selected
            // album from last session (see `LibraryModel`'s persisted
            // `selectedAlbums`) wouldn't otherwise get disc/track order
            // until you re-clicked it. A manual header-click sort still
            // wins from here on, same as after any other album click,
            // since nothing re-fires this once the view has appeared.
            guard !library.selectedAlbums.isEmpty else { return }
            sortOrder = Self.albumGroupingDefaultOrder
        }
        .onChange(of: library.selectedAlbums) { _, newValue in
            // Browsing an album reads far better in disc/track order than
            // alphabetically; you can still click a header to override it.
            // Leaving the album goes back to All Tracks' own default
            // (grouped by album, track-number order within each), not
            // flat alphabetical-by-title.
            sortOrder = newValue.isEmpty ? Self.albumColumnOrder : Self.albumGroupingDefaultOrder
        }
        .onChange(of: albumsSortedByRating) { _, newValue in
            // Same idea as browsing a single album above: switching on
            // "sort albums by rating" reads better with each album's
            // tracks in disc/track order — still just a default, a header
            // click after this still wins (see sortedTracks).
            guard isAllTracksView else { return }
            sortOrder = newValue ? Self.albumGroupingDefaultOrder : Self.albumColumnOrder
        }
    }

    private var table: some View {
        Table(sortedTracks, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("") { track in
                if track.id == nowPlaying.trackID {
                    Image(systemName: nowPlaying.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
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
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        // Selection highlight in the app's own green rather than whatever
        // the system accent color happens to be set to.
        .tint(Color.appAccent)
        // Taller rows, to match the wider column padding — the default
        // was cramped.
        .environment(\.defaultMinListRowHeight, 28)
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
                    } else {
                        // Lets a placeholder — manually entered, or synced
                        // in from another machine's catalog (see
                        // iCloudSyncService.syncedPlaceholderPathPrefix) —
                        // be promoted to a real track the moment you
                        // actually have the file, without waiting for a
                        // folder rescan/"Import Known Tracks" to discover
                        // it on its own.
                        Button("Attach File…") {
                            presentAttachFilePanel(for: track)
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

                // Columns is table-wide configuration, not something
                // about a single selected track — showing it only for a
                // multi-row selection (which already reads as "acting on
                if selectedTracks.count == 1, let track = selectedTracks.first, !track.isPlaceholder {
                    Divider()
                    Button("Learn Song…") {
                        library.learningTrack = track
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
            // Cmd+L is dual-purpose: with a track highlighted, it opens
            // Learn Song for it (the more common thing to want mid-browse);
            // with nothing selected, it falls back to its original job of
            // jumping the list to whatever's currently playing.
            if selection.count == 1, let id = selection.first,
               let track = sortedTracks.first(where: { $0.id == id }), !track.isPlaceholder {
                library.learningTrack = track
                return
            }
            guard let currentID = player.currentTrack?.id,
                  let index = sortedTracks.firstIndex(where: { $0.id == currentID }) else { return }
            selection = [currentID]
            locateRowIndex = index
            locateTrigger += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestGoToPlayingTrack)) { _ in
            guard let currentTrack = player.currentTrack else { return }
            // Always lands on the playing track's own album view — even
            // if it's already visible right where you are (e.g. browsing
            // All Tracks) — Cmd+P means "take me to this song's album,"
            // not just "scroll to wherever it already is" (that's Cmd+L).
            // `sortedTracks` is a plain computed property (not cached), so
            // re-reading it right after changing the filters already
            // reflects them — no need to wait for a view update.
            library.resetAllFilters()
            library.setAlbums([currentTrack.album])
            guard let index = sortedTracks.firstIndex(where: { $0.id == currentTrack.id }) else { return }
            selection = [currentTrack.id]
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
        return track.id == nowPlaying.trackID ? Color.appAccent : Color.primary
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

    /// `NSOpenPanel` directly rather than `.fileImporter` — see the
    /// CLAUDE.md lesson about `.fileImporter` unreliably failing to
    /// deliver a picked file (same pattern as
    /// `LearnSongView.presentImporter`/`ContentView.presentImportKnownTracksPanel`).
    private func presentAttachFilePanel(for placeholder: Track) {
        let panel = NSOpenPanel()
        panel.title = "Attach File"
        panel.message = "Choose the audio file for “\(placeholder.title)”."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.audio]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await library.attachFile(to: placeholder, fileURL: url) }
        }
    }

    @TableColumnBuilder<Track, KeyPathComparator<Track>>
    private var columnSlot0: some TableColumnContent<Track, KeyPathComparator<Track>> {
        if library.orderedVisibleColumns.indices.contains(0), library.orderedVisibleColumns[0] == .title {
            TableColumn("Title", value: \.title) { track in
                Text(track.title)
                    .fontWeight(track.id == nowPlaying.trackID ? .semibold : .regular)
                    .foregroundStyle(rowTextColor(track))
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .modifier(ReorderModifier(track: track, playlist: activePlaylist, library: library, isDragArmed: dragArmedIDs.contains(track.id)))
                .padding(.horizontal, 10)
            }
            .width(min: 160, ideal: 260)
        } else if library.orderedVisibleColumns.indices.contains(0), library.orderedVisibleColumns[0] == .artist {
            TableColumn("Artist", value: \.artist) { track in
                Text(track.artist).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(0), library.orderedVisibleColumns[0] == .album {
            TableColumn("Album", value: \.album) { track in
                Text(track.album).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 100, ideal: 180)
        } else if library.orderedVisibleColumns.indices.contains(0), library.orderedVisibleColumns[0] == .genre {
            TableColumn("Genre", value: \.genre) { track in
                Text(track.genre).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 70, ideal: 100)
        } else if library.orderedVisibleColumns.indices.contains(0), library.orderedVisibleColumns[0] == .year {
            TableColumn("Year", value: \.yearSortKey) { track in
                Text(track.year.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 50, ideal: 60, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(0), library.orderedVisibleColumns[0] == .trackNumber {
            TableColumn("Track #", value: \.trackNumberSortKey) { track in
                Text(track.trackNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 50, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(0), library.orderedVisibleColumns[0] == .discNumber {
            TableColumn("Disc #", value: \.discNumberSortKey) { track in
                Text(track.discNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 50, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(0), library.orderedVisibleColumns[0] == .bpm {
            TableColumn("BPM", value: \.bpmSortKey) { track in
                Text(track.bpm.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 46, max: 80)
        } else if library.orderedVisibleColumns.indices.contains(0), library.orderedVisibleColumns[0] == .key {
            TableColumn("Key", value: \.keySortKey) { track in
                Text(track.key ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 46, max: 80)
        } else if library.orderedVisibleColumns.indices.contains(0), library.orderedVisibleColumns[0] == .comments {
            TableColumn("Comments", value: \.commentsSortKey) { track in
                Text(track.comments ?? "").foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(0), library.orderedVisibleColumns[0] == .plays {
            TableColumn("Plays", value: \.playCount) { track in
                Text(track.playCount > 0 ? String(format: "%.1f", track.playCount) : "–").foregroundStyle(rowTextColor(track)).monospacedDigit()
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 46, max: 80)
        } else if library.orderedVisibleColumns.indices.contains(0), library.orderedVisibleColumns[0] == .tags {
            TableColumn("Tags", value: \.tagsSortKey) { track in
                Text(track.tags.joined(separator: ", ")).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 80, ideal: 140)
        } else if library.orderedVisibleColumns.indices.contains(0), library.orderedVisibleColumns[0] == .time {
            TableColumn("Time", value: \.duration) { track in
                Text(track.durationString).foregroundStyle(rowTextColor(track)).monospacedDigit()
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 50, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(0), library.orderedVisibleColumns[0] == .rating {
            TableColumn("Resonance", value: \.rating) { track in
                RatingCellView(
                    rating: Binding(
                        get: { track.rating },
                        set: { library.setRating($0, for: track) }
                    ),
                    isSelected: selection.count == 1 && selection.contains(track.id),
                    showSlider: selection.count == 1 && dragArmedIDs.contains(track.id)
                )
                .padding(.horizontal, 10)
            }
            .width(min: 110, ideal: 130)
        }
    }

    @TableColumnBuilder<Track, KeyPathComparator<Track>>
    private var columnSlot1: some TableColumnContent<Track, KeyPathComparator<Track>> {
        if library.orderedVisibleColumns.indices.contains(1), library.orderedVisibleColumns[1] == .title {
            TableColumn("Title", value: \.title) { track in
                Text(track.title)
                    .fontWeight(track.id == nowPlaying.trackID ? .semibold : .regular)
                    .foregroundStyle(rowTextColor(track))
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .modifier(ReorderModifier(track: track, playlist: activePlaylist, library: library, isDragArmed: dragArmedIDs.contains(track.id)))
                .padding(.horizontal, 10)
            }
            .width(min: 160, ideal: 260)
        } else if library.orderedVisibleColumns.indices.contains(1), library.orderedVisibleColumns[1] == .artist {
            TableColumn("Artist", value: \.artist) { track in
                Text(track.artist).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(1), library.orderedVisibleColumns[1] == .album {
            TableColumn("Album", value: \.album) { track in
                Text(track.album).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 100, ideal: 180)
        } else if library.orderedVisibleColumns.indices.contains(1), library.orderedVisibleColumns[1] == .genre {
            TableColumn("Genre", value: \.genre) { track in
                Text(track.genre).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 70, ideal: 100)
        } else if library.orderedVisibleColumns.indices.contains(1), library.orderedVisibleColumns[1] == .year {
            TableColumn("Year", value: \.yearSortKey) { track in
                Text(track.year.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 50, ideal: 60, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(1), library.orderedVisibleColumns[1] == .trackNumber {
            TableColumn("Track #", value: \.trackNumberSortKey) { track in
                Text(track.trackNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 50, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(1), library.orderedVisibleColumns[1] == .discNumber {
            TableColumn("Disc #", value: \.discNumberSortKey) { track in
                Text(track.discNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 50, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(1), library.orderedVisibleColumns[1] == .bpm {
            TableColumn("BPM", value: \.bpmSortKey) { track in
                Text(track.bpm.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 46, max: 80)
        } else if library.orderedVisibleColumns.indices.contains(1), library.orderedVisibleColumns[1] == .key {
            TableColumn("Key", value: \.keySortKey) { track in
                Text(track.key ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 46, max: 80)
        } else if library.orderedVisibleColumns.indices.contains(1), library.orderedVisibleColumns[1] == .comments {
            TableColumn("Comments", value: \.commentsSortKey) { track in
                Text(track.comments ?? "").foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(1), library.orderedVisibleColumns[1] == .plays {
            TableColumn("Plays", value: \.playCount) { track in
                Text(track.playCount > 0 ? String(format: "%.1f", track.playCount) : "–").foregroundStyle(rowTextColor(track)).monospacedDigit()
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 46, max: 80)
        } else if library.orderedVisibleColumns.indices.contains(1), library.orderedVisibleColumns[1] == .tags {
            TableColumn("Tags", value: \.tagsSortKey) { track in
                Text(track.tags.joined(separator: ", ")).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 80, ideal: 140)
        } else if library.orderedVisibleColumns.indices.contains(1), library.orderedVisibleColumns[1] == .time {
            TableColumn("Time", value: \.duration) { track in
                Text(track.durationString).foregroundStyle(rowTextColor(track)).monospacedDigit()
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 50, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(1), library.orderedVisibleColumns[1] == .rating {
            TableColumn("Resonance", value: \.rating) { track in
                RatingCellView(
                    rating: Binding(
                        get: { track.rating },
                        set: { library.setRating($0, for: track) }
                    ),
                    isSelected: selection.count == 1 && selection.contains(track.id),
                    showSlider: selection.count == 1 && dragArmedIDs.contains(track.id)
                )
                .padding(.horizontal, 10)
            }
            .width(min: 110, ideal: 130)
        }
    }

    @TableColumnBuilder<Track, KeyPathComparator<Track>>
    private var columnSlot2: some TableColumnContent<Track, KeyPathComparator<Track>> {
        if library.orderedVisibleColumns.indices.contains(2), library.orderedVisibleColumns[2] == .title {
            TableColumn("Title", value: \.title) { track in
                Text(track.title)
                    .fontWeight(track.id == nowPlaying.trackID ? .semibold : .regular)
                    .foregroundStyle(rowTextColor(track))
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .modifier(ReorderModifier(track: track, playlist: activePlaylist, library: library, isDragArmed: dragArmedIDs.contains(track.id)))
                .padding(.horizontal, 10)
            }
            .width(min: 160, ideal: 260)
        } else if library.orderedVisibleColumns.indices.contains(2), library.orderedVisibleColumns[2] == .artist {
            TableColumn("Artist", value: \.artist) { track in
                Text(track.artist).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(2), library.orderedVisibleColumns[2] == .album {
            TableColumn("Album", value: \.album) { track in
                Text(track.album).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 100, ideal: 180)
        } else if library.orderedVisibleColumns.indices.contains(2), library.orderedVisibleColumns[2] == .genre {
            TableColumn("Genre", value: \.genre) { track in
                Text(track.genre).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 70, ideal: 100)
        } else if library.orderedVisibleColumns.indices.contains(2), library.orderedVisibleColumns[2] == .year {
            TableColumn("Year", value: \.yearSortKey) { track in
                Text(track.year.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 50, ideal: 60, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(2), library.orderedVisibleColumns[2] == .trackNumber {
            TableColumn("Track #", value: \.trackNumberSortKey) { track in
                Text(track.trackNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 50, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(2), library.orderedVisibleColumns[2] == .discNumber {
            TableColumn("Disc #", value: \.discNumberSortKey) { track in
                Text(track.discNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 50, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(2), library.orderedVisibleColumns[2] == .bpm {
            TableColumn("BPM", value: \.bpmSortKey) { track in
                Text(track.bpm.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 46, max: 80)
        } else if library.orderedVisibleColumns.indices.contains(2), library.orderedVisibleColumns[2] == .key {
            TableColumn("Key", value: \.keySortKey) { track in
                Text(track.key ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 46, max: 80)
        } else if library.orderedVisibleColumns.indices.contains(2), library.orderedVisibleColumns[2] == .comments {
            TableColumn("Comments", value: \.commentsSortKey) { track in
                Text(track.comments ?? "").foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(2), library.orderedVisibleColumns[2] == .plays {
            TableColumn("Plays", value: \.playCount) { track in
                Text(track.playCount > 0 ? String(format: "%.1f", track.playCount) : "–").foregroundStyle(rowTextColor(track)).monospacedDigit()
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 46, max: 80)
        } else if library.orderedVisibleColumns.indices.contains(2), library.orderedVisibleColumns[2] == .tags {
            TableColumn("Tags", value: \.tagsSortKey) { track in
                Text(track.tags.joined(separator: ", ")).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 80, ideal: 140)
        } else if library.orderedVisibleColumns.indices.contains(2), library.orderedVisibleColumns[2] == .time {
            TableColumn("Time", value: \.duration) { track in
                Text(track.durationString).foregroundStyle(rowTextColor(track)).monospacedDigit()
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 50, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(2), library.orderedVisibleColumns[2] == .rating {
            TableColumn("Resonance", value: \.rating) { track in
                RatingCellView(
                    rating: Binding(
                        get: { track.rating },
                        set: { library.setRating($0, for: track) }
                    ),
                    isSelected: selection.count == 1 && selection.contains(track.id),
                    showSlider: selection.count == 1 && dragArmedIDs.contains(track.id)
                )
                .padding(.horizontal, 10)
            }
            .width(min: 110, ideal: 130)
        }
    }

    @TableColumnBuilder<Track, KeyPathComparator<Track>>
    private var columnSlot3: some TableColumnContent<Track, KeyPathComparator<Track>> {
        if library.orderedVisibleColumns.indices.contains(3), library.orderedVisibleColumns[3] == .title {
            TableColumn("Title", value: \.title) { track in
                Text(track.title)
                    .fontWeight(track.id == nowPlaying.trackID ? .semibold : .regular)
                    .foregroundStyle(rowTextColor(track))
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .modifier(ReorderModifier(track: track, playlist: activePlaylist, library: library, isDragArmed: dragArmedIDs.contains(track.id)))
                .padding(.horizontal, 10)
            }
            .width(min: 160, ideal: 260)
        } else if library.orderedVisibleColumns.indices.contains(3), library.orderedVisibleColumns[3] == .artist {
            TableColumn("Artist", value: \.artist) { track in
                Text(track.artist).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(3), library.orderedVisibleColumns[3] == .album {
            TableColumn("Album", value: \.album) { track in
                Text(track.album).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 100, ideal: 180)
        } else if library.orderedVisibleColumns.indices.contains(3), library.orderedVisibleColumns[3] == .genre {
            TableColumn("Genre", value: \.genre) { track in
                Text(track.genre).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 70, ideal: 100)
        } else if library.orderedVisibleColumns.indices.contains(3), library.orderedVisibleColumns[3] == .year {
            TableColumn("Year", value: \.yearSortKey) { track in
                Text(track.year.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 50, ideal: 60, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(3), library.orderedVisibleColumns[3] == .trackNumber {
            TableColumn("Track #", value: \.trackNumberSortKey) { track in
                Text(track.trackNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 50, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(3), library.orderedVisibleColumns[3] == .discNumber {
            TableColumn("Disc #", value: \.discNumberSortKey) { track in
                Text(track.discNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 50, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(3), library.orderedVisibleColumns[3] == .bpm {
            TableColumn("BPM", value: \.bpmSortKey) { track in
                Text(track.bpm.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 46, max: 80)
        } else if library.orderedVisibleColumns.indices.contains(3), library.orderedVisibleColumns[3] == .key {
            TableColumn("Key", value: \.keySortKey) { track in
                Text(track.key ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 46, max: 80)
        } else if library.orderedVisibleColumns.indices.contains(3), library.orderedVisibleColumns[3] == .comments {
            TableColumn("Comments", value: \.commentsSortKey) { track in
                Text(track.comments ?? "").foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(3), library.orderedVisibleColumns[3] == .plays {
            TableColumn("Plays", value: \.playCount) { track in
                Text(track.playCount > 0 ? String(format: "%.1f", track.playCount) : "–").foregroundStyle(rowTextColor(track)).monospacedDigit()
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 46, max: 80)
        } else if library.orderedVisibleColumns.indices.contains(3), library.orderedVisibleColumns[3] == .tags {
            TableColumn("Tags", value: \.tagsSortKey) { track in
                Text(track.tags.joined(separator: ", ")).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 80, ideal: 140)
        } else if library.orderedVisibleColumns.indices.contains(3), library.orderedVisibleColumns[3] == .time {
            TableColumn("Time", value: \.duration) { track in
                Text(track.durationString).foregroundStyle(rowTextColor(track)).monospacedDigit()
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 50, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(3), library.orderedVisibleColumns[3] == .rating {
            TableColumn("Resonance", value: \.rating) { track in
                RatingCellView(
                    rating: Binding(
                        get: { track.rating },
                        set: { library.setRating($0, for: track) }
                    ),
                    isSelected: selection.count == 1 && selection.contains(track.id),
                    showSlider: selection.count == 1 && dragArmedIDs.contains(track.id)
                )
                .padding(.horizontal, 10)
            }
            .width(min: 110, ideal: 130)
        }
    }

    @TableColumnBuilder<Track, KeyPathComparator<Track>>
    private var columnSlot4: some TableColumnContent<Track, KeyPathComparator<Track>> {
        if library.orderedVisibleColumns.indices.contains(4), library.orderedVisibleColumns[4] == .title {
            TableColumn("Title", value: \.title) { track in
                Text(track.title)
                    .fontWeight(track.id == nowPlaying.trackID ? .semibold : .regular)
                    .foregroundStyle(rowTextColor(track))
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .modifier(ReorderModifier(track: track, playlist: activePlaylist, library: library, isDragArmed: dragArmedIDs.contains(track.id)))
                .padding(.horizontal, 10)
            }
            .width(min: 160, ideal: 260)
        } else if library.orderedVisibleColumns.indices.contains(4), library.orderedVisibleColumns[4] == .artist {
            TableColumn("Artist", value: \.artist) { track in
                Text(track.artist).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(4), library.orderedVisibleColumns[4] == .album {
            TableColumn("Album", value: \.album) { track in
                Text(track.album).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 100, ideal: 180)
        } else if library.orderedVisibleColumns.indices.contains(4), library.orderedVisibleColumns[4] == .genre {
            TableColumn("Genre", value: \.genre) { track in
                Text(track.genre).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 70, ideal: 100)
        } else if library.orderedVisibleColumns.indices.contains(4), library.orderedVisibleColumns[4] == .year {
            TableColumn("Year", value: \.yearSortKey) { track in
                Text(track.year.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 50, ideal: 60, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(4), library.orderedVisibleColumns[4] == .trackNumber {
            TableColumn("Track #", value: \.trackNumberSortKey) { track in
                Text(track.trackNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 50, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(4), library.orderedVisibleColumns[4] == .discNumber {
            TableColumn("Disc #", value: \.discNumberSortKey) { track in
                Text(track.discNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 50, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(4), library.orderedVisibleColumns[4] == .bpm {
            TableColumn("BPM", value: \.bpmSortKey) { track in
                Text(track.bpm.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 46, max: 80)
        } else if library.orderedVisibleColumns.indices.contains(4), library.orderedVisibleColumns[4] == .key {
            TableColumn("Key", value: \.keySortKey) { track in
                Text(track.key ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 46, max: 80)
        } else if library.orderedVisibleColumns.indices.contains(4), library.orderedVisibleColumns[4] == .comments {
            TableColumn("Comments", value: \.commentsSortKey) { track in
                Text(track.comments ?? "").foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(4), library.orderedVisibleColumns[4] == .plays {
            TableColumn("Plays", value: \.playCount) { track in
                Text(track.playCount > 0 ? String(format: "%.1f", track.playCount) : "–").foregroundStyle(rowTextColor(track)).monospacedDigit()
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 46, max: 80)
        } else if library.orderedVisibleColumns.indices.contains(4), library.orderedVisibleColumns[4] == .tags {
            TableColumn("Tags", value: \.tagsSortKey) { track in
                Text(track.tags.joined(separator: ", ")).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 80, ideal: 140)
        } else if library.orderedVisibleColumns.indices.contains(4), library.orderedVisibleColumns[4] == .time {
            TableColumn("Time", value: \.duration) { track in
                Text(track.durationString).foregroundStyle(rowTextColor(track)).monospacedDigit()
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 50, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(4), library.orderedVisibleColumns[4] == .rating {
            TableColumn("Resonance", value: \.rating) { track in
                RatingCellView(
                    rating: Binding(
                        get: { track.rating },
                        set: { library.setRating($0, for: track) }
                    ),
                    isSelected: selection.count == 1 && selection.contains(track.id),
                    showSlider: selection.count == 1 && dragArmedIDs.contains(track.id)
                )
                .padding(.horizontal, 10)
            }
            .width(min: 110, ideal: 130)
        }
    }

    @TableColumnBuilder<Track, KeyPathComparator<Track>>
    private var columnSlot5: some TableColumnContent<Track, KeyPathComparator<Track>> {
        if library.orderedVisibleColumns.indices.contains(5), library.orderedVisibleColumns[5] == .title {
            TableColumn("Title", value: \.title) { track in
                Text(track.title)
                    .fontWeight(track.id == nowPlaying.trackID ? .semibold : .regular)
                    .foregroundStyle(rowTextColor(track))
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .modifier(ReorderModifier(track: track, playlist: activePlaylist, library: library, isDragArmed: dragArmedIDs.contains(track.id)))
                .padding(.horizontal, 10)
            }
            .width(min: 160, ideal: 260)
        } else if library.orderedVisibleColumns.indices.contains(5), library.orderedVisibleColumns[5] == .artist {
            TableColumn("Artist", value: \.artist) { track in
                Text(track.artist).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(5), library.orderedVisibleColumns[5] == .album {
            TableColumn("Album", value: \.album) { track in
                Text(track.album).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 100, ideal: 180)
        } else if library.orderedVisibleColumns.indices.contains(5), library.orderedVisibleColumns[5] == .genre {
            TableColumn("Genre", value: \.genre) { track in
                Text(track.genre).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 70, ideal: 100)
        } else if library.orderedVisibleColumns.indices.contains(5), library.orderedVisibleColumns[5] == .year {
            TableColumn("Year", value: \.yearSortKey) { track in
                Text(track.year.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 50, ideal: 60, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(5), library.orderedVisibleColumns[5] == .trackNumber {
            TableColumn("Track #", value: \.trackNumberSortKey) { track in
                Text(track.trackNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 50, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(5), library.orderedVisibleColumns[5] == .discNumber {
            TableColumn("Disc #", value: \.discNumberSortKey) { track in
                Text(track.discNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 50, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(5), library.orderedVisibleColumns[5] == .bpm {
            TableColumn("BPM", value: \.bpmSortKey) { track in
                Text(track.bpm.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 46, max: 80)
        } else if library.orderedVisibleColumns.indices.contains(5), library.orderedVisibleColumns[5] == .key {
            TableColumn("Key", value: \.keySortKey) { track in
                Text(track.key ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 46, max: 80)
        } else if library.orderedVisibleColumns.indices.contains(5), library.orderedVisibleColumns[5] == .comments {
            TableColumn("Comments", value: \.commentsSortKey) { track in
                Text(track.comments ?? "").foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(5), library.orderedVisibleColumns[5] == .plays {
            TableColumn("Plays", value: \.playCount) { track in
                Text(track.playCount > 0 ? String(format: "%.1f", track.playCount) : "–").foregroundStyle(rowTextColor(track)).monospacedDigit()
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 46, max: 80)
        } else if library.orderedVisibleColumns.indices.contains(5), library.orderedVisibleColumns[5] == .tags {
            TableColumn("Tags", value: \.tagsSortKey) { track in
                Text(track.tags.joined(separator: ", ")).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 80, ideal: 140)
        } else if library.orderedVisibleColumns.indices.contains(5), library.orderedVisibleColumns[5] == .time {
            TableColumn("Time", value: \.duration) { track in
                Text(track.durationString).foregroundStyle(rowTextColor(track)).monospacedDigit()
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 50, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(5), library.orderedVisibleColumns[5] == .rating {
            TableColumn("Resonance", value: \.rating) { track in
                RatingCellView(
                    rating: Binding(
                        get: { track.rating },
                        set: { library.setRating($0, for: track) }
                    ),
                    isSelected: selection.count == 1 && selection.contains(track.id),
                    showSlider: selection.count == 1 && dragArmedIDs.contains(track.id)
                )
                .padding(.horizontal, 10)
            }
            .width(min: 110, ideal: 130)
        }
    }

    @TableColumnBuilder<Track, KeyPathComparator<Track>>
    private var columnSlot6: some TableColumnContent<Track, KeyPathComparator<Track>> {
        if library.orderedVisibleColumns.indices.contains(6), library.orderedVisibleColumns[6] == .title {
            TableColumn("Title", value: \.title) { track in
                Text(track.title)
                    .fontWeight(track.id == nowPlaying.trackID ? .semibold : .regular)
                    .foregroundStyle(rowTextColor(track))
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .modifier(ReorderModifier(track: track, playlist: activePlaylist, library: library, isDragArmed: dragArmedIDs.contains(track.id)))
                .padding(.horizontal, 10)
            }
            .width(min: 160, ideal: 260)
        } else if library.orderedVisibleColumns.indices.contains(6), library.orderedVisibleColumns[6] == .artist {
            TableColumn("Artist", value: \.artist) { track in
                Text(track.artist).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(6), library.orderedVisibleColumns[6] == .album {
            TableColumn("Album", value: \.album) { track in
                Text(track.album).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 100, ideal: 180)
        } else if library.orderedVisibleColumns.indices.contains(6), library.orderedVisibleColumns[6] == .genre {
            TableColumn("Genre", value: \.genre) { track in
                Text(track.genre).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 70, ideal: 100)
        } else if library.orderedVisibleColumns.indices.contains(6), library.orderedVisibleColumns[6] == .year {
            TableColumn("Year", value: \.yearSortKey) { track in
                Text(track.year.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 50, ideal: 60, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(6), library.orderedVisibleColumns[6] == .trackNumber {
            TableColumn("Track #", value: \.trackNumberSortKey) { track in
                Text(track.trackNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 50, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(6), library.orderedVisibleColumns[6] == .discNumber {
            TableColumn("Disc #", value: \.discNumberSortKey) { track in
                Text(track.discNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 50, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(6), library.orderedVisibleColumns[6] == .bpm {
            TableColumn("BPM", value: \.bpmSortKey) { track in
                Text(track.bpm.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 46, max: 80)
        } else if library.orderedVisibleColumns.indices.contains(6), library.orderedVisibleColumns[6] == .key {
            TableColumn("Key", value: \.keySortKey) { track in
                Text(track.key ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 46, max: 80)
        } else if library.orderedVisibleColumns.indices.contains(6), library.orderedVisibleColumns[6] == .comments {
            TableColumn("Comments", value: \.commentsSortKey) { track in
                Text(track.comments ?? "").foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(6), library.orderedVisibleColumns[6] == .plays {
            TableColumn("Plays", value: \.playCount) { track in
                Text(track.playCount > 0 ? String(format: "%.1f", track.playCount) : "–").foregroundStyle(rowTextColor(track)).monospacedDigit()
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 46, max: 80)
        } else if library.orderedVisibleColumns.indices.contains(6), library.orderedVisibleColumns[6] == .tags {
            TableColumn("Tags", value: \.tagsSortKey) { track in
                Text(track.tags.joined(separator: ", ")).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 80, ideal: 140)
        } else if library.orderedVisibleColumns.indices.contains(6), library.orderedVisibleColumns[6] == .time {
            TableColumn("Time", value: \.duration) { track in
                Text(track.durationString).foregroundStyle(rowTextColor(track)).monospacedDigit()
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 50, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(6), library.orderedVisibleColumns[6] == .rating {
            TableColumn("Resonance", value: \.rating) { track in
                RatingCellView(
                    rating: Binding(
                        get: { track.rating },
                        set: { library.setRating($0, for: track) }
                    ),
                    isSelected: selection.count == 1 && selection.contains(track.id),
                    showSlider: selection.count == 1 && dragArmedIDs.contains(track.id)
                )
                .padding(.horizontal, 10)
            }
            .width(min: 110, ideal: 130)
        }
    }

    @TableColumnBuilder<Track, KeyPathComparator<Track>>
    private var columnSlot7: some TableColumnContent<Track, KeyPathComparator<Track>> {
        if library.orderedVisibleColumns.indices.contains(7), library.orderedVisibleColumns[7] == .title {
            TableColumn("Title", value: \.title) { track in
                Text(track.title)
                    .fontWeight(track.id == nowPlaying.trackID ? .semibold : .regular)
                    .foregroundStyle(rowTextColor(track))
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .modifier(ReorderModifier(track: track, playlist: activePlaylist, library: library, isDragArmed: dragArmedIDs.contains(track.id)))
                .padding(.horizontal, 10)
            }
            .width(min: 160, ideal: 260)
        } else if library.orderedVisibleColumns.indices.contains(7), library.orderedVisibleColumns[7] == .artist {
            TableColumn("Artist", value: \.artist) { track in
                Text(track.artist).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(7), library.orderedVisibleColumns[7] == .album {
            TableColumn("Album", value: \.album) { track in
                Text(track.album).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 100, ideal: 180)
        } else if library.orderedVisibleColumns.indices.contains(7), library.orderedVisibleColumns[7] == .genre {
            TableColumn("Genre", value: \.genre) { track in
                Text(track.genre).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 70, ideal: 100)
        } else if library.orderedVisibleColumns.indices.contains(7), library.orderedVisibleColumns[7] == .year {
            TableColumn("Year", value: \.yearSortKey) { track in
                Text(track.year.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 50, ideal: 60, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(7), library.orderedVisibleColumns[7] == .trackNumber {
            TableColumn("Track #", value: \.trackNumberSortKey) { track in
                Text(track.trackNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 50, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(7), library.orderedVisibleColumns[7] == .discNumber {
            TableColumn("Disc #", value: \.discNumberSortKey) { track in
                Text(track.discNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 50, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(7), library.orderedVisibleColumns[7] == .bpm {
            TableColumn("BPM", value: \.bpmSortKey) { track in
                Text(track.bpm.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 46, max: 80)
        } else if library.orderedVisibleColumns.indices.contains(7), library.orderedVisibleColumns[7] == .key {
            TableColumn("Key", value: \.keySortKey) { track in
                Text(track.key ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 46, max: 80)
        } else if library.orderedVisibleColumns.indices.contains(7), library.orderedVisibleColumns[7] == .comments {
            TableColumn("Comments", value: \.commentsSortKey) { track in
                Text(track.comments ?? "").foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(7), library.orderedVisibleColumns[7] == .plays {
            TableColumn("Plays", value: \.playCount) { track in
                Text(track.playCount > 0 ? String(format: "%.1f", track.playCount) : "–").foregroundStyle(rowTextColor(track)).monospacedDigit()
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 46, max: 80)
        } else if library.orderedVisibleColumns.indices.contains(7), library.orderedVisibleColumns[7] == .tags {
            TableColumn("Tags", value: \.tagsSortKey) { track in
                Text(track.tags.joined(separator: ", ")).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 80, ideal: 140)
        } else if library.orderedVisibleColumns.indices.contains(7), library.orderedVisibleColumns[7] == .time {
            TableColumn("Time", value: \.duration) { track in
                Text(track.durationString).foregroundStyle(rowTextColor(track)).monospacedDigit()
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 50, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(7), library.orderedVisibleColumns[7] == .rating {
            TableColumn("Resonance", value: \.rating) { track in
                RatingCellView(
                    rating: Binding(
                        get: { track.rating },
                        set: { library.setRating($0, for: track) }
                    ),
                    isSelected: selection.count == 1 && selection.contains(track.id),
                    showSlider: selection.count == 1 && dragArmedIDs.contains(track.id)
                )
                .padding(.horizontal, 10)
            }
            .width(min: 110, ideal: 130)
        }
    }

    @TableColumnBuilder<Track, KeyPathComparator<Track>>
    private var columnSlot8: some TableColumnContent<Track, KeyPathComparator<Track>> {
        if library.orderedVisibleColumns.indices.contains(8), library.orderedVisibleColumns[8] == .title {
            TableColumn("Title", value: \.title) { track in
                Text(track.title)
                    .fontWeight(track.id == nowPlaying.trackID ? .semibold : .regular)
                    .foregroundStyle(rowTextColor(track))
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .modifier(ReorderModifier(track: track, playlist: activePlaylist, library: library, isDragArmed: dragArmedIDs.contains(track.id)))
                .padding(.horizontal, 10)
            }
            .width(min: 160, ideal: 260)
        } else if library.orderedVisibleColumns.indices.contains(8), library.orderedVisibleColumns[8] == .artist {
            TableColumn("Artist", value: \.artist) { track in
                Text(track.artist).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(8), library.orderedVisibleColumns[8] == .album {
            TableColumn("Album", value: \.album) { track in
                Text(track.album).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 100, ideal: 180)
        } else if library.orderedVisibleColumns.indices.contains(8), library.orderedVisibleColumns[8] == .genre {
            TableColumn("Genre", value: \.genre) { track in
                Text(track.genre).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 70, ideal: 100)
        } else if library.orderedVisibleColumns.indices.contains(8), library.orderedVisibleColumns[8] == .year {
            TableColumn("Year", value: \.yearSortKey) { track in
                Text(track.year.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 50, ideal: 60, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(8), library.orderedVisibleColumns[8] == .trackNumber {
            TableColumn("Track #", value: \.trackNumberSortKey) { track in
                Text(track.trackNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 50, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(8), library.orderedVisibleColumns[8] == .discNumber {
            TableColumn("Disc #", value: \.discNumberSortKey) { track in
                Text(track.discNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 50, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(8), library.orderedVisibleColumns[8] == .bpm {
            TableColumn("BPM", value: \.bpmSortKey) { track in
                Text(track.bpm.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 46, max: 80)
        } else if library.orderedVisibleColumns.indices.contains(8), library.orderedVisibleColumns[8] == .key {
            TableColumn("Key", value: \.keySortKey) { track in
                Text(track.key ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 46, max: 80)
        } else if library.orderedVisibleColumns.indices.contains(8), library.orderedVisibleColumns[8] == .comments {
            TableColumn("Comments", value: \.commentsSortKey) { track in
                Text(track.comments ?? "").foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(8), library.orderedVisibleColumns[8] == .plays {
            TableColumn("Plays", value: \.playCount) { track in
                Text(track.playCount > 0 ? String(format: "%.1f", track.playCount) : "–").foregroundStyle(rowTextColor(track)).monospacedDigit()
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 46, max: 80)
        } else if library.orderedVisibleColumns.indices.contains(8), library.orderedVisibleColumns[8] == .tags {
            TableColumn("Tags", value: \.tagsSortKey) { track in
                Text(track.tags.joined(separator: ", ")).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 80, ideal: 140)
        } else if library.orderedVisibleColumns.indices.contains(8), library.orderedVisibleColumns[8] == .time {
            TableColumn("Time", value: \.duration) { track in
                Text(track.durationString).foregroundStyle(rowTextColor(track)).monospacedDigit()
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 50, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(8), library.orderedVisibleColumns[8] == .rating {
            TableColumn("Resonance", value: \.rating) { track in
                RatingCellView(
                    rating: Binding(
                        get: { track.rating },
                        set: { library.setRating($0, for: track) }
                    ),
                    isSelected: selection.count == 1 && selection.contains(track.id),
                    showSlider: selection.count == 1 && dragArmedIDs.contains(track.id)
                )
                .padding(.horizontal, 10)
            }
            .width(min: 110, ideal: 130)
        }
    }

    @TableColumnBuilder<Track, KeyPathComparator<Track>>
    private var columnSlot9: some TableColumnContent<Track, KeyPathComparator<Track>> {
        if library.orderedVisibleColumns.indices.contains(9), library.orderedVisibleColumns[9] == .title {
            TableColumn("Title", value: \.title) { track in
                Text(track.title)
                    .fontWeight(track.id == nowPlaying.trackID ? .semibold : .regular)
                    .foregroundStyle(rowTextColor(track))
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .modifier(ReorderModifier(track: track, playlist: activePlaylist, library: library, isDragArmed: dragArmedIDs.contains(track.id)))
                .padding(.horizontal, 10)
            }
            .width(min: 160, ideal: 260)
        } else if library.orderedVisibleColumns.indices.contains(9), library.orderedVisibleColumns[9] == .artist {
            TableColumn("Artist", value: \.artist) { track in
                Text(track.artist).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(9), library.orderedVisibleColumns[9] == .album {
            TableColumn("Album", value: \.album) { track in
                Text(track.album).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 100, ideal: 180)
        } else if library.orderedVisibleColumns.indices.contains(9), library.orderedVisibleColumns[9] == .genre {
            TableColumn("Genre", value: \.genre) { track in
                Text(track.genre).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 70, ideal: 100)
        } else if library.orderedVisibleColumns.indices.contains(9), library.orderedVisibleColumns[9] == .year {
            TableColumn("Year", value: \.yearSortKey) { track in
                Text(track.year.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 50, ideal: 60, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(9), library.orderedVisibleColumns[9] == .trackNumber {
            TableColumn("Track #", value: \.trackNumberSortKey) { track in
                Text(track.trackNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 50, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(9), library.orderedVisibleColumns[9] == .discNumber {
            TableColumn("Disc #", value: \.discNumberSortKey) { track in
                Text(track.discNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 50, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(9), library.orderedVisibleColumns[9] == .bpm {
            TableColumn("BPM", value: \.bpmSortKey) { track in
                Text(track.bpm.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 46, max: 80)
        } else if library.orderedVisibleColumns.indices.contains(9), library.orderedVisibleColumns[9] == .key {
            TableColumn("Key", value: \.keySortKey) { track in
                Text(track.key ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 46, max: 80)
        } else if library.orderedVisibleColumns.indices.contains(9), library.orderedVisibleColumns[9] == .comments {
            TableColumn("Comments", value: \.commentsSortKey) { track in
                Text(track.comments ?? "").foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(9), library.orderedVisibleColumns[9] == .plays {
            TableColumn("Plays", value: \.playCount) { track in
                Text(track.playCount > 0 ? String(format: "%.1f", track.playCount) : "–").foregroundStyle(rowTextColor(track)).monospacedDigit()
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 46, max: 80)
        } else if library.orderedVisibleColumns.indices.contains(9), library.orderedVisibleColumns[9] == .tags {
            TableColumn("Tags", value: \.tagsSortKey) { track in
                Text(track.tags.joined(separator: ", ")).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 80, ideal: 140)
        } else if library.orderedVisibleColumns.indices.contains(9), library.orderedVisibleColumns[9] == .time {
            TableColumn("Time", value: \.duration) { track in
                Text(track.durationString).foregroundStyle(rowTextColor(track)).monospacedDigit()
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 50, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(9), library.orderedVisibleColumns[9] == .rating {
            TableColumn("Resonance", value: \.rating) { track in
                RatingCellView(
                    rating: Binding(
                        get: { track.rating },
                        set: { library.setRating($0, for: track) }
                    ),
                    isSelected: selection.count == 1 && selection.contains(track.id),
                    showSlider: selection.count == 1 && dragArmedIDs.contains(track.id)
                )
                .padding(.horizontal, 10)
            }
            .width(min: 110, ideal: 130)
        }
    }

    @TableColumnBuilder<Track, KeyPathComparator<Track>>
    private var columnSlot10: some TableColumnContent<Track, KeyPathComparator<Track>> {
        if library.orderedVisibleColumns.indices.contains(10), library.orderedVisibleColumns[10] == .title {
            TableColumn("Title", value: \.title) { track in
                Text(track.title)
                    .fontWeight(track.id == nowPlaying.trackID ? .semibold : .regular)
                    .foregroundStyle(rowTextColor(track))
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .modifier(ReorderModifier(track: track, playlist: activePlaylist, library: library, isDragArmed: dragArmedIDs.contains(track.id)))
                .padding(.horizontal, 10)
            }
            .width(min: 160, ideal: 260)
        } else if library.orderedVisibleColumns.indices.contains(10), library.orderedVisibleColumns[10] == .artist {
            TableColumn("Artist", value: \.artist) { track in
                Text(track.artist).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(10), library.orderedVisibleColumns[10] == .album {
            TableColumn("Album", value: \.album) { track in
                Text(track.album).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 100, ideal: 180)
        } else if library.orderedVisibleColumns.indices.contains(10), library.orderedVisibleColumns[10] == .genre {
            TableColumn("Genre", value: \.genre) { track in
                Text(track.genre).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 70, ideal: 100)
        } else if library.orderedVisibleColumns.indices.contains(10), library.orderedVisibleColumns[10] == .year {
            TableColumn("Year", value: \.yearSortKey) { track in
                Text(track.year.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 50, ideal: 60, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(10), library.orderedVisibleColumns[10] == .trackNumber {
            TableColumn("Track #", value: \.trackNumberSortKey) { track in
                Text(track.trackNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 50, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(10), library.orderedVisibleColumns[10] == .discNumber {
            TableColumn("Disc #", value: \.discNumberSortKey) { track in
                Text(track.discNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 50, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(10), library.orderedVisibleColumns[10] == .bpm {
            TableColumn("BPM", value: \.bpmSortKey) { track in
                Text(track.bpm.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 46, max: 80)
        } else if library.orderedVisibleColumns.indices.contains(10), library.orderedVisibleColumns[10] == .key {
            TableColumn("Key", value: \.keySortKey) { track in
                Text(track.key ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 46, max: 80)
        } else if library.orderedVisibleColumns.indices.contains(10), library.orderedVisibleColumns[10] == .comments {
            TableColumn("Comments", value: \.commentsSortKey) { track in
                Text(track.comments ?? "").foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(10), library.orderedVisibleColumns[10] == .plays {
            TableColumn("Plays", value: \.playCount) { track in
                Text(track.playCount > 0 ? String(format: "%.1f", track.playCount) : "–").foregroundStyle(rowTextColor(track)).monospacedDigit()
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 46, max: 80)
        } else if library.orderedVisibleColumns.indices.contains(10), library.orderedVisibleColumns[10] == .tags {
            TableColumn("Tags", value: \.tagsSortKey) { track in
                Text(track.tags.joined(separator: ", ")).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 80, ideal: 140)
        } else if library.orderedVisibleColumns.indices.contains(10), library.orderedVisibleColumns[10] == .time {
            TableColumn("Time", value: \.duration) { track in
                Text(track.durationString).foregroundStyle(rowTextColor(track)).monospacedDigit()
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 50, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(10), library.orderedVisibleColumns[10] == .rating {
            TableColumn("Resonance", value: \.rating) { track in
                RatingCellView(
                    rating: Binding(
                        get: { track.rating },
                        set: { library.setRating($0, for: track) }
                    ),
                    isSelected: selection.count == 1 && selection.contains(track.id),
                    showSlider: selection.count == 1 && dragArmedIDs.contains(track.id)
                )
                .padding(.horizontal, 10)
            }
            .width(min: 110, ideal: 130)
        }
    }

    @TableColumnBuilder<Track, KeyPathComparator<Track>>
    private var columnSlot11: some TableColumnContent<Track, KeyPathComparator<Track>> {
        if library.orderedVisibleColumns.indices.contains(11), library.orderedVisibleColumns[11] == .title {
            TableColumn("Title", value: \.title) { track in
                Text(track.title)
                    .fontWeight(track.id == nowPlaying.trackID ? .semibold : .regular)
                    .foregroundStyle(rowTextColor(track))
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .modifier(ReorderModifier(track: track, playlist: activePlaylist, library: library, isDragArmed: dragArmedIDs.contains(track.id)))
                .padding(.horizontal, 10)
            }
            .width(min: 160, ideal: 260)
        } else if library.orderedVisibleColumns.indices.contains(11), library.orderedVisibleColumns[11] == .artist {
            TableColumn("Artist", value: \.artist) { track in
                Text(track.artist).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(11), library.orderedVisibleColumns[11] == .album {
            TableColumn("Album", value: \.album) { track in
                Text(track.album).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 100, ideal: 180)
        } else if library.orderedVisibleColumns.indices.contains(11), library.orderedVisibleColumns[11] == .genre {
            TableColumn("Genre", value: \.genre) { track in
                Text(track.genre).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 70, ideal: 100)
        } else if library.orderedVisibleColumns.indices.contains(11), library.orderedVisibleColumns[11] == .year {
            TableColumn("Year", value: \.yearSortKey) { track in
                Text(track.year.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 50, ideal: 60, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(11), library.orderedVisibleColumns[11] == .trackNumber {
            TableColumn("Track #", value: \.trackNumberSortKey) { track in
                Text(track.trackNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 50, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(11), library.orderedVisibleColumns[11] == .discNumber {
            TableColumn("Disc #", value: \.discNumberSortKey) { track in
                Text(track.discNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 50, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(11), library.orderedVisibleColumns[11] == .bpm {
            TableColumn("BPM", value: \.bpmSortKey) { track in
                Text(track.bpm.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 46, max: 80)
        } else if library.orderedVisibleColumns.indices.contains(11), library.orderedVisibleColumns[11] == .key {
            TableColumn("Key", value: \.keySortKey) { track in
                Text(track.key ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 46, max: 80)
        } else if library.orderedVisibleColumns.indices.contains(11), library.orderedVisibleColumns[11] == .comments {
            TableColumn("Comments", value: \.commentsSortKey) { track in
                Text(track.comments ?? "").foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(11), library.orderedVisibleColumns[11] == .plays {
            TableColumn("Plays", value: \.playCount) { track in
                Text(track.playCount > 0 ? String(format: "%.1f", track.playCount) : "–").foregroundStyle(rowTextColor(track)).monospacedDigit()
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 46, max: 80)
        } else if library.orderedVisibleColumns.indices.contains(11), library.orderedVisibleColumns[11] == .tags {
            TableColumn("Tags", value: \.tagsSortKey) { track in
                Text(track.tags.joined(separator: ", ")).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 80, ideal: 140)
        } else if library.orderedVisibleColumns.indices.contains(11), library.orderedVisibleColumns[11] == .time {
            TableColumn("Time", value: \.duration) { track in
                Text(track.durationString).foregroundStyle(rowTextColor(track)).monospacedDigit()
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 50, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(11), library.orderedVisibleColumns[11] == .rating {
            TableColumn("Resonance", value: \.rating) { track in
                RatingCellView(
                    rating: Binding(
                        get: { track.rating },
                        set: { library.setRating($0, for: track) }
                    ),
                    isSelected: selection.count == 1 && selection.contains(track.id),
                    showSlider: selection.count == 1 && dragArmedIDs.contains(track.id)
                )
                .padding(.horizontal, 10)
            }
            .width(min: 110, ideal: 130)
        }
    }

    @TableColumnBuilder<Track, KeyPathComparator<Track>>
    private var columnSlot12: some TableColumnContent<Track, KeyPathComparator<Track>> {
        if library.orderedVisibleColumns.indices.contains(12), library.orderedVisibleColumns[12] == .title {
            TableColumn("Title", value: \.title) { track in
                Text(track.title)
                    .fontWeight(track.id == nowPlaying.trackID ? .semibold : .regular)
                    .foregroundStyle(rowTextColor(track))
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .modifier(ReorderModifier(track: track, playlist: activePlaylist, library: library, isDragArmed: dragArmedIDs.contains(track.id)))
                .padding(.horizontal, 10)
            }
            .width(min: 160, ideal: 260)
        } else if library.orderedVisibleColumns.indices.contains(12), library.orderedVisibleColumns[12] == .artist {
            TableColumn("Artist", value: \.artist) { track in
                Text(track.artist).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(12), library.orderedVisibleColumns[12] == .album {
            TableColumn("Album", value: \.album) { track in
                Text(track.album).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 100, ideal: 180)
        } else if library.orderedVisibleColumns.indices.contains(12), library.orderedVisibleColumns[12] == .genre {
            TableColumn("Genre", value: \.genre) { track in
                Text(track.genre).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 70, ideal: 100)
        } else if library.orderedVisibleColumns.indices.contains(12), library.orderedVisibleColumns[12] == .year {
            TableColumn("Year", value: \.yearSortKey) { track in
                Text(track.year.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 50, ideal: 60, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(12), library.orderedVisibleColumns[12] == .trackNumber {
            TableColumn("Track #", value: \.trackNumberSortKey) { track in
                Text(track.trackNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 50, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(12), library.orderedVisibleColumns[12] == .discNumber {
            TableColumn("Disc #", value: \.discNumberSortKey) { track in
                Text(track.discNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 50, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(12), library.orderedVisibleColumns[12] == .bpm {
            TableColumn("BPM", value: \.bpmSortKey) { track in
                Text(track.bpm.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 46, max: 80)
        } else if library.orderedVisibleColumns.indices.contains(12), library.orderedVisibleColumns[12] == .key {
            TableColumn("Key", value: \.keySortKey) { track in
                Text(track.key ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 46, max: 80)
        } else if library.orderedVisibleColumns.indices.contains(12), library.orderedVisibleColumns[12] == .comments {
            TableColumn("Comments", value: \.commentsSortKey) { track in
                Text(track.comments ?? "").foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(12), library.orderedVisibleColumns[12] == .plays {
            TableColumn("Plays", value: \.playCount) { track in
                Text(track.playCount > 0 ? String(format: "%.1f", track.playCount) : "–").foregroundStyle(rowTextColor(track)).monospacedDigit()
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 46, max: 80)
        } else if library.orderedVisibleColumns.indices.contains(12), library.orderedVisibleColumns[12] == .tags {
            TableColumn("Tags", value: \.tagsSortKey) { track in
                Text(track.tags.joined(separator: ", ")).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 80, ideal: 140)
        } else if library.orderedVisibleColumns.indices.contains(12), library.orderedVisibleColumns[12] == .time {
            TableColumn("Time", value: \.duration) { track in
                Text(track.durationString).foregroundStyle(rowTextColor(track)).monospacedDigit()
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 50, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(12), library.orderedVisibleColumns[12] == .rating {
            TableColumn("Resonance", value: \.rating) { track in
                RatingCellView(
                    rating: Binding(
                        get: { track.rating },
                        set: { library.setRating($0, for: track) }
                    ),
                    isSelected: selection.count == 1 && selection.contains(track.id),
                    showSlider: selection.count == 1 && dragArmedIDs.contains(track.id)
                )
                .padding(.horizontal, 10)
            }
            .width(min: 110, ideal: 130)
        }
    }

    @TableColumnBuilder<Track, KeyPathComparator<Track>>
    private var columnSlot13: some TableColumnContent<Track, KeyPathComparator<Track>> {
        if library.orderedVisibleColumns.indices.contains(13), library.orderedVisibleColumns[13] == .title {
            TableColumn("Title", value: \.title) { track in
                Text(track.title)
                    .fontWeight(track.id == nowPlaying.trackID ? .semibold : .regular)
                    .foregroundStyle(rowTextColor(track))
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .modifier(ReorderModifier(track: track, playlist: activePlaylist, library: library, isDragArmed: dragArmedIDs.contains(track.id)))
                .padding(.horizontal, 10)
            }
            .width(min: 160, ideal: 260)
        } else if library.orderedVisibleColumns.indices.contains(13), library.orderedVisibleColumns[13] == .artist {
            TableColumn("Artist", value: \.artist) { track in
                Text(track.artist).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(13), library.orderedVisibleColumns[13] == .album {
            TableColumn("Album", value: \.album) { track in
                Text(track.album).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 100, ideal: 180)
        } else if library.orderedVisibleColumns.indices.contains(13), library.orderedVisibleColumns[13] == .genre {
            TableColumn("Genre", value: \.genre) { track in
                Text(track.genre).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 70, ideal: 100)
        } else if library.orderedVisibleColumns.indices.contains(13), library.orderedVisibleColumns[13] == .year {
            TableColumn("Year", value: \.yearSortKey) { track in
                Text(track.year.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 50, ideal: 60, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(13), library.orderedVisibleColumns[13] == .trackNumber {
            TableColumn("Track #", value: \.trackNumberSortKey) { track in
                Text(track.trackNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 50, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(13), library.orderedVisibleColumns[13] == .discNumber {
            TableColumn("Disc #", value: \.discNumberSortKey) { track in
                Text(track.discNumber.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 50, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(13), library.orderedVisibleColumns[13] == .bpm {
            TableColumn("BPM", value: \.bpmSortKey) { track in
                Text(track.bpm.map(String.init) ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 46, max: 80)
        } else if library.orderedVisibleColumns.indices.contains(13), library.orderedVisibleColumns[13] == .key {
            TableColumn("Key", value: \.keySortKey) { track in
                Text(track.key ?? "").foregroundStyle(rowTextColor(track))
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 46, max: 80)
        } else if library.orderedVisibleColumns.indices.contains(13), library.orderedVisibleColumns[13] == .comments {
            TableColumn("Comments", value: \.commentsSortKey) { track in
                Text(track.comments ?? "").foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 100, ideal: 160)
        } else if library.orderedVisibleColumns.indices.contains(13), library.orderedVisibleColumns[13] == .plays {
            TableColumn("Plays", value: \.playCount) { track in
                Text(track.playCount > 0 ? String(format: "%.1f", track.playCount) : "–").foregroundStyle(rowTextColor(track)).monospacedDigit()
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 46, max: 80)
        } else if library.orderedVisibleColumns.indices.contains(13), library.orderedVisibleColumns[13] == .tags {
            TableColumn("Tags", value: \.tagsSortKey) { track in
                Text(track.tags.joined(separator: ", ")).foregroundStyle(rowTextColor(track)).lineLimit(1)
                .padding(.horizontal, 10)
            }
            .width(min: 80, ideal: 140)
        } else if library.orderedVisibleColumns.indices.contains(13), library.orderedVisibleColumns[13] == .time {
            TableColumn("Time", value: \.duration) { track in
                Text(track.durationString).foregroundStyle(rowTextColor(track)).monospacedDigit()
                .padding(.horizontal, 10)
            }
            .width(min: 40, ideal: 50, max: 90)
        } else if library.orderedVisibleColumns.indices.contains(13), library.orderedVisibleColumns[13] == .rating {
            TableColumn("Resonance", value: \.rating) { track in
                RatingCellView(
                    rating: Binding(
                        get: { track.rating },
                        set: { library.setRating($0, for: track) }
                    ),
                    isSelected: selection.count == 1 && selection.contains(track.id),
                    showSlider: selection.count == 1 && dragArmedIDs.contains(track.id)
                )
                .padding(.horizontal, 10)
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

/// Watches `player.$currentTrack`/`player.$isPlaying` and republishes just
/// the derived "which track, if any, is currently playing" identity —
/// deliberately not `player.currentTime`, which ticks on a ~0.25s timer
/// the whole time anything plays and has nothing to do with which row
/// should be highlighted. `removeDuplicates()` on each upstream publisher
/// means this only re-publishes when the *value* actually changes, not
/// merely when `player` reassigns it (e.g. `handleFinished()` sets both
/// `currentTrack` and `isPlaying` to their existing values in some paths).
@MainActor
private final class NowPlayingObserver: ObservableObject {
    @Published private(set) var trackID: Track.ID?
    @Published private(set) var isPlaying = false

    private var cancellable: AnyCancellable?

    init(player: PlayerController) {
        cancellable = player.$currentTrack
            .map { $0?.id }
            .removeDuplicates()
            .combineLatest(player.$isPlaying.removeDuplicates())
            .sink { [weak self] trackID, isPlaying in
                self?.trackID = trackID
                self?.isPlaying = isPlaying
            }
    }
}
