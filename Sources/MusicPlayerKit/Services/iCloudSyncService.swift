import Foundation

/// Syncs ratings and play counts across machines via a small JSON file in
/// iCloud Drive — never the audio files themselves, which stay exactly
/// where they are on each machine.
///
/// Two Macs each scanning their own local copy of a library can't share
/// `Track.path` as an identity (their folder layouts differ), so this
/// keys everything by `Track.syncFingerprint` (normalized title/artist/
/// album/duration) instead.
///
/// Deliberately uses the plain, visible "iCloud Drive" folder
/// (`~/Library/Mobile Documents/com~apple~CloudDocs/`) rather than an
/// app-specific ubiquity container (`FileManager.url(forUbiquityContainerIdentifier:)`)
/// — the latter requires an iCloud entitlement tied to a paid Apple
/// Developer Program membership and a provisioning profile, neither of
/// which this self-signed, non-App-Store app has. Treating iCloud Drive
/// as "just a folder that happens to sync," the same way Dropbox would
/// work, needs no special entitlement at all — only that the user has
/// iCloud Drive enabled, same as for any other file they'd drag in there.
public enum iCloudSyncService {
    /// Enough of a track's own metadata to reconstruct a placeholder on a
    /// machine with no local file for its fingerprint — see
    /// `syncedPlaceholderPathPrefix`. Not itself part of any last-write-
    /// wins merge: it's only ever consulted for a fingerprint this machine
    /// has *no* local file for, so whichever machine actually has the file
    /// is the only one whose copy of these fields is ever shown, making
    /// conflicting edits on two machines that both have the file moot.
    public struct TrackMetadata: Codable, Sendable, Equatable {
        public var title: String
        public var artist: String
        public var album: String
        public var genre: String
        public var duration: TimeInterval
        public var year: Int?
        public var trackNumber: Int?
        public var discNumber: Int?
        public var bpm: Int?
        public var key: String?
        public var comments: String?
        public var tags: [String]
    }

    public struct SnapshotEntry: Codable, Sendable, Equatable {
        public var rating: Int
        public var ratedAt: Date?
        public var playCount: Double
        /// `nil` for entries written before this existed — that
        /// fingerprint's owning machine backfills it automatically next
        /// time it syncs.
        public var metadata: TrackMetadata?
    }

    /// A playlist synced across machines by fingerprint (see
    /// `Track.syncFingerprint`) rather than `Playlist.trackPaths`' local
    /// paths, which mean nothing on another machine. Smart playlists carry
    /// no fingerprints at all — `smartRules` already match on track
    /// fields, portable as-is.
    public struct SyncedPlaylist: Codable, Sendable, Equatable {
        public var name: String
        public var isSmart: Bool
        public var smartMatchAll: Bool
        public var smartRules: [SmartRule]
        public var trackFingerprints: [String]
        public var updatedAt: Date?
    }

    public struct Snapshot: Codable, Sendable {
        public var entries: [String: SnapshotEntry]
        /// Keyed by `Playlist.id.uuidString`.
        public var playlists: [String: SyncedPlaylist]
        public var updatedAt: Date

        public init(entries: [String: SnapshotEntry] = [:], playlists: [String: SyncedPlaylist] = [:], updatedAt: Date = Date()) {
            self.entries = entries
            self.playlists = playlists
            self.updatedAt = updatedAt
        }

        private enum CodingKeys: String, CodingKey {
            case entries, playlists, updatedAt
        }

        /// Manual decode (rather than relying on synthesized `Decodable`)
        /// so a file written before `playlists` existed — this user
        /// already has one with hundreds of real entries — still decodes
        /// successfully instead of `readSnapshot` falling back to an
        /// empty `Snapshot()`, which would look like "no remote data at
        /// all" and, on the next write, drop every fingerprint this
        /// machine doesn't have locally.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            entries = try container.decodeIfPresent([String: SnapshotEntry].self, forKey: .entries) ?? [:]
            playlists = try container.decodeIfPresent([String: SyncedPlaylist].self, forKey: .playlists) ?? [:]
            updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        }
    }

    public struct SyncResult: Sendable {
        public var pathsUpdatedLocally: Int
        public var wroteRemoteSnapshot: Bool
    }

    public enum SyncError: Error {
        case iCloudDriveUnavailable
    }

    /// Synthetic path prefix for a placeholder `sync(...)` itself creates
    /// to represent a fingerprint this machine has no local file for —
    /// `"placeholder://synced/<fingerprint>"`. Deterministic per
    /// fingerprint (so re-syncing updates the same row rather than
    /// duplicating it) and distinguishable by prefix from a user-created
    /// placeholder's `"placeholder://<uuid>"`, without needing a separate
    /// field on `Track`/`PlaceholderTrackData`.
    public static let syncedPlaceholderPathPrefix = "placeholder://synced/"

    private static var iCloudDriveRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    private static var syncDirectoryURL: URL {
        iCloudDriveRoot.appendingPathComponent("MusicPlayerSync", isDirectory: true)
    }

    public static var syncFileURL: URL {
        syncDirectoryURL.appendingPathComponent("sync.json", isDirectory: false)
    }

    /// `false` if iCloud Drive isn't enabled/available on this Mac —
    /// distinguished from "available but the sync file doesn't exist yet"
    /// (a brand-new sync, which is fine and just starts from empty).
    public static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: iCloudDriveRoot.path)
    }

    /// Fingerprints of every track known from the iCloud ratings/plays
    /// snapshot — i.e. catalogued in the library on this machine or any
    /// other that's synced. Read-only: doesn't merge state or write
    /// anything back, just inspects whatever the last sync wrote. Used to
    /// auto-match a second machine's local files against what's already
    /// been curated elsewhere, without moving any audio between machines.
    public static func knownFingerprints(fileURL: URL? = nil) -> Set<String> {
        Set(readSnapshot(at: fileURL ?? syncFileURL).entries.keys)
    }

    /// Reads whatever the other machine(s) last wrote, merges it with
    /// `tracks`' current local state, writes any locally-changed ratings/
    /// play counts back through `store`, and uploads the merged result so
    /// the next machine to sync sees it. Safe to call even if nothing has
    /// ever been rated/played (writes an empty-ish snapshot) or if this is
    /// the very first sync on either machine (no remote file yet).
    /// `fileURL` defaults to the real shared iCloud Drive location — only
    /// overridden by tests, to exercise the merge logic against a scratch
    /// file instead of the real one.
    @discardableResult
    public static func sync(tracks: [Track], store: RatingStore, fileURL: URL? = nil) async throws -> SyncResult {
        let targetURL: URL
        if let fileURL {
            targetURL = fileURL
        } else {
            guard isAvailable else { throw SyncError.iCloudDriveUnavailable }
            targetURL = syncFileURL
        }

        try FileManager.default.createDirectory(
            at: targetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let remote = readSnapshot(at: targetURL)
        let localRatings = (try? await store.allRatings()) ?? [:]

        // A fingerprint can (rarely) map to more than one local path —
        // duplicate files of the same song. The merged result applies to
        // all of them; that's the right call either way, since they're
        // meant to represent "the same track" for sync purposes. Real
        // (non-placeholder, non-synced-placeholder) tracks only — a
        // synced placeholder is this fingerprint's *stand-in* for not
        // having a local file, not a local match for it.
        var pathsByFingerprint: [String: [String]] = [:]
        var representativeTrackByFingerprint: [String: Track] = [:]
        for track in tracks where !track.isPlaceholder {
            pathsByFingerprint[track.syncFingerprint, default: []].append(track.path)
            representativeTrackByFingerprint[track.syncFingerprint] = track
        }

        var mergedEntries: [String: SnapshotEntry] = [:]
        var updatedPathCount = 0

        for (fingerprint, paths) in pathsByFingerprint {
            // All paths sharing a fingerprint should already agree locally
            // (they're duplicates of the same song), so the first one's
            // stored rating stands in for the whole group.
            let local = paths.first.flatMap { localRatings[$0] }
            let remoteEntry = remote.entries[fingerprint]

            var merged = Self.merge(local: local, remote: remoteEntry)
            // This machine has a real file for this fingerprint, so its
            // metadata is authoritative — always overwrite whatever was
            // carried in the remote entry (which, if present, only ever
            // came from *some* machine's local file in the first place).
            if let track = representativeTrackByFingerprint[fingerprint] {
                merged.metadata = TrackMetadata(
                    title: track.title, artist: track.artist, album: track.album, genre: track.genre,
                    duration: track.duration, year: track.year, trackNumber: track.trackNumber,
                    discNumber: track.discNumber, bpm: track.bpm, key: track.key, comments: track.comments,
                    tags: track.tags
                )
            }
            mergedEntries[fingerprint] = merged

            for path in paths {
                let current = localRatings[path]
                if current?.rating != merged.rating {
                    try? await store.applySyncedRating(merged.rating, ratedAt: merged.ratedAt ?? Date(), forPath: path)
                    updatedPathCount += 1
                }
                if (current?.playCount ?? 0) != merged.playCount {
                    try? await store.setPlayCount(merged.playCount, forPath: path)
                }
            }
        }

        // Carries forward any remote entry whose fingerprint has no match
        // in *this* machine's current library (a track only the other
        // machine has scanned) — otherwise re-uploading would silently
        // drop it for everyone.
        for (fingerprint, entry) in remote.entries where mergedEntries[fingerprint] == nil {
            mergedEntries[fingerprint] = entry
        }

        await reconcilePlaceholders(mergedEntries: mergedEntries, localFingerprints: Set(pathsByFingerprint.keys), store: store)

        // `playlists` is carried forward untouched — this function knows
        // nothing about them (see `syncPlaylists`, a separate pass over
        // the same file) and must not stomp them on every plain track
        // sync, which runs far more often.
        let wrote = writeSnapshot(Snapshot(entries: mergedEntries, playlists: remote.playlists, updatedAt: Date()), to: targetURL)
        return SyncResult(pathsUpdatedLocally: updatedPathCount, wroteRemoteSnapshot: wrote)
    }

    /// Syncs playlists across machines by fingerprint — a separate,
    /// focused read-merge-write pass over the same file, meant to run
    /// right after `sync(...)` so it sees the just-written `entries`
    /// (needed to resolve fingerprints back to local paths). Regular
    /// playlists translate `trackPaths` to/from fingerprints; smart
    /// playlists sync as-is since their rules already match on track
    /// fields, not paths. Last-write-wins by `updatedAt`, whole record at
    /// a time — simple, matching a personal two-machine setup rather than
    /// a distributed system.
    ///
    /// Deletion is intentionally not propagated to the other machine:
    /// `excludedPlaylistIDs` only keeps *this* machine from resurrecting
    /// something it just deleted locally before its own next sync — it
    /// doesn't write a tombstone anyone else looks at. Delete a playlist
    /// on both machines if you want it gone everywhere.
    public static func syncPlaylists(
        playlists: [Playlist], tracks: [Track], store: PlaylistStore,
        excludedPlaylistIDs: Set<UUID>, fileURL: URL? = nil
    ) async throws {
        let targetURL: URL
        if let fileURL {
            targetURL = fileURL
        } else {
            guard isAvailable else { throw SyncError.iCloudDriveUnavailable }
            targetURL = syncFileURL
        }

        try FileManager.default.createDirectory(
            at: targetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var snapshot = readSnapshot(at: targetURL)

        var pathByFingerprint: [String: String] = [:]
        for track in tracks where !pathByFingerprint.keys.contains(track.syncFingerprint) {
            pathByFingerprint[track.syncFingerprint] = track.path
        }

        var merged = snapshot.playlists
        for playlist in playlists where !excludedPlaylistIDs.contains(playlist.id) {
            let synced = SyncedPlaylist(
                name: playlist.name, isSmart: playlist.isSmart, smartMatchAll: playlist.smartMatchAll,
                smartRules: playlist.smartRules,
                trackFingerprints: playlist.isSmart ? [] : playlist.trackPaths.compactMap { path in
                    tracks.first(where: { $0.path == path })?.syncFingerprint
                },
                updatedAt: playlist.updatedAt
            )
            merged[playlist.id.uuidString] = Self.mergePlaylist(local: synced, remote: merged[playlist.id.uuidString])
        }

        for (idString, synced) in merged {
            guard let id = UUID(uuidString: idString), !excludedPlaylistIDs.contains(id) else { continue }
            let resolvedPaths = synced.isSmart ? [] : synced.trackFingerprints.compactMap { pathByFingerprint[$0] }
            let resolved = Playlist(
                id: id, name: synced.name, isSmart: synced.isSmart, smartMatchAll: synced.smartMatchAll,
                smartRules: synced.smartRules, trackPaths: resolvedPaths, updatedAt: synced.updatedAt
            )
            try? await store.savePlaylist(resolved)
        }

        snapshot.playlists = merged
        writeSnapshot(snapshot, to: targetURL)
    }

    /// Whole-record last-write-wins by `updatedAt` — an untimestamped
    /// playlist (predates this feature, or just-created without ever
    /// syncing) loses to any timestamped counterpart, same tie-break
    /// philosophy as `merge(local:remote:)` for ratings.
    private static func mergePlaylist(local: SyncedPlaylist, remote: SyncedPlaylist?) -> SyncedPlaylist {
        guard let remote else { return local }
        switch (local.updatedAt, remote.updatedAt) {
        case let (l?, r?): return r > l ? remote : local
        case (nil, .some): return remote
        case (.some, nil): return local
        case (nil, nil): return local
        }
    }

    /// Keeps this machine's placeholder tracks (see
    /// `syncedPlaceholderPathPrefix`) in step with the merged catalog:
    /// creates/updates one for every fingerprint this machine has no real
    /// local file for (so it shows up grayed out instead of not at all),
    /// and removes one for any fingerprint that now *does* have a real
    /// local match — the real file "promotes" over it. No separate
    /// rating/play-count transfer needed for a promotion: the real file's
    /// path is already picked up by the merge loop above like any other.
    private static func reconcilePlaceholders(
        mergedEntries: [String: SnapshotEntry], localFingerprints: Set<String>, store: RatingStore
    ) async {
        let existingPlaceholders = (try? await store.allPlaceholderTracks()) ?? []
        let existingSyncedFingerprints = Set(
            existingPlaceholders
                .map(\.path)
                .filter { $0.hasPrefix(syncedPlaceholderPathPrefix) }
                .map { String($0.dropFirst(syncedPlaceholderPathPrefix.count)) }
        )

        for (fingerprint, entry) in mergedEntries {
            guard let metadata = entry.metadata, !localFingerprints.contains(fingerprint) else { continue }
            let data = PlaceholderTrackData(
                path: syncedPlaceholderPathPrefix + fingerprint,
                title: metadata.title, artist: metadata.artist, album: metadata.album, genre: metadata.genre,
                year: metadata.year, trackNumber: metadata.trackNumber, discNumber: metadata.discNumber,
                bpm: metadata.bpm, key: metadata.key, comments: metadata.comments,
                rating: entry.rating, tags: metadata.tags, isHidden: false, playCount: entry.playCount,
                duration: metadata.duration
            )
            try? await store.savePlaceholderTrack(data)
        }

        for fingerprint in existingSyncedFingerprints where localFingerprints.contains(fingerprint) {
            try? await store.deletePlaceholderTrack(path: syncedPlaceholderPathPrefix + fingerprint)
        }
    }

    /// Ratings use last-write-wins by `ratedAt`; play counts take the max
    /// of both sides (a grow-only counter, not a point-in-time value) —
    /// never loses a play, though a track played on *both* machines in
    /// the same window between syncs undercounts that overlap. A
    /// reasonable tradeoff for a personal two-machine setup, not a
    /// distributed system.
    private static func merge(local: StoredRating?, remote: SnapshotEntry?) -> SnapshotEntry {
        let localRating = local?.rating ?? 0
        let localRatedAt = local?.ratedAt
        let remoteRating = remote?.rating ?? 0
        let remoteRatedAt = remote?.ratedAt

        let mergedRating: Int
        let mergedRatedAt: Date?
        switch (localRatedAt, remoteRatedAt) {
        case let (l?, r?):
            (mergedRating, mergedRatedAt) = r > l ? (remoteRating, r) : (localRating, l)
        case (nil, let r?):
            (mergedRating, mergedRatedAt) = (remoteRating, r)
        case (let l?, nil):
            (mergedRating, mergedRatedAt) = (localRating, l)
        case (nil, nil):
            // Neither side has ever recorded a timestamp (a rating set
            // before this feature existed) — prefer an actual rating over
            // an untouched 0 rather than favoring local by default.
            (mergedRating, mergedRatedAt) = (localRating == 0 && remoteRating != 0)
                ? (remoteRating, nil)
                : (localRating, nil)
        }

        let mergedPlayCount = max(local?.playCount ?? 0, remote?.playCount ?? 0)
        return SnapshotEntry(rating: mergedRating, ratedAt: mergedRatedAt, playCount: mergedPlayCount)
    }

    // MARK: - File I/O

    /// `NSFileCoordinator` isn't available outside AppKit/Foundation's
    /// file-presenter machinery in a plain `async` context here, so reads
    /// and writes just go through `FileManager` directly — for a personal,
    /// two-machine, sync-on-launch setup, the odds of a genuine torn read
    /// (mid-write from the other machine, mid-iCloud-upload) are low
    /// enough to accept; a bad read just falls back to an empty snapshot
    /// rather than crashing, which is preferable to added complexity here.
    /// Stock `.iso8601` (both encoder and decoder) truncates to whole
    /// seconds — nowhere near precise enough for last-write-wins to mean
    /// anything: two rating changes on two machines, synced minutes apart,
    /// can easily still land in the same second once each was actually
    /// *set*, silently falling back to an arbitrary tie-break instead of
    /// honoring whichever genuinely happened later.
    // `nonisolated(unsafe)`: built once, read-only afterward — genuinely
    // safe to share, but `ISO8601DateFormatter` itself predates Swift
    // concurrency and isn't marked `Sendable`.
    private nonisolated(unsafe) static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func readSnapshot(at url: URL) -> Snapshot {
        guard let data = try? Data(contentsOf: url) else { return Snapshot() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = dateFormatter.date(from: string) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date: \(string)")
            }
            return date
        }
        return (try? decoder.decode(Snapshot.self, from: data)) ?? Snapshot()
    }

    @discardableResult
    private static func writeSnapshot(_ snapshot: Snapshot, to url: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(dateFormatter.string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}
