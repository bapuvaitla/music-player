import Foundation
import SwiftUI

/// Every column the track table can show, in the order the user can drag
/// them into. Title / Artist / Album / Time / Rating are always visible
/// (can't be hidden via the Columns popover) but can still be dragged to
/// any position alongside the optional ones.
public enum TrackColumn: String, CaseIterable, Identifiable, Sendable {
    case title, artist, album
    case genre, year, trackNumber, discNumber, bpm, key, comments, plays, tags
    case time, rating

    public var id: String { rawValue }

    /// Always shown regardless of `visibleColumns` — no checkbox in the
    /// Columns popover, just a drag handle to reposition it.
    public var isAlwaysVisible: Bool {
        switch self {
        case .title, .artist, .album, .time, .rating: return true
        default: return false
        }
    }

    public var title: String {
        switch self {
        case .title: return "Title"
        case .artist: return "Artist"
        case .album: return "Album"
        case .time: return "Time"
        case .rating: return "Rating"
        case .genre: return "Genre"
        case .year: return "Year"
        case .trackNumber: return "Track #"
        case .discNumber: return "Disc #"
        case .bpm: return "BPM"
        case .key: return "Key"
        case .comments: return "Comments"
        case .plays: return "Plays"
        case .tags: return "Tags"
        }
    }
}

private enum Facet {
    case artist, album, genre
}

@MainActor
public final class LibraryModel: ObservableObject {
    @Published public private(set) var tracks: [Track] = []
    @Published public private(set) var playlists: [Playlist] = []

    // What's currently "on screen" — restored on launch so reopening the
    // app comes back to the same browsing context instead of always
    // starting at the unfiltered library.
    @Published public var selectedArtists: Set<String> {
        didSet { persistBrowsingState() }
    }
    @Published public var selectedAlbums: Set<String> {
        didSet { persistBrowsingState() }
    }
    @Published public var selectedGenres: Set<String> {
        didSet { persistBrowsingState() }
    }
    @Published public var showUnratedOnly: Bool {
        didSet { persistBrowsingState() }
    }
    @Published public var selectedPlaylistID: UUID? {
        didSet { persistBrowsingState() }
    }
    /// Mirrors the track table's row selection (owned as real `@State` in
    /// TrackListView, which mirrors it here) so other views — like the
    /// sidebar's artwork panel — can react to "a track got selected"
    /// without needing selection to live centrally in the first place.
    @Published public var selectedTrackIDs: Set<String> = []

    /// Non-nil while the "Learn Song" view is open for a track — set from
    /// the track list's right-click menu, read by `ContentView` to decide
    /// whether to show that view over the normal library, and cleared by
    /// its own "Done" button.
    @Published public var learningTrack: Track?

    @Published public var isScanning: Bool = false
    @Published public var scanProgress: (completed: Int, total: Int)?
    @Published public var searchText: String = ""

    @Published public var visibleColumns: Set<TrackColumn> {
        didSet { persistVisibleColumns() }
    }

    /// Display order for the optional columns (drag-reordered from the
    /// toolbar's Columns popover). Always contains every `TrackColumn` case;
    /// the track table renders columns by checking, for each fixed slot
    /// position, which column (if any) is assigned there — confirmed via a
    /// standalone compile test that this (unlike `ForEach`) is accepted by
    /// `TableColumnBuilder`, so reordering here really does change what
    /// the table renders.
    @Published public private(set) var columnOrder: [TrackColumn]

    /// Every folder the user has added, so the library accumulates across
    /// multiple "Add Folder" picks instead of a new pick replacing the last.
    @Published public private(set) var scannedFolderPaths: [String] = []

    /// Every individually-added file's path — from `addFiles` (loose
    /// files, not a whole folder) or `importKnownTracks` (matched files
    /// out of a folder that isn't itself being tracked for rescanning).
    /// Without this, those tracks only ever existed in memory: unlike
    /// `addFolder`, nothing durable said "re-find this file" at the next
    /// launch, so `rescanAllFolders()` (which rebuilds `tracks` from
    /// scratch) silently dropped them. Not `@Published`/exposed — nothing
    /// in the UI needs to show or gate on this list itself.
    private var additionalTrackPaths: [String] = []

    /// Albums manually flagged "incomplete" — the user doesn't own every
    /// track, hasn't heard the rest, and doesn't want the average shown as
    /// if it reflected the whole album. Purely a user-declared flag, not
    /// derived: distinct from `partiallyRatedAlbums`, which is computed
    /// from whether every *owned* track has a rating.
    @Published public var incompleteRatingAlbums: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(incompleteRatingAlbums), forKey: Self.incompleteRatingAlbumsKey)
        }
    }

    private let ratingStore: RatingStore
    private let playlistStore: PlaylistStore
    private static let visibleColumnsKey = "visibleTrackColumns"
    private static let columnOrderKey = "trackColumnOrder"
    private static let scannedFoldersKey = "scannedFolderPaths"
    private static let additionalTrackPathsKey = "additionalTrackPaths"
    private static let selectedArtistsKey = "selectedArtists"
    private static let selectedAlbumsKey = "selectedAlbums"
    private static let selectedGenresKey = "selectedGenres"
    private static let showUnratedOnlyKey = "showUnratedOnly"
    private static let selectedPlaylistIDKey = "selectedPlaylistID"
    private static let incompleteRatingAlbumsKey = "incompleteRatingAlbums"

    public init(ratingStore: RatingStore, playlistStore: PlaylistStore) {
        self.ratingStore = ratingStore
        self.playlistStore = playlistStore
        self.visibleColumns = Self.loadVisibleColumns()
        self.columnOrder = Self.loadColumnOrder()
        self.scannedFolderPaths = Self.loadScannedFolderPaths()
        self.additionalTrackPaths = Self.loadAdditionalTrackPaths()
        self.selectedArtists = Set(UserDefaults.standard.stringArray(forKey: Self.selectedArtistsKey) ?? [])
        self.selectedAlbums = Set(UserDefaults.standard.stringArray(forKey: Self.selectedAlbumsKey) ?? [])
        self.selectedGenres = Set(UserDefaults.standard.stringArray(forKey: Self.selectedGenresKey) ?? [])
        self.showUnratedOnly = UserDefaults.standard.bool(forKey: Self.showUnratedOnlyKey)
        self.selectedPlaylistID = UserDefaults.standard.string(forKey: Self.selectedPlaylistIDKey).flatMap(UUID.init(uuidString:))
        self.incompleteRatingAlbums = Set(UserDefaults.standard.stringArray(forKey: Self.incompleteRatingAlbumsKey) ?? [])
        Task { await ArtworkLoader.shared.configure(store: ratingStore) }
    }

    public func toggleIncompleteRating(forAlbum album: String) {
        if incompleteRatingAlbums.contains(album) {
            incompleteRatingAlbums.remove(album)
        } else {
            incompleteRatingAlbums.insert(album)
        }
    }

    /// Every property here is `didSet`-driven back to this one call, since
    /// several of them commonly change together (e.g. `resetAllFilters`) —
    /// a little redundant on the rare multi-property update, but simpler
    /// than routing each property to its own write.
    private func persistBrowsingState() {
        let defaults = UserDefaults.standard
        defaults.set(Array(selectedArtists), forKey: Self.selectedArtistsKey)
        defaults.set(Array(selectedAlbums), forKey: Self.selectedAlbumsKey)
        defaults.set(Array(selectedGenres), forKey: Self.selectedGenresKey)
        defaults.set(showUnratedOnly, forKey: Self.showUnratedOnlyKey)
        defaults.set(selectedPlaylistID?.uuidString, forKey: Self.selectedPlaylistIDKey)
    }

    // MARK: - Faceted browsing

    /// Tracks eligible for browsing/playback — hidden tracks are excluded
    /// everywhere except album ratings, which intentionally still count them.
    public var visibleTracks: [Track] {
        tracks.filter { !$0.isHidden }
    }

    private func tracksMatchingFacets(excluding excluded: Facet?, includeHidden: Bool = false) -> [Track] {
        var result = includeHidden ? tracks : visibleTracks
        if excluded != .artist, !selectedArtists.isEmpty { result = result.filter { selectedArtists.contains($0.artist) } }
        if excluded != .album, !selectedAlbums.isEmpty { result = result.filter { selectedAlbums.contains($0.album) } }
        if excluded != .genre, !selectedGenres.isEmpty { result = result.filter { selectedGenres.contains($0.genre) } }
        if showUnratedOnly { result = result.filter { $0.rating == 0 } }
        return result
    }

    public var artists: [String] {
        Array(Set(tracksMatchingFacets(excluding: .artist).map(\.artist)))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Includes albums whose tracks are all hidden, so a fully-hidden
    /// album's rating still surfaces in the sidebar.
    public var albums: [String] {
        Array(Set(tracksMatchingFacets(excluding: .album, includeHidden: true).map(\.album)))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public var genres: [String] {
        Array(Set(tracksMatchingFacets(excluding: .genre).map(\.genre)))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public var artistTrackCounts: [String: Int] {
        Dictionary(grouping: tracksMatchingFacets(excluding: .artist), by: \.artist).mapValues(\.count)
    }

    public var genreTrackCounts: [String: Int] {
        Dictionary(grouping: tracksMatchingFacets(excluding: .genre), by: \.genre).mapValues(\.count)
    }

    /// How many tracks are currently unrated — shown next to the "Unrated"
    /// row itself, so it doesn't need to actually be selected to know.
    public var unratedTrackCount: Int {
        visibleTracks.filter { $0.rating == 0 }.count
    }

    /// Mean rating per album across the whole library (not affected by the
    /// current facet selection), excluding unrated tracks.
    public var albumAverageRatings: [String: Double] {
        var result: [String: Double] = [:]
        for (album, albumTracks) in Dictionary(grouping: tracks, by: \.album) {
            let rated = albumTracks.filter { $0.rating > 0 }
            guard !rated.isEmpty else { continue }
            result[album] = Double(rated.reduce(0) { $0 + $1.rating }) / Double(rated.count)
        }
        return result
    }

    /// Albums where some, but not all, tracks are rated — their average is
    /// still shown in the sidebar, just visually muted to flag that it's
    /// based on incomplete data.
    public var partiallyRatedAlbums: Set<String> {
        var result: Set<String> = []
        for (album, albumTracks) in Dictionary(grouping: tracks, by: \.album) {
            let rated = albumTracks.filter { $0.rating > 0 }
            guard !rated.isEmpty, rated.count < albumTracks.count else { continue }
            result.insert(album)
        }
        return result
    }

    public var allTags: [String] {
        Array(Set(tracks.flatMap(\.tags))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Replaces the entire artist selection — the sidebar computes what the
    /// new set should be (plain click = just this one, Cmd = toggle, Shift
    /// = range), matching standard macOS list selection conventions.
    public func setArtists(_ artists: Set<String>) {
        recordHistoryBeforeNavigating()
        selectedPlaylistID = nil
        selectedArtists = artists
    }

    public func setAlbums(_ albums: Set<String>) {
        recordHistoryBeforeNavigating()
        selectedPlaylistID = nil
        selectedAlbums = albums
    }

    public func setGenres(_ genres: Set<String>) {
        recordHistoryBeforeNavigating()
        selectedPlaylistID = nil
        selectedGenres = genres
    }

    public func toggleUnratedOnly() {
        recordHistoryBeforeNavigating()
        selectedPlaylistID = nil
        showUnratedOnly.toggle()
    }

    public func resetAllFilters() {
        recordHistoryBeforeNavigating()
        selectedArtists.removeAll()
        selectedAlbums.removeAll()
        selectedGenres.removeAll()
        showUnratedOnly = false
        selectedPlaylistID = nil
        searchText = ""
    }

    public func selectPlaylist(_ id: UUID?) {
        recordHistoryBeforeNavigating()
        selectedPlaylistID = id
        selectedArtists.removeAll()
        selectedAlbums.removeAll()
        selectedGenres.removeAll()
        showUnratedOnly = false
    }

    // MARK: - Back/forward navigation history

    /// What "a place you were browsing" means for back/forward purposes —
    /// deliberately excludes `searchText`: that's transient typing state,
    /// not a destination, and including it would push a new history entry
    /// on every keystroke.
    private struct BrowsingSnapshot: Equatable {
        var selectedArtists: Set<String>
        var selectedAlbums: Set<String>
        var selectedGenres: Set<String>
        var showUnratedOnly: Bool
        var selectedPlaylistID: UUID?
    }

    private var backStack: [BrowsingSnapshot] = []
    private var forwardStack: [BrowsingSnapshot] = []

    public var canGoBack: Bool { !backStack.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }

    private var currentBrowsingSnapshot: BrowsingSnapshot {
        BrowsingSnapshot(
            selectedArtists: selectedArtists,
            selectedAlbums: selectedAlbums,
            selectedGenres: selectedGenres,
            showUnratedOnly: showUnratedOnly,
            selectedPlaylistID: selectedPlaylistID
        )
    }

    /// Called at the top of every navigation method, before it changes
    /// anything — captures wherever you're standing right now as the place
    /// `goBack()` should return to, and (standard browser behavior)
    /// discards the forward history, since navigating anywhere new makes
    /// the old "forward" path stale.
    private func recordHistoryBeforeNavigating() {
        backStack.append(currentBrowsingSnapshot)
        forwardStack.removeAll()
    }

    /// Applies a snapshot directly (not through `setArtists`/etc.) so this
    /// never re-triggers `recordHistoryBeforeNavigating()` — moving through
    /// history shouldn't itself rewrite history.
    private func applyBrowsingSnapshot(_ snapshot: BrowsingSnapshot) {
        selectedArtists = snapshot.selectedArtists
        selectedAlbums = snapshot.selectedAlbums
        selectedGenres = snapshot.selectedGenres
        showUnratedOnly = snapshot.showUnratedOnly
        selectedPlaylistID = snapshot.selectedPlaylistID
    }

    public func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(currentBrowsingSnapshot)
        applyBrowsingSnapshot(previous)
    }

    public func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(currentBrowsingSnapshot)
        applyBrowsingSnapshot(next)
    }

    public var currentViewTitle: String {
        if let id = selectedPlaylistID, let playlist = playlists.first(where: { $0.id == id }) {
            return playlist.name
        }
        var parts: [String] = []
        parts.append(contentsOf: describeFacet(selectedArtists, singular: "Artist"))
        parts.append(contentsOf: describeFacet(selectedAlbums, singular: "Album"))
        parts.append(contentsOf: describeFacet(selectedGenres, singular: "Genre"))
        return parts.isEmpty ? "All Tracks" : parts.joined(separator: " · ")
    }

    private func describeFacet(_ selection: Set<String>, singular: String) -> [String] {
        if selection.isEmpty { return [] }
        if selection.count == 1, let only = selection.first { return [only] }
        return ["\(selection.count) \(singular)s"]
    }

    public var filteredTracks: [Track] {
        var result: [Track]

        if let id = selectedPlaylistID, let playlist = playlists.first(where: { $0.id == id }) {
            result = resolvedTracks(for: playlist)
        } else {
            result = tracksMatchingFacets(excluding: nil)
        }

        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter {
                $0.title.lowercased().contains(query) ||
                $0.artist.lowercased().contains(query) ||
                $0.album.lowercased().contains(query)
            }
        }

        return result
    }

    public func resolvedTracks(for playlist: Playlist) -> [Track] {
        if playlist.isSmart {
            let rules = playlist.smartRules
            guard !rules.isEmpty else { return [] }
            return visibleTracks.filter { track in
                playlist.smartMatchAll
                    ? rules.allSatisfy { $0.matches(track) }
                    : rules.contains { $0.matches(track) }
            }
        } else {
            let byPath = Dictionary(uniqueKeysWithValues: visibleTracks.map { ($0.path, $0) })
            return playlist.trackPaths.compactMap { byPath[$0] }
        }
    }

    // MARK: - Scanning

    /// Adds a new folder to the library. Only that folder is scanned — its
    /// tracks are merged into whatever is already loaded, so previously
    /// added folders/albums are never lost. Returns how many audio files
    /// were found in it, so callers can confirm the scan actually found
    /// something (as opposed to the tracks being added but hidden behind
    /// an unrelated filter still active from before).
    @discardableResult
    public func addFolder(_ folderURL: URL) async -> Int {
        if !scannedFolderPaths.contains(folderURL.path) {
            scannedFolderPaths.append(folderURL.path)
            persistScannedFolderPaths()
        }

        let scanned = await scanWithStoredRatings(rootURL: folderURL)
        mergeScannedTracks(scanned)
        return scanned.count
    }

    /// Imports individually-picked audio files rather than a whole folder.
    /// Unlike `addFolder`, these aren't added to `scannedFolderPaths` — a
    /// loose file isn't a "folder to keep watching" the way `addFolder`'s
    /// argument is — but each file's own path is remembered in
    /// `additionalTrackPaths` so `rescanAllFolders` (called at every
    /// launch) still finds it again later.
    public func addFiles(_ fileURLs: [URL]) async -> Int {
        isScanning = true
        scanProgress = (0, 0)
        let scanned = await applyStoredRatings(
            to: await LibraryScanner.scanFiles(fileURLs) { [weak self] completed, total in
                Task { @MainActor in self?.scanProgress = (completed, total) }
            }
        )
        isScanning = false
        scanProgress = nil

        rememberAdditionalTrackPaths(scanned.map(\.path))
        mergeScannedTracks(scanned)
        return scanned.count
    }

    /// Records paths outside of any `scannedFolderPaths` folder so they
    /// survive a relaunch — see `additionalTrackPaths`.
    private func rememberAdditionalTrackPaths(_ paths: [String]) {
        var didAdd = false
        for path in paths where !additionalTrackPaths.contains(path) {
            additionalTrackPaths.append(path)
            didAdd = true
        }
        if didAdd { persistAdditionalTrackPaths() }
    }

    private static func loadAdditionalTrackPaths() -> [String] {
        guard let raw = UserDefaults.standard.string(forKey: additionalTrackPathsKey), !raw.isEmpty else { return [] }
        return raw.components(separatedBy: "\n")
    }

    private func persistAdditionalTrackPaths() {
        UserDefaults.standard.set(additionalTrackPaths.joined(separator: "\n"), forKey: Self.additionalTrackPathsKey)
    }

    /// Scans `folderURL` like `addFolder`, but keeps only files whose
    /// fingerprint is already known from the iCloud sync catalog (see
    /// `iCloudSyncService.knownFingerprints`) — tracks already catalogued
    /// in the library on another machine. Lets a second machine mirror
    /// what's been curated elsewhere out of a larger local folder (e.g. a
    /// full personal archive) without re-importing everything in it and
    /// without moving any audio files between machines. Unlike
    /// `addFolder`, doesn't add `folderURL` itself to `scannedFolderPaths`
    /// — a plain rescan of the whole folder would re-import everything in
    /// it, defeating the point of matching only known tracks — but each
    /// matched file's own path is remembered in `additionalTrackPaths` so
    /// it still survives a relaunch. Returns how many matching tracks
    /// were found; `fileURL` exists only for tests to point at a scratch
    /// snapshot instead of the real iCloud Drive location.
    ///
    /// A newly-matched track has no *locally*-stored rating/play count of
    /// its own yet — `applyStoredRatings` below only ever pulls from this
    /// machine's own store, which has never seen this file before. The
    /// whole point of matching against the iCloud catalog is that the
    /// rating/play count already exist there (from whichever machine
    /// catalogued it first), so this re-runs `syncWithiCloud` once the
    /// matches are merged into `tracks`, letting that fingerprint-keyed
    /// merge fill them in — the same thing that happens automatically for
    /// a normal scan, just at app launch (see `ContentView`'s `.task`)
    /// rather than mid-session.
    @discardableResult
    public func importKnownTracks(from folderURL: URL, fileURL: URL? = nil) async -> Int {
        let knownEntries = iCloudSyncService.knownEntries(fileURL: fileURL)
        guard !knownEntries.isEmpty else { return 0 }

        isScanning = true
        scanProgress = (0, 0)
        let scanned = await applyStoredRatings(
            to: await LibraryScanner.scan(rootURL: folderURL) { [weak self] completed, total in
                Task { @MainActor in self?.scanProgress = (completed, total) }
            }
        )
        isScanning = false
        scanProgress = nil

        var matched: [Track] = []
        for var track in scanned {
            if knownEntries.keys.contains(track.syncFingerprint) {
                matched.append(track)
            } else if let fingerprint = iCloudSyncService.fuzzyMatchingFingerprint(for: track, in: knownEntries),
                      let metadata = knownEntries[fingerprint]?.metadata {
                // Tagged differently on this machine (a featured-artist
                // credit in a different field, an abridged album
                // subtitle, etc. — see `iCloudSyncService.fuzzyMatch`) —
                // lock in the catalog's exact wording so this becomes a
                // real fingerprint match from now on, rather than
                // depending on the fuzzy fallback on every future sync.
                await applyCatalogMetadataOverride(metadata, to: track)
                track.title = metadata.title
                track.artist = metadata.artist
                track.album = metadata.album
                matched.append(track)
            }
        }
        guard !matched.isEmpty else { return 0 }

        rememberAdditionalTrackPaths(matched.map(\.path))
        mergeScannedTracks(matched)
        await syncWithiCloud(fileURL: fileURL)
        return matched.count
    }

    /// Overrides a real track's title/artist/album to match the iCloud
    /// catalog's exact wording (everything else is carried through
    /// unchanged) — used both here and by `attachFile`, whenever a
    /// fingerprint mismatch between two machines' tagging of the same
    /// song needs to be locked in as a match going forward.
    private func applyCatalogMetadataOverride(title: String, artist: String, album: String, track: Track) async {
        try? await ratingStore.setOverrides(
            MetadataOverrides(
                title: title, artist: artist, album: album, genre: nil,
                year: track.year, trackNumber: track.trackNumber, discNumber: track.discNumber,
                bpm: track.bpm, key: track.key, comments: track.comments, tags: track.tags
            ),
            forPath: track.path
        )
    }

    private func applyCatalogMetadataOverride(_ metadata: iCloudSyncService.TrackMetadata, to track: Track) async {
        await applyCatalogMetadataOverride(title: metadata.title, artist: metadata.artist, album: metadata.album, track: track)
    }

    private func mergeScannedTracks(_ scanned: [Track]) {
        var byPath = Dictionary(uniqueKeysWithValues: tracks.map { ($0.path, $0) })
        for track in scanned { byPath[track.path] = track }
        tracks = byPath.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    // MARK: - Placeholder tracks

    /// In-flight persistence Task per placeholder path, so a rapid
    /// sequence of edits to the same placeholder (e.g. `updateMetadata`
    /// immediately followed by `setRating`) writes to the database in the
    /// order the edits were made, not the order their unstructured Tasks
    /// happen to get scheduled. See `persistPlaceholder`.
    private var pendingPlaceholderWrites: [String: Task<Void, Never>] = [:]

    /// Loads every manually-entered placeholder track (see
    /// `Track.isPlaceholder`) and merges them in alongside whatever's been
    /// scanned from files — call once at launch, same as
    /// `rescanAllFolders()`/`loadPlaylists()`.
    public func loadPlaceholderTracks() async {
        let stored = (try? await ratingStore.allPlaceholderTracks()) ?? []
        let placeholders: [Track] = stored.map { data in
            var track = Track(
                path: data.path,
                title: data.title,
                artist: data.artist,
                album: data.album,
                genre: data.genre,
                duration: data.duration,
                year: data.year,
                trackNumber: data.trackNumber,
                discNumber: data.discNumber,
                bpm: data.bpm,
                key: data.key,
                comments: data.comments,
                rating: data.rating,
                tags: data.tags,
                playCount: data.playCount
            )
            track.isHidden = data.isHidden
            track.isPlaceholder = true
            return track
        }
        mergeScannedTracks(placeholders)
    }

    /// Creates a new placeholder (file-less) track — for rating a song
    /// from an album you've heard but don't actually have a copy of, so it
    /// still counts toward that album's average. Pre-fills artist/genre
    /// from another track already in `album`, since those usually apply
    /// across the whole thing; title is left blank for the caller to fill
    /// in via the edit sheet.
    ///
    /// Deliberately does *not* persist to disk yet — it only exists
    /// in-memory until the caller's edit sheet actually saves (the normal
    /// save path already persists placeholders, see `persistPlaceholder`),
    /// so an abandoned "Add Track" that's immediately cancelled doesn't
    /// leave a stray empty row behind. Returns the new track so the caller
    /// can open it straight into that sheet.
    public func createPlaceholderTrack(album: String) -> Track {
        let reference = tracks.first(where: { $0.album == album })
        var track = Track(
            path: "placeholder://\(UUID().uuidString)",
            title: "",
            artist: reference?.artist ?? "",
            album: album,
            genre: reference?.genre ?? "",
            duration: 0
        )
        track.isPlaceholder = true
        tracks.append(track)
        tracks.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return track
    }

    /// Permanently removes a placeholder track (as opposed to hiding it,
    /// which still keeps it around). No-op for a real, file-backed track.
    public func deletePlaceholderTrack(_ track: Track) {
        guard track.isPlaceholder else { return }
        tracks.removeAll { $0.path == track.path }
        let path = track.path
        let previous = pendingPlaceholderWrites[path]
        pendingPlaceholderWrites[path] = Task {
            _ = await previous?.value
            try? await ratingStore.deletePlaceholderTrack(path: path)
        }
    }

    /// Removes a track from the library entirely — unlike "Hide," which
    /// just excludes it from browsing while keeping it around (and still
    /// counting toward its album's rating), this is meant to be closer to
    /// gone. The audio file itself is never touched: for a placeholder
    /// this is the same as `deletePlaceholderTrack`; for a real,
    /// file-backed track, the path is remembered as excluded so a later
    /// rescan — which would otherwise just find the file again — doesn't
    /// bring it back.
    public func deleteTrack(_ track: Track) {
        if track.isPlaceholder {
            deletePlaceholderTrack(track)
            return
        }
        tracks.removeAll { $0.path == track.path }
        let path = track.path
        Task {
            try? await ratingStore.excludePath(path)
        }
    }

    // MARK: - Learn Song

    public func loadLearnSession(for track: Track) async -> LearnSessionData? {
        try? await ratingStore.learnSession(forTrackPath: track.path)
    }

    public func saveLearnSession(_ data: LearnSessionData, for track: Track) {
        let path = track.path
        Task {
            try? await ratingStore.saveLearnSession(data, forTrackPath: path)
        }
    }

    /// Points a track at a different file on disk — e.g. swapping in a
    /// better-quality rip of the same song — without losing the rating,
    /// tags, artwork override, or playlist membership already accumulated
    /// under its old path. Re-scans `newURL` fresh (so title/artist/etc.
    /// reflect the new file's own tags) and carries every locally-stored
    /// override on top of that, same as any other scan. Returns the
    /// updated track, or `nil` if the new file couldn't be read or the
    /// original track is no longer in the library.
    public func replaceFile(for track: Track, withNewFile newURL: URL) async -> Track? {
        guard let index = tracks.firstIndex(where: { $0.path == track.path }) else { return nil }
        let oldPath = track.path

        guard let rawTrack = await LibraryScanner.scanFiles([newURL]).first else { return nil }
        try? await ratingStore.reassignPath(from: oldPath, to: rawTrack.path)
        guard let newTrack = await applyStoredRatings(to: [rawTrack]).first else { return nil }

        tracks[index] = newTrack

        // If the old file was tracked individually (see
        // `additionalTrackPaths`) rather than via a whole scanned folder,
        // swap it for the new path — otherwise the new file would never
        // be remembered for next launch, and the old (still-on-disk, just
        // no longer referenced) file would linger and get re-added as a
        // stale duplicate on the next rescan.
        if let additionalIndex = additionalTrackPaths.firstIndex(of: oldPath) {
            additionalTrackPaths[additionalIndex] = newTrack.path
            persistAdditionalTrackPaths()
        }

        for playlistIndex in playlists.indices {
            guard let trackIndex = playlists[playlistIndex].trackPaths.firstIndex(of: oldPath) else { continue }
            playlists[playlistIndex].trackPaths[trackIndex] = newTrack.path
            persist(playlists[playlistIndex])
        }

        await ArtworkLoader.shared.invalidate(path: oldPath)
        await ArtworkLoader.shared.invalidate(path: newTrack.path)
        artworkVersion += 1

        return newTrack
    }

    /// Attaches a real audio file to a placeholder track (see
    /// `Track.isPlaceholder`) — for a manually-created placeholder you've
    /// finally obtained the file for, or a synced placeholder (see
    /// `iCloudSyncService.syncedPlaceholderPathPrefix`) representing a
    /// track another machine has catalogued that this machine turns out
    /// to already have a file for, without waiting for a folder rescan or
    /// "Import Known Tracks" to discover it.
    ///
    /// Carries the placeholder's rating/tags onto the new real track
    /// (everything else — title/artist/album/genre — comes from the
    /// file's own tags, same as any other scan) and removes the
    /// placeholder row. This never touches any *other* machine's data:
    /// each machine keeps its own file at its own local path, and sync
    /// only ever merges fingerprint-keyed rating/playCount/metadata — so
    /// attaching a file here can't cause another machine to lose its own
    /// attached copy. What it *can* do is orphan the promotion itself: if
    /// the picked file's own tags don't reasonably match what the
    /// placeholder represents, it won't share the placeholder's
    /// `syncFingerprint` going forward, and the two will sync as
    /// separate, unrelated tracks instead of one promoted one — the same
    /// risk `replaceFile` already carries for a mismatched swap.
    public func attachFile(to placeholder: Track, fileURL: URL) async -> Track? {
        guard placeholder.isPlaceholder, tracks.contains(where: { $0.path == placeholder.path }) else { return nil }

        guard let rawTrack = await LibraryScanner.scanFiles([fileURL]).first else { return nil }
        try? await ratingStore.setRating(placeholder.rating, forPath: rawTrack.path)
        // Always overrides title/artist/album to match the placeholder
        // exactly — not conditional on how close the file's own tags
        // already are, since choosing to attach this specific file to
        // this specific placeholder *is* the confirmation that it's the
        // same song. This guarantees the new track's fingerprint matches
        // the placeholder's going forward, the same convergence
        // `importKnownTracks` reaches for a fuzzy match (see
        // `applyCatalogMetadataOverride`), just driven by an explicit
        // user action here instead of a duration/text heuristic.
        try? await ratingStore.setOverrides(
            MetadataOverrides(
                title: placeholder.title, artist: placeholder.artist, album: placeholder.album, genre: nil,
                year: rawTrack.year, trackNumber: rawTrack.trackNumber, discNumber: rawTrack.discNumber,
                bpm: rawTrack.bpm, key: rawTrack.key, comments: rawTrack.comments, tags: placeholder.tags
            ),
            forPath: rawTrack.path
        )
        // `applyStoredRatings` already reads the override just written
        // above, so `newTrack.title`/`.artist`/`.album` reflect the
        // placeholder's exact wording without needing to set them again
        // here.
        guard let newTrack = await applyStoredRatings(to: [rawTrack]).first else { return nil }

        let oldPath = placeholder.path
        tracks.removeAll { $0.path == oldPath }
        mergeScannedTracks([newTrack])
        // Otherwise this newly-attached file would vanish on the next
        // relaunch, same as any other individually-added file — see
        // `additionalTrackPaths`.
        rememberAdditionalTrackPaths([newTrack.path])
        try? await ratingStore.deletePlaceholderTrack(path: oldPath)

        for playlistIndex in playlists.indices {
            guard let trackIndex = playlists[playlistIndex].trackPaths.firstIndex(of: oldPath) else { continue }
            playlists[playlistIndex].trackPaths[trackIndex] = newTrack.path
            persist(playlists[playlistIndex])
        }

        await ArtworkLoader.shared.invalidate(path: newTrack.path)
        artworkVersion += 1

        return newTrack
    }

    /// Re-scans every previously added folder from scratch (picks up files
    /// that were added, removed, or retagged since last launch).
    public func rescanAllFolders() async {
        guard !scannedFolderPaths.isEmpty || !additionalTrackPaths.isEmpty else { return }

        var combined: [Track] = []
        for path in scannedFolderPaths {
            combined.append(contentsOf: await scanWithStoredRatings(rootURL: URL(fileURLWithPath: path)))
        }

        // Files remembered individually (see `additionalTrackPaths`) rather
        // than via a whole folder — re-verify each still exists first,
        // since `LibraryScanner.scanFiles` doesn't skip a missing file the
        // way walking a folder naturally would, and drop any that don't
        // so a deleted/moved file doesn't linger here forever.
        let stillPresent = additionalTrackPaths.filter { FileManager.default.fileExists(atPath: $0) }
        if stillPresent.count != additionalTrackPaths.count {
            additionalTrackPaths = stillPresent
            persistAdditionalTrackPaths()
        }
        if !stillPresent.isEmpty {
            isScanning = true
            scanProgress = (0, 0)
            let rescanned = await applyStoredRatings(
                to: await LibraryScanner.scanFiles(stillPresent.map { URL(fileURLWithPath: $0) }) { [weak self] completed, total in
                    Task { @MainActor in self?.scanProgress = (completed, total) }
                }
            )
            isScanning = false
            scanProgress = nil
            combined.append(contentsOf: rescanned)
        }

        guard !combined.isEmpty else { return }
        var byPath: [String: Track] = [:]
        for track in combined { byPath[track.path] = track }
        tracks = byPath.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Scans one folder and applies any locally-stored ratings/tags/overrides
    /// to the results. Drives `isScanning`/`scanProgress` for the duration.
    private func scanWithStoredRatings(rootURL: URL) async -> [Track] {
        isScanning = true
        scanProgress = (0, 0)

        let scanned = await applyStoredRatings(
            to: await LibraryScanner.scan(rootURL: rootURL) { [weak self] completed, total in
                Task { @MainActor in
                    self?.scanProgress = (completed, total)
                }
            }
        )

        isScanning = false
        scanProgress = nil
        return scanned
    }

    /// Applies any locally-stored ratings/tags/overrides on top of a fresh
    /// scan's results — shared by folder scans and individual-file imports.
    private func applyStoredRatings(to scanned: [Track]) async -> [Track] {
        // Deleted tracks (see deleteTrack(_:)) must not come back just
        // because the file is still on disk and a rescan finds it again —
        // that's the whole difference between "Delete" and "Hide."
        let excluded = (try? await ratingStore.excludedPaths()) ?? []
        var scanned = excluded.isEmpty ? scanned : scanned.filter { !excluded.contains($0.path) }

        let savedRatings = (try? await ratingStore.allRatings()) ?? [:]
        for index in scanned.indices {
            guard let saved = savedRatings[scanned[index].path] else { continue }
            scanned[index].rating = saved.rating
            scanned[index].tags = saved.tags
            scanned[index].playCount = saved.playCount
            scanned[index].isHidden = saved.isHidden
            if let title = saved.titleOverride, !title.isEmpty { scanned[index].title = title }
            if let artist = saved.artistOverride, !artist.isEmpty { scanned[index].artist = artist }
            if let album = saved.albumOverride, !album.isEmpty { scanned[index].album = album }
            if let genre = saved.genreOverride, !genre.isEmpty { scanned[index].genre = genre }
            if let year = saved.yearOverride { scanned[index].year = year }
            if let trackNumber = saved.trackNumberOverride { scanned[index].trackNumber = trackNumber }
            if let discNumber = saved.discNumberOverride { scanned[index].discNumber = discNumber }
            if let bpm = saved.bpmOverride { scanned[index].bpm = bpm }
            if let key = saved.keyOverride, !key.isEmpty { scanned[index].key = key }
            if let comments = saved.commentsOverride, !comments.isEmpty { scanned[index].comments = comments }
        }
        return scanned
    }

    /// Re-applies whatever's currently in the store onto the *existing*
    /// in-memory `tracks` — same per-field merge as `applyStoredRatings`,
    /// but refreshing tracks already loaded rather than a freshly-scanned
    /// batch. Used after `syncWithiCloud()` writes merged ratings/play
    /// counts to the store, so the UI reflects them without a full rescan.
    private func refreshRatingsFromStore() async {
        let savedRatings = (try? await ratingStore.allRatings()) ?? [:]
        for index in tracks.indices {
            guard let saved = savedRatings[tracks[index].path] else { continue }
            tracks[index].rating = saved.rating
            tracks[index].playCount = saved.playCount
        }
    }

    /// Surfaced in the toolbar (see `ContentView`'s sync status item) —
    /// added after a real debugging session where two machines synced
    /// within the same minute raced each other (the second one read the
    /// first one's update before iCloud had propagated it, then silently
    /// overwrote it) with zero visible indication anything had gone
    /// sideways. Not a guarantee every partial failure is caught —
    /// `syncPlaylists` below still uses `try?` internally — but covers
    /// the main case: whether the primary track/ratings sync itself
    /// actually reached iCloud Drive.
    public enum SyncStatus: Equatable, Sendable {
        case neverSynced
        case syncing
        case succeeded(Date)
        case failed(Date)
    }

    @Published public private(set) var syncStatus: SyncStatus = .neverSynced

    /// Merges ratings/play counts and the track/playlist catalog with
    /// whatever another machine last synced via iCloud Drive (see
    /// `iCloudSyncService`), then refreshes `tracks`/`playlists` to
    /// reflect anything that changed. A no-op (throws, caught here) if
    /// iCloud Drive isn't available on this Mac — sync is opt-in by
    /// having iCloud Drive enabled at all, not a hard requirement to use
    /// the app. `fileURL` exists only for tests to point at a scratch
    /// snapshot instead of the real iCloud Drive location.
    @discardableResult
    public func syncWithiCloud(fileURL: URL? = nil) async -> iCloudSyncService.SyncResult? {
        syncStatus = .syncing
        guard let result = try? await iCloudSyncService.sync(tracks: tracks, store: ratingStore, fileURL: fileURL) else {
            syncStatus = .failed(Date())
            return nil
        }
        if result.pathsUpdatedLocally > 0 {
            await refreshRatingsFromStore()
        }
        // Must happen before playlist sync below — a playlist's track
        // fingerprints can only resolve to *something* locally (a real
        // track or a placeholder) once this machine's placeholders are
        // caught up with the merged catalog.
        await reconcileSyncedPlaceholders()

        let excludedPlaylistIDs = (try? await playlistStore.excludedPlaylistIDs()) ?? []
        try? await iCloudSyncService.syncPlaylists(
            playlists: playlists, tracks: tracks, store: playlistStore,
            excludedPlaylistIDs: excludedPlaylistIDs, fileURL: fileURL
        )
        await loadPlaylists()

        syncStatus = .succeeded(Date())
        return result
    }

    /// Drops any synced placeholder (see
    /// `iCloudSyncService.syncedPlaceholderPathPrefix`) from memory before
    /// reloading — `sync(...)` just reconciled the *store* (created ones
    /// for newly-known fingerprints, removed ones a real local file now
    /// covers), but `tracks` hasn't caught up yet, and `loadPlaceholderTracks`
    /// only ever merges in what's currently stored, never removes what
    /// isn't anymore.
    private func reconcileSyncedPlaceholders() async {
        tracks.removeAll { $0.path.hasPrefix(iCloudSyncService.syncedPlaceholderPathPrefix) }
        await loadPlaceholderTracks()
    }

    private static func loadScannedFolderPaths() -> [String] {
        guard let raw = UserDefaults.standard.string(forKey: scannedFoldersKey), !raw.isEmpty else { return [] }
        return raw.components(separatedBy: "\n")
    }

    private func persistScannedFolderPaths() {
        UserDefaults.standard.set(scannedFolderPaths.joined(separator: "\n"), forKey: Self.scannedFoldersKey)
    }

    public func loadPlaylists() async {
        let loaded = (try? await playlistStore.allPlaylists()) ?? []
        playlists = loaded.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Ratings / tags / plays

    public func setRating(_ rating: Int, for track: Track) {
        guard let index = tracks.firstIndex(where: { $0.path == track.path }) else { return }
        let clamped = max(0, min(11, rating))
        tracks[index].rating = clamped
        if tracks[index].isPlaceholder {
            persistPlaceholder(tracks[index])
        } else {
            Task {
                try? await ratingStore.setRating(clamped, forPath: track.path)
            }
        }
    }

    /// Placeholder tracks (see `Track.isPlaceholder`) have no scanned file
    /// to layer an override on top of — everything about one lives in this
    /// single row, so any edit just re-saves the whole current snapshot.
    ///
    /// Chained onto `pendingPlaceholderWrites` (keyed by path) rather than
    /// fired as an independent `Task`: two edits in quick succession (e.g.
    /// `updateMetadata` immediately followed by `setRating`) each snapshot
    /// `track` synchronously, but their unstructured Tasks have no
    /// guaranteed order of *execution* — without chaining, the earlier
    /// edit's write could reach the database after the later one's and
    /// silently clobber it with stale data.
    private func persistPlaceholder(_ track: Track) {
        let data = PlaceholderTrackData(
            path: track.path,
            title: track.title,
            artist: track.artist,
            album: track.album,
            genre: track.genre,
            year: track.year,
            trackNumber: track.trackNumber,
            discNumber: track.discNumber,
            bpm: track.bpm,
            key: track.key,
            comments: track.comments,
            rating: track.rating,
            tags: track.tags,
            isHidden: track.isHidden
        )
        let path = track.path
        let previous = pendingPlaceholderWrites[path]
        pendingPlaceholderWrites[path] = Task {
            _ = await previous?.value
            try? await ratingStore.savePlaceholderTrack(data)
        }
    }

    /// Adds to a track's play count. `fraction` is "how many full listens
    /// worth" of real playing time just happened — not capped at 1, since
    /// rewinding to replay a passage within one sitting can genuinely add
    /// up to more than the track's own duration.
    public func recordPartialPlay(_ fraction: Double, for track: Track) {
        Task {
            await recordPartialPlayAndWait(fraction, for: track)
        }
    }

    /// Same as `recordPartialPlay`, but awaits the underlying store write
    /// completing instead of firing an unstructured `Task` — used at app
    /// termination, where the process can exit before a fire-and-forget
    /// write reaches disk.
    public func recordPartialPlayAndWait(_ fraction: Double, for track: Track) async {
        let clamped = max(0, fraction)
        guard clamped > 0 else { return }
        guard let index = tracks.firstIndex(where: { $0.path == track.path }) else { return }
        tracks[index].playCount += clamped
        try? await ratingStore.addPartialPlay(clamped, forPath: track.path)
    }

    /// Saves local overrides for every field the "Edit Info" sheet exposes
    /// (everything except play count, which is derived, not editable).
    /// Pass an empty string / nil for any field to clear its override and
    /// fall back to the value originally read from the file.
    public func updateMetadata(
        for track: Track,
        title: String,
        artist: String,
        album: String,
        genre: String,
        year: Int?,
        trackNumber: Int?,
        discNumber: Int?,
        bpm: Int?,
        key: String,
        comments: String,
        tags: [String]
    ) {
        guard let index = tracks.firstIndex(where: { $0.path == track.path }) else { return }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedGenre = genre.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedComments = comments.trimmingCharacters(in: .whitespacesAndNewlines)

        tracks[index].title = trimmedTitle.isEmpty ? tracks[index].originalTitle : trimmedTitle
        tracks[index].artist = trimmedArtist.isEmpty ? tracks[index].originalArtist : trimmedArtist
        tracks[index].album = trimmedAlbum.isEmpty ? tracks[index].originalAlbum : trimmedAlbum
        tracks[index].genre = trimmedGenre.isEmpty ? tracks[index].originalGenre : trimmedGenre
        tracks[index].year = year ?? tracks[index].originalYear
        tracks[index].trackNumber = trackNumber ?? tracks[index].originalTrackNumber
        tracks[index].discNumber = discNumber ?? tracks[index].originalDiscNumber
        tracks[index].bpm = bpm ?? tracks[index].originalBpm
        tracks[index].key = trimmedKey.isEmpty ? tracks[index].originalKey : trimmedKey
        tracks[index].comments = trimmedComments.isEmpty ? tracks[index].originalComments : trimmedComments
        tracks[index].tags = tags

        if tracks[index].isPlaceholder {
            persistPlaceholder(tracks[index])
            return
        }

        let overrides = MetadataOverrides(
            title: trimmedTitle.isEmpty ? nil : trimmedTitle,
            artist: trimmedArtist.isEmpty ? nil : trimmedArtist,
            album: trimmedAlbum.isEmpty ? nil : trimmedAlbum,
            genre: trimmedGenre.isEmpty ? nil : trimmedGenre,
            year: year,
            trackNumber: trackNumber,
            discNumber: discNumber,
            bpm: bpm,
            key: trimmedKey.isEmpty ? nil : trimmedKey,
            comments: trimmedComments.isEmpty ? nil : trimmedComments,
            tags: tags
        )
        Task {
            try? await ratingStore.setOverrides(overrides, forPath: track.path)
        }
    }

    /// Batch variant of `updateMetadata`: applied across several tracks at
    /// once. Unlike single-track editing, a blank field here means "leave
    /// each track's existing value alone" — not "reset to file value" —
    /// since there's no single original to reset to across a batch. Tags
    /// are merged into each track's existing tags rather than replacing them.
    public func batchUpdateMetadata(
        for batchTracks: [Track],
        title: String,
        artist: String,
        album: String,
        genre: String,
        year: Int?,
        trackNumber: Int?,
        discNumber: Int?,
        bpm: Int?,
        key: String,
        comments: String,
        addTags: [String]
    ) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedGenre = genre.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedComments = comments.trimmingCharacters(in: .whitespacesAndNewlines)

        for batchTrack in batchTracks {
            guard let index = tracks.firstIndex(where: { $0.path == batchTrack.path }) else { continue }

            if !trimmedTitle.isEmpty { tracks[index].title = trimmedTitle }
            if !trimmedArtist.isEmpty { tracks[index].artist = trimmedArtist }
            if !trimmedAlbum.isEmpty { tracks[index].album = trimmedAlbum }
            if !trimmedGenre.isEmpty { tracks[index].genre = trimmedGenre }
            if let year { tracks[index].year = year }
            if let trackNumber { tracks[index].trackNumber = trackNumber }
            if let discNumber { tracks[index].discNumber = discNumber }
            if let bpm { tracks[index].bpm = bpm }
            if !trimmedKey.isEmpty { tracks[index].key = trimmedKey }
            if !trimmedComments.isEmpty { tracks[index].comments = trimmedComments }
            if !addTags.isEmpty {
                tracks[index].tags = Array(Set(tracks[index].tags).union(addTags)).sorted()
            }

            if tracks[index].isPlaceholder {
                persistPlaceholder(tracks[index])
                continue
            }

            let updated = tracks[index]
            let overrides = MetadataOverrides(
                title: updated.title == updated.originalTitle ? nil : updated.title,
                artist: updated.artist == updated.originalArtist ? nil : updated.artist,
                album: updated.album == updated.originalAlbum ? nil : updated.album,
                genre: updated.genre == updated.originalGenre ? nil : updated.genre,
                year: updated.year == updated.originalYear ? nil : updated.year,
                trackNumber: updated.trackNumber == updated.originalTrackNumber ? nil : updated.trackNumber,
                discNumber: updated.discNumber == updated.originalDiscNumber ? nil : updated.discNumber,
                bpm: updated.bpm == updated.originalBpm ? nil : updated.bpm,
                key: updated.key == updated.originalKey ? nil : updated.key,
                comments: updated.comments == updated.originalComments ? nil : updated.comments,
                tags: updated.tags
            )
            let path = updated.path
            Task {
                try? await ratingStore.setOverrides(overrides, forPath: path)
            }
        }
    }

    // MARK: - Hidden tracks

    public func setHidden(_ hidden: Bool, for track: Track) {
        guard let index = tracks.firstIndex(where: { $0.path == track.path }) else { return }
        tracks[index].isHidden = hidden
        if tracks[index].isPlaceholder {
            persistPlaceholder(tracks[index])
        } else {
            let path = track.path
            Task {
                try? await ratingStore.setHidden(hidden, forPath: path)
            }
        }
    }

    public func setHidden(_ hidden: Bool, for batchTracks: [Track]) {
        for track in batchTracks {
            setHidden(hidden, for: track)
        }
    }

    public func unhideAllTracks(inAlbum album: String) {
        let hiddenInAlbum = tracks.filter { $0.album == album && $0.isHidden }
        setHidden(false, for: hiddenInAlbum)
    }

    // MARK: - Artwork

    /// Bumped whenever any track's artwork override changes, so views that
    /// don't otherwise re-render (their track's `path` hasn't changed, just
    /// what image that path resolves to) know to reload — see `ArtworkView`.
    @Published public private(set) var artworkVersion = 0

    /// Replaces (or, with `nil`, clears back to embedded) the locally-shown
    /// cover art for one or more tracks. Like every other edit in this app,
    /// this never touches the audio file itself.
    public func setArtworkOverride(_ imageData: Data?, for batchTracks: [Track]) {
        Task {
            for track in batchTracks {
                try? await ratingStore.setArtworkOverride(imageData, forPath: track.path)
                await ArtworkLoader.shared.invalidate(path: track.path)
            }
            artworkVersion += 1
        }
    }

    // MARK: - Columns

    public func toggleColumn(_ column: TrackColumn) {
        if visibleColumns.contains(column) {
            visibleColumns.remove(column)
        } else {
            visibleColumns.insert(column)
        }
    }

    private static func loadVisibleColumns() -> Set<TrackColumn> {
        guard let raw = UserDefaults.standard.string(forKey: visibleColumnsKey) else {
            // Show everything by default — easier to hide a column you
            // don't want via the toolbar's Columns menu than to discover
            // one you didn't know existed.
            return Set(TrackColumn.allCases)
        }
        return Set(raw.split(separator: ",").compactMap { TrackColumn(rawValue: String($0)) })
    }

    private func persistVisibleColumns() {
        UserDefaults.standard.set(visibleColumns.map(\.rawValue).joined(separator: ","), forKey: Self.visibleColumnsKey)
    }

    /// Every column that should actually render, in the user's chosen
    /// display order — Title/Artist/Album are always included regardless
    /// of `visibleColumns`.
    public var orderedVisibleColumns: [TrackColumn] {
        columnOrder.filter { $0.isAlwaysVisible || visibleColumns.contains($0) }
    }

    public func moveColumn(from source: IndexSet, to destination: Int) {
        columnOrder.move(fromOffsets: source, toOffset: destination)
        persistColumnOrder()
    }

    private static func loadColumnOrder() -> [TrackColumn] {
        guard let raw = UserDefaults.standard.string(forKey: columnOrderKey), !raw.isEmpty else {
            return TrackColumn.allCases
        }
        let saved = raw.split(separator: ",").compactMap { TrackColumn(rawValue: String($0)) }
        // Guard against a stale saved order missing a case added since —
        // put newly-added always-visible columns back at the front (that's
        // where Title/Artist/Album belong by default) and any other new
        // optional column at the end.
        let missing = TrackColumn.allCases.filter { !saved.contains($0) }
        let missingAlwaysVisible = missing.filter(\.isAlwaysVisible)
        let missingOptional = missing.filter { !$0.isAlwaysVisible }
        return missingAlwaysVisible + saved + missingOptional
    }

    private func persistColumnOrder() {
        UserDefaults.standard.set(columnOrder.map(\.rawValue).joined(separator: ","), forKey: Self.columnOrderKey)
    }

    // MARK: - Playlists

    public func createPlaylist(name: String) {
        let playlist = Playlist(name: name)
        playlists.append(playlist)
        persist(playlist)
    }

    public func createSmartPlaylist(name: String, rules: [SmartRule], matchAll: Bool) {
        let playlist = Playlist(name: name, isSmart: true, smartMatchAll: matchAll, smartRules: rules)
        playlists.append(playlist)
        persist(playlist)
    }

    public func updateSmartPlaylist(_ id: UUID, name: String, rules: [SmartRule], matchAll: Bool) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].name = name
        playlists[index].smartRules = rules
        playlists[index].smartMatchAll = matchAll
        persist(playlists[index])
    }

    public func renamePlaylist(_ id: UUID, to newName: String) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].name = newName
        persist(playlists[index])
    }

    public func deletePlaylist(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        if selectedPlaylistID == id { selectedPlaylistID = nil }
        Task {
            try? await playlistStore.deletePlaylist(id: id)
            // Also recorded locally (mirrors `excludedPaths` for tracks)
            // so this machine's own next sync doesn't resurrect it from
            // the shared catalog before the deletion has any chance to
            // happen on the other machine too — see
            // `iCloudSyncService.syncPlaylists`'s doc comment on why
            // deletion isn't otherwise propagated.
            try? await playlistStore.excludePlaylist(id: id)
        }
    }

    public func addTrack(_ track: Track, toPlaylistID id: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == id }), !playlists[index].isSmart else { return }
        guard !playlists[index].trackPaths.contains(track.path) else { return }
        playlists[index].trackPaths.append(track.path)
        persist(playlists[index])
    }

    public func removeTrack(_ track: Track, fromPlaylistID id: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].trackPaths.removeAll { $0 == track.path }
        persist(playlists[index])
    }

    public func moveTracks(inPlaylistID id: UUID, from offsets: IndexSet, to destination: Int) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].trackPaths.move(fromOffsets: offsets, toOffset: destination)
        persist(playlists[index])
    }

    /// Every playlist mutation above funnels through here, so stamping
    /// `updatedAt` in this one place (rather than at each call site)
    /// covers all of them — needed for cross-machine last-write-wins (see
    /// `iCloudSyncService.syncPlaylists`). Written back into `playlists`
    /// too, not just the store, so the in-memory copy the *next*
    /// `syncWithiCloud()` call reads already reflects it.
    private func persist(_ playlist: Playlist) {
        var stamped = playlist
        stamped.updatedAt = Date()
        if let index = playlists.firstIndex(where: { $0.id == stamped.id }) {
            playlists[index] = stamped
        }
        Task { try? await playlistStore.savePlaylist(stamped) }
    }
}
