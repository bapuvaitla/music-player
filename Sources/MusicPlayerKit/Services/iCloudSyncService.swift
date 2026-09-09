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
    public struct SnapshotEntry: Codable, Sendable, Equatable {
        public var rating: Int
        public var ratedAt: Date?
        public var playCount: Double
    }

    public struct Snapshot: Codable, Sendable {
        public var entries: [String: SnapshotEntry]
        public var updatedAt: Date

        public init(entries: [String: SnapshotEntry] = [:], updatedAt: Date = Date()) {
            self.entries = entries
            self.updatedAt = updatedAt
        }
    }

    public struct SyncResult: Sendable {
        public var pathsUpdatedLocally: Int
        public var wroteRemoteSnapshot: Bool
    }

    public enum SyncError: Error {
        case iCloudDriveUnavailable
    }

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
        // meant to represent "the same track" for sync purposes.
        var pathsByFingerprint: [String: [String]] = [:]
        for track in tracks where !track.isPlaceholder {
            pathsByFingerprint[track.syncFingerprint, default: []].append(track.path)
        }

        var mergedEntries: [String: SnapshotEntry] = [:]
        var updatedPathCount = 0

        for (fingerprint, paths) in pathsByFingerprint {
            // All paths sharing a fingerprint should already agree locally
            // (they're duplicates of the same song), so the first one's
            // stored rating stands in for the whole group.
            let local = paths.first.flatMap { localRatings[$0] }
            let remoteEntry = remote.entries[fingerprint]

            let merged = Self.merge(local: local, remote: remoteEntry)
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

        let wrote = writeSnapshot(Snapshot(entries: mergedEntries, updatedAt: Date()), to: targetURL)
        return SyncResult(pathsUpdatedLocally: updatedPathCount, wroteRemoteSnapshot: wrote)
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
