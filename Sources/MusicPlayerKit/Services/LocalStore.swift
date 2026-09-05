import Foundation
import GRDB

public struct StoredRating: Sendable {
    public var rating: Int
    public var tags: [String]
    public var playCount: Double
    public var isHidden: Bool

    public var titleOverride: String?
    public var artistOverride: String?
    public var albumOverride: String?
    public var genreOverride: String?
    public var yearOverride: Int?
    public var trackNumberOverride: Int?
    public var discNumberOverride: Int?
    public var bpmOverride: Int?
    public var keyOverride: String?
    public var commentsOverride: String?

    public init(
        rating: Int,
        tags: [String],
        playCount: Double = 0,
        isHidden: Bool = false,
        titleOverride: String? = nil,
        artistOverride: String? = nil,
        albumOverride: String? = nil,
        genreOverride: String? = nil,
        yearOverride: Int? = nil,
        trackNumberOverride: Int? = nil,
        discNumberOverride: Int? = nil,
        bpmOverride: Int? = nil,
        keyOverride: String? = nil,
        commentsOverride: String? = nil
    ) {
        self.rating = rating
        self.tags = tags
        self.playCount = playCount
        self.isHidden = isHidden
        self.titleOverride = titleOverride
        self.artistOverride = artistOverride
        self.albumOverride = albumOverride
        self.genreOverride = genreOverride
        self.yearOverride = yearOverride
        self.trackNumberOverride = trackNumberOverride
        self.discNumberOverride = discNumberOverride
        self.bpmOverride = bpmOverride
        self.keyOverride = keyOverride
        self.commentsOverride = commentsOverride
    }
}

/// Every field a track's "Edit Info" sheet can override, bundled together
/// so the store's write API doesn't need a 10-parameter function.
public struct MetadataOverrides: Sendable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var genre: String?
    public var year: Int?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var bpm: Int?
    public var key: String?
    public var comments: String?
    public var tags: [String]

    public init(
        title: String?,
        artist: String?,
        album: String?,
        genre: String?,
        year: Int?,
        trackNumber: Int?,
        discNumber: Int?,
        bpm: Int?,
        key: String?,
        comments: String?,
        tags: [String]
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.genre = genre
        self.year = year
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.bpm = bpm
        self.key = key
        self.comments = comments
        self.tags = tags
    }
}

public protocol RatingStore: Sendable {
    func allRatings() async throws -> [String: StoredRating]
    func setRating(_ rating: Int, forPath path: String) async throws
    func addPartialPlay(_ fraction: Double, forPath path: String) async throws
    func setHidden(_ hidden: Bool, forPath path: String) async throws
    func setOverrides(_ overrides: MetadataOverrides, forPath path: String) async throws

    /// A locally-stored replacement cover image for this track, if one was
    /// set — kept in its own table rather than on the `ratings` row so
    /// `allRatings()` never has to bulk-load image blobs. `nil` means "use
    /// the file's embedded artwork," not "no artwork exists."
    func artworkOverride(forPath path: String) async throws -> Data?
    /// Pass `nil` to clear the override and fall back to embedded artwork.
    func setArtworkOverride(_ imageData: Data?, forPath path: String) async throws

    /// Migrates a track's locally-stored rating/tags/overrides/artwork from
    /// one path to another — used when a track's backing file is swapped
    /// out (see `LibraryModel.replaceFile`), so the file change doesn't
    /// orphan everything keyed to the old path. A no-op if `oldPath` has no
    /// stored data.
    func reassignPath(from oldPath: String, to newPath: String) async throws

    /// Placeholder tracks (no backing audio file — see `Track.isPlaceholder`)
    /// are entirely manually-entered, so unlike a real track's rating/tags
    /// (an override layered on scanned file metadata), everything about one
    /// lives in this single row — there's no file scan to reapply it to.
    func allPlaceholderTracks() async throws -> [PlaceholderTrackData]
    func savePlaceholderTrack(_ data: PlaceholderTrackData) async throws
    func deletePlaceholderTrack(path: String) async throws

    /// Paths permanently removed from the library via "Delete Track" on a
    /// real, file-backed track — unlike hiding, this survives a rescan:
    /// the file is still on disk and would otherwise just get picked back
    /// up, so scanning filters out anything in this set. The audio file
    /// itself is never touched.
    func excludedPaths() async throws -> Set<String>
    func excludePath(_ path: String) async throws

    /// Learn Song: which tab/vocal-melody file (if any) is attached to a
    /// track, and its saved loop region — keyed by track path. Stores
    /// *references* to the imported files, same as how the library
    /// references audio files by path rather than copying them.
    func learnSession(forTrackPath path: String) async throws -> LearnSessionData?
    func saveLearnSession(_ data: LearnSessionData, forTrackPath path: String) async throws
}

/// Learn Song's saved state for one track — see `RatingStore.learnSession`.
public struct LearnSessionData: Sendable {
    public var tabFilePath: String?
    public var vocalFilePath: String?
    public var loopStart: TimeInterval?
    public var loopEnd: TimeInterval?

    public init(tabFilePath: String? = nil, vocalFilePath: String? = nil, loopStart: TimeInterval? = nil, loopEnd: TimeInterval? = nil) {
        self.tabFilePath = tabFilePath
        self.vocalFilePath = vocalFilePath
        self.loopStart = loopStart
        self.loopEnd = loopEnd
    }
}

/// A manually-entered track with no backing audio file — see
/// `Track.isPlaceholder`. Holds every field of the track directly, since
/// there's no scanned file to layer it on top of.
public struct PlaceholderTrackData: Sendable {
    public var path: String
    public var title: String
    public var artist: String
    public var album: String
    public var genre: String
    public var year: Int?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var bpm: Int?
    public var key: String?
    public var comments: String?
    public var rating: Int
    public var tags: [String]
    public var isHidden: Bool

    public init(
        path: String,
        title: String,
        artist: String,
        album: String,
        genre: String,
        year: Int? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        bpm: Int? = nil,
        key: String? = nil,
        comments: String? = nil,
        rating: Int = 0,
        tags: [String] = [],
        isHidden: Bool = false
    ) {
        self.path = path
        self.title = title
        self.artist = artist
        self.album = album
        self.genre = genre
        self.year = year
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.bpm = bpm
        self.key = key
        self.comments = comments
        self.rating = rating
        self.tags = tags
        self.isHidden = isHidden
    }
}

public protocol PlaylistStore: Sendable {
    func allPlaylists() async throws -> [Playlist]
    func savePlaylist(_ playlist: Playlist) async throws
    func deletePlaylist(id: UUID) async throws
}

private struct RatingRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "ratings"

    var path: String
    var rating: Int
    var tags: String
    var playCount: Double
    var isHidden: Bool
    var titleOverride: String?
    var artistOverride: String?
    var albumOverride: String?
    var genreOverride: String?
    var yearOverride: Int?
    var trackNumberOverride: Int?
    var discNumberOverride: Int?
    var bpmOverride: Int?
    var keyOverride: String?
    var commentsOverride: String?

    enum CodingKeys: String, CodingKey {
        case path, rating, tags
        case playCount = "play_count"
        case isHidden = "is_hidden"
        case titleOverride = "title_override"
        case artistOverride = "artist_override"
        case albumOverride = "album_override"
        case genreOverride = "genre_override"
        case yearOverride = "year_override"
        case trackNumberOverride = "track_number_override"
        case discNumberOverride = "disc_number_override"
        case bpmOverride = "bpm_override"
        case keyOverride = "key_override"
        case commentsOverride = "comments_override"
    }

    /// A copy of this record (or a fresh blank one) with the given path's
    /// rating/playCount kept and every override field replaced.
    static func applyingOverrides(_ overrides: MetadataOverrides, to existing: RatingRecord?, path: String) -> RatingRecord {
        RatingRecord(
            path: path,
            rating: existing?.rating ?? 0,
            tags: overrides.tags.joined(separator: ","),
            playCount: existing?.playCount ?? 0,
            isHidden: existing?.isHidden ?? false,
            titleOverride: overrides.title,
            artistOverride: overrides.artist,
            albumOverride: overrides.album,
            genreOverride: overrides.genre,
            yearOverride: overrides.year,
            trackNumberOverride: overrides.trackNumber,
            discNumberOverride: overrides.discNumber,
            bpmOverride: overrides.bpm,
            keyOverride: overrides.key,
            commentsOverride: overrides.comments
        )
    }
}

private struct ArtworkOverrideRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "artwork_overrides"

    var path: String
    var imageData: Data

    enum CodingKeys: String, CodingKey {
        case path
        case imageData = "image_data"
    }
}

private struct ExcludedPathRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "excluded_paths"
    var path: String
}

private struct LearnSessionRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "learn_sessions"

    var trackPath: String
    var tabFilePath: String?
    var vocalFilePath: String?
    var loopStart: Double?
    var loopEnd: Double?

    enum CodingKeys: String, CodingKey {
        case trackPath = "track_path"
        case tabFilePath = "tab_file_path"
        case vocalFilePath = "vocal_file_path"
        case loopStart = "loop_start"
        case loopEnd = "loop_end"
    }

    var asData: LearnSessionData {
        LearnSessionData(tabFilePath: tabFilePath, vocalFilePath: vocalFilePath, loopStart: loopStart, loopEnd: loopEnd)
    }

    init(trackPath: String, tabFilePath: String?, vocalFilePath: String?, loopStart: Double?, loopEnd: Double?) {
        self.trackPath = trackPath
        self.tabFilePath = tabFilePath
        self.vocalFilePath = vocalFilePath
        self.loopStart = loopStart
        self.loopEnd = loopEnd
    }

    init(trackPath: String, _ data: LearnSessionData) {
        self.init(trackPath: trackPath, tabFilePath: data.tabFilePath, vocalFilePath: data.vocalFilePath, loopStart: data.loopStart, loopEnd: data.loopEnd)
    }
}

private struct PlaceholderTrackRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "placeholder_tracks"

    var path: String
    var title: String
    var artist: String
    var album: String
    var genre: String
    var year: Int?
    var trackNumber: Int?
    var discNumber: Int?
    var bpm: Int?
    var key: String?
    var comments: String?
    var rating: Int
    var tags: String
    var isHidden: Bool

    enum CodingKeys: String, CodingKey {
        case path, title, artist, album, genre, year, rating, tags, key, comments
        case trackNumber = "track_number"
        case discNumber = "disc_number"
        case bpm
        case isHidden = "is_hidden"
    }

    var asData: PlaceholderTrackData {
        PlaceholderTrackData(
            path: path, title: title, artist: artist, album: album, genre: genre,
            year: year, trackNumber: trackNumber, discNumber: discNumber, bpm: bpm,
            key: key, comments: comments, rating: rating,
            tags: tags.isEmpty ? [] : tags.components(separatedBy: ","),
            isHidden: isHidden
        )
    }

    init(path: String, title: String, artist: String, album: String, genre: String, year: Int?, trackNumber: Int?, discNumber: Int?, bpm: Int?, key: String?, comments: String?, rating: Int, tags: String, isHidden: Bool) {
        self.path = path
        self.title = title
        self.artist = artist
        self.album = album
        self.genre = genre
        self.year = year
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.bpm = bpm
        self.key = key
        self.comments = comments
        self.rating = rating
        self.tags = tags
        self.isHidden = isHidden
    }

    init(_ data: PlaceholderTrackData) {
        self.init(
            path: data.path, title: data.title, artist: data.artist, album: data.album, genre: data.genre,
            year: data.year, trackNumber: data.trackNumber, discNumber: data.discNumber, bpm: data.bpm,
            key: data.key, comments: data.comments, rating: data.rating,
            tags: data.tags.joined(separator: ","), isHidden: data.isHidden
        )
    }
}

private struct PlaylistRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "playlists"

    var id: String
    var name: String
    var isSmart: Bool
    var smartMatchAll: Bool
    /// Legacy tag-only representation — no longer written, but still read
    /// as a migration source for playlists saved before smart rules
    /// existed (see `smartRules`, computed from whichever of these two is
    /// present).
    var smartTags: String
    /// JSON-encoded `[SmartRule]`. Nil for a legacy pre-rules row, in
    /// which case `smartRules` synthesizes one `.tags`/`.contains` rule
    /// per legacy tag instead.
    var smartRulesJSON: String?
    var trackPaths: String

    enum CodingKeys: String, CodingKey {
        case id, name
        case isSmart = "is_smart"
        case smartMatchAll = "smart_match_all"
        case smartTags = "smart_tags"
        case smartRulesJSON = "smart_rules_json"
        case trackPaths = "track_paths"
    }

    /// Decodes `smartRulesJSON` when present; otherwise migrates the
    /// legacy comma-separated `smartTags` into equivalent rules, one
    /// "Tags contains <tag>" rule per tag.
    var smartRules: [SmartRule] {
        if let json = smartRulesJSON, let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([SmartRule].self, from: data) {
            return decoded
        }
        guard !smartTags.isEmpty else { return [] }
        return smartTags.components(separatedBy: ",").map {
            SmartRule(field: .tags, comparison: .contains, value: $0)
        }
    }

    static func encodeRules(_ rules: [SmartRule]) -> String? {
        guard let data = try? JSONEncoder().encode(rules), let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }
}

public final class GRDBLocalStore: RatingStore, PlaylistStore, @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    public init(databaseURL: URL) throws {
        dbQueue = try DatabaseQueue(path: databaseURL.path)
        try Self.migrator.migrate(dbQueue)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createRatings") { db in
            try db.create(table: "ratings") { t in
                t.column("path", .text).notNull().primaryKey()
                t.column("rating", .integer).notNull().defaults(to: 0)
                t.column("tags", .text).notNull().defaults(to: "")
            }
        }
        migrator.registerMigration("addMetadataOverrides") { db in
            try db.alter(table: "ratings") { t in
                t.add(column: "title_override", .text)
                t.add(column: "artist_override", .text)
                t.add(column: "album_override", .text)
                t.add(column: "genre_override", .text)
            }
        }
        migrator.registerMigration("addPlayCount") { db in
            try db.alter(table: "ratings") { t in
                t.add(column: "play_count", .double).notNull().defaults(to: 0)
            }
        }
        migrator.registerMigration("createPlaylists") { db in
            try db.create(table: "playlists") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("name", .text).notNull()
                t.column("is_smart", .boolean).notNull().defaults(to: false)
                t.column("smart_match_all", .boolean).notNull().defaults(to: false)
                t.column("smart_tags", .text).notNull().defaults(to: "")
                t.column("track_paths", .text).notNull().defaults(to: "")
            }
        }
        migrator.registerMigration("addExtendedMetadataOverrides") { db in
            try db.alter(table: "ratings") { t in
                t.add(column: "year_override", .integer)
                t.add(column: "track_number_override", .integer)
                t.add(column: "disc_number_override", .integer)
                t.add(column: "bpm_override", .integer)
                t.add(column: "key_override", .text)
                t.add(column: "comments_override", .text)
            }
        }
        migrator.registerMigration("createArtworkOverrides") { db in
            try db.create(table: "artwork_overrides") { t in
                t.column("path", .text).notNull().primaryKey()
                t.column("image_data", .blob).notNull()
            }
        }
        migrator.registerMigration("addIsHidden") { db in
            try db.alter(table: "ratings") { t in
                t.add(column: "is_hidden", .boolean).notNull().defaults(to: false)
            }
        }
        migrator.registerMigration("createPlaceholderTracks") { db in
            try db.create(table: "placeholder_tracks") { t in
                t.column("path", .text).notNull().primaryKey()
                t.column("title", .text).notNull()
                t.column("artist", .text).notNull()
                t.column("album", .text).notNull()
                t.column("genre", .text).notNull()
                t.column("year", .integer)
                t.column("track_number", .integer)
                t.column("disc_number", .integer)
                t.column("bpm", .integer)
                t.column("key", .text)
                t.column("comments", .text)
                t.column("rating", .integer).notNull().defaults(to: 0)
                t.column("tags", .text).notNull().defaults(to: "")
                t.column("is_hidden", .boolean).notNull().defaults(to: false)
            }
        }
        migrator.registerMigration("addSmartRules") { db in
            try db.alter(table: "playlists") { t in
                t.add(column: "smart_rules_json", .text)
            }
        }
        migrator.registerMigration("createExcludedPaths") { db in
            try db.create(table: "excluded_paths") { t in
                t.column("path", .text).notNull().primaryKey()
            }
        }
        migrator.registerMigration("createLearnSessions") { db in
            try db.create(table: "learn_sessions") { t in
                t.column("track_path", .text).notNull().primaryKey()
                t.column("tab_file_path", .text)
                t.column("vocal_file_path", .text)
                t.column("loop_start", .double)
                t.column("loop_end", .double)
            }
        }
        return migrator
    }

    // MARK: - RatingStore

    public func allRatings() async throws -> [String: StoredRating] {
        let records = try await dbQueue.read { db in
            try RatingRecord.fetchAll(db)
        }
        var result: [String: StoredRating] = [:]
        for record in records {
            let tags = record.tags.isEmpty ? [] : record.tags.components(separatedBy: ",")
            result[record.path] = StoredRating(
                rating: record.rating,
                tags: tags,
                playCount: record.playCount,
                isHidden: record.isHidden,
                titleOverride: record.titleOverride,
                artistOverride: record.artistOverride,
                albumOverride: record.albumOverride,
                genreOverride: record.genreOverride,
                yearOverride: record.yearOverride,
                trackNumberOverride: record.trackNumberOverride,
                discNumberOverride: record.discNumberOverride,
                bpmOverride: record.bpmOverride,
                keyOverride: record.keyOverride,
                commentsOverride: record.commentsOverride
            )
        }
        return result
    }

    private static func blankRecord(path: String) -> RatingRecord {
        RatingRecord(
            path: path, rating: 0, tags: "", playCount: 0, isHidden: false,
            titleOverride: nil, artistOverride: nil, albumOverride: nil, genreOverride: nil,
            yearOverride: nil, trackNumberOverride: nil, discNumberOverride: nil,
            bpmOverride: nil, keyOverride: nil, commentsOverride: nil
        )
    }

    public func setRating(_ rating: Int, forPath path: String) async throws {
        try await dbQueue.write { db in
            var record = try RatingRecord.fetchOne(db, key: path) ?? Self.blankRecord(path: path)
            record.rating = rating
            try record.save(db)
        }
    }

    public func addPartialPlay(_ fraction: Double, forPath path: String) async throws {
        try await dbQueue.write { db in
            var record = try RatingRecord.fetchOne(db, key: path) ?? Self.blankRecord(path: path)
            record.playCount += fraction
            try record.save(db)
        }
    }

    public func setHidden(_ hidden: Bool, forPath path: String) async throws {
        try await dbQueue.write { db in
            var record = try RatingRecord.fetchOne(db, key: path) ?? Self.blankRecord(path: path)
            record.isHidden = hidden
            try record.save(db)
        }
    }

    public func setOverrides(_ overrides: MetadataOverrides, forPath path: String) async throws {
        try await dbQueue.write { db in
            let existing = try RatingRecord.fetchOne(db, key: path)
            let record = RatingRecord.applyingOverrides(overrides, to: existing, path: path)
            try record.save(db)
        }
    }

    public func artworkOverride(forPath path: String) async throws -> Data? {
        try await dbQueue.read { db in
            try ArtworkOverrideRecord.fetchOne(db, key: path)?.imageData
        }
    }

    public func setArtworkOverride(_ imageData: Data?, forPath path: String) async throws {
        try await dbQueue.write { db in
            if let imageData {
                try ArtworkOverrideRecord(path: path, imageData: imageData).save(db)
            } else {
                _ = try ArtworkOverrideRecord.deleteOne(db, key: path)
            }
        }
    }

    public func reassignPath(from oldPath: String, to newPath: String) async throws {
        try await dbQueue.write { db in
            if var rating = try RatingRecord.fetchOne(db, key: oldPath) {
                _ = try RatingRecord.deleteOne(db, key: oldPath)
                rating.path = newPath
                try rating.save(db)
            }
            if var artwork = try ArtworkOverrideRecord.fetchOne(db, key: oldPath) {
                _ = try ArtworkOverrideRecord.deleteOne(db, key: oldPath)
                artwork.path = newPath
                try artwork.save(db)
            }
        }
    }

    public func allPlaceholderTracks() async throws -> [PlaceholderTrackData] {
        let records = try await dbQueue.read { db in
            try PlaceholderTrackRecord.fetchAll(db)
        }
        return records.map(\.asData)
    }

    public func savePlaceholderTrack(_ data: PlaceholderTrackData) async throws {
        try await dbQueue.write { db in
            try PlaceholderTrackRecord(data).save(db)
        }
    }

    public func deletePlaceholderTrack(path: String) async throws {
        try await dbQueue.write { db in
            _ = try PlaceholderTrackRecord.deleteOne(db, key: path)
        }
    }

    public func excludedPaths() async throws -> Set<String> {
        let records = try await dbQueue.read { db in
            try ExcludedPathRecord.fetchAll(db)
        }
        return Set(records.map(\.path))
    }

    public func excludePath(_ path: String) async throws {
        try await dbQueue.write { db in
            try ExcludedPathRecord(path: path).save(db)
        }
    }

    public func learnSession(forTrackPath path: String) async throws -> LearnSessionData? {
        try await dbQueue.read { db in
            try LearnSessionRecord.fetchOne(db, key: path)?.asData
        }
    }

    public func saveLearnSession(_ data: LearnSessionData, forTrackPath path: String) async throws {
        try await dbQueue.write { db in
            try LearnSessionRecord(trackPath: path, data).save(db)
        }
    }

    // MARK: - PlaylistStore

    public func allPlaylists() async throws -> [Playlist] {
        let records = try await dbQueue.read { db in
            try PlaylistRecord.fetchAll(db)
        }
        return records.map { record in
            Playlist(
                id: UUID(uuidString: record.id) ?? UUID(),
                name: record.name,
                isSmart: record.isSmart,
                smartMatchAll: record.smartMatchAll,
                smartRules: record.smartRules,
                trackPaths: record.trackPaths.isEmpty ? [] : record.trackPaths.components(separatedBy: "\n")
            )
        }
    }

    public func savePlaylist(_ playlist: Playlist) async throws {
        try await dbQueue.write { db in
            let record = PlaylistRecord(
                id: playlist.id.uuidString,
                name: playlist.name,
                isSmart: playlist.isSmart,
                smartMatchAll: playlist.smartMatchAll,
                smartTags: "",
                smartRulesJSON: PlaylistRecord.encodeRules(playlist.smartRules),
                trackPaths: playlist.trackPaths.joined(separator: "\n")
            )
            try record.save(db)
        }
    }

    public func deletePlaylist(id: UUID) async throws {
        try await dbQueue.write { db in
            _ = try PlaylistRecord.deleteOne(db, key: id.uuidString)
        }
    }
}

public actor InMemoryLocalStore: RatingStore, PlaylistStore {
    private var ratings: [String: StoredRating] = [:]
    private var playlists: [UUID: Playlist] = [:]
    private var artworkOverrides: [String: Data] = [:]
    private var placeholderTracks: [String: PlaceholderTrackData] = [:]
    private var excludedPathsStorage: Set<String> = []
    private var learnSessions: [String: LearnSessionData] = [:]

    public init() {}

    public func allRatings() async throws -> [String: StoredRating] {
        ratings
    }

    public func setRating(_ rating: Int, forPath path: String) async throws {
        var existing = ratings[path] ?? StoredRating(rating: 0, tags: [])
        existing.rating = rating
        ratings[path] = existing
    }

    public func addPartialPlay(_ fraction: Double, forPath path: String) async throws {
        var existing = ratings[path] ?? StoredRating(rating: 0, tags: [])
        existing.playCount += fraction
        ratings[path] = existing
    }

    public func setHidden(_ hidden: Bool, forPath path: String) async throws {
        var existing = ratings[path] ?? StoredRating(rating: 0, tags: [])
        existing.isHidden = hidden
        ratings[path] = existing
    }

    public func setOverrides(_ overrides: MetadataOverrides, forPath path: String) async throws {
        var existing = ratings[path] ?? StoredRating(rating: 0, tags: [])
        existing.tags = overrides.tags
        existing.titleOverride = overrides.title
        existing.artistOverride = overrides.artist
        existing.albumOverride = overrides.album
        existing.genreOverride = overrides.genre
        existing.yearOverride = overrides.year
        existing.trackNumberOverride = overrides.trackNumber
        existing.discNumberOverride = overrides.discNumber
        existing.bpmOverride = overrides.bpm
        existing.keyOverride = overrides.key
        existing.commentsOverride = overrides.comments
        ratings[path] = existing
    }

    public func artworkOverride(forPath path: String) async throws -> Data? {
        artworkOverrides[path]
    }

    public func setArtworkOverride(_ imageData: Data?, forPath path: String) async throws {
        artworkOverrides[path] = imageData
    }

    public func reassignPath(from oldPath: String, to newPath: String) async throws {
        if let rating = ratings[oldPath] {
            ratings[oldPath] = nil
            ratings[newPath] = rating
        }
        if let artwork = artworkOverrides[oldPath] {
            artworkOverrides[oldPath] = nil
            artworkOverrides[newPath] = artwork
        }
    }

    public func allPlaceholderTracks() async throws -> [PlaceholderTrackData] {
        Array(placeholderTracks.values)
    }

    public func savePlaceholderTrack(_ data: PlaceholderTrackData) async throws {
        placeholderTracks[data.path] = data
    }

    public func deletePlaceholderTrack(path: String) async throws {
        placeholderTracks[path] = nil
    }

    public func excludedPaths() async throws -> Set<String> {
        excludedPathsStorage
    }

    public func excludePath(_ path: String) async throws {
        excludedPathsStorage.insert(path)
    }

    public func learnSession(forTrackPath path: String) async throws -> LearnSessionData? {
        learnSessions[path]
    }

    public func saveLearnSession(_ data: LearnSessionData, forTrackPath path: String) async throws {
        learnSessions[path] = data
    }

    public func allPlaylists() async throws -> [Playlist] {
        Array(playlists.values)
    }

    public func savePlaylist(_ playlist: Playlist) async throws {
        playlists[playlist.id] = playlist
    }

    public func deletePlaylist(id: UUID) async throws {
        playlists[id] = nil
    }
}
