import Foundation

public struct Track: Identifiable, Hashable, Sendable {
    public var id: String { path }

    public let path: String

    /// Effective, displayed values — either the file's own metadata, or a
    /// locally-stored override if the user edited it.
    public var title: String
    public var artist: String
    public var album: String
    public var genre: String

    /// The metadata as originally read from the file, before any local
    /// override. Used to prefill/reset the edit UI and never overwritten.
    public let originalTitle: String
    public let originalArtist: String
    public let originalAlbum: String
    public let originalGenre: String

    public var duration: TimeInterval

    // Effective values — file metadata unless locally overridden.
    public var year: Int?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var bpm: Int?
    public var key: String?
    public var comments: String?

    // As originally read from the file, for reset-to-file-value in the edit UI.
    public let originalYear: Int?
    public let originalTrackNumber: Int?
    public let originalDiscNumber: Int?
    public let originalBpm: Int?
    public let originalKey: String?
    public let originalComments: String?

    public var rating: Int = 0
    public var tags: [String] = []
    public var playCount: Double = 0

    /// Hidden tracks are excluded from browsing and playback (shuffle,
    /// album view, "up next", etc.) but still count toward an album's
    /// aggregate rating.
    public var isHidden: Bool = false

    /// A manually-entered stand-in for a track you don't actually have a
    /// file for — e.g. a song from an album you've heard but don't own,
    /// entered just so its rating counts toward that album's average.
    /// Has no backing audio file (`path` is a synthetic identifier, not a
    /// real filesystem path) and can't be played; shown grayed out in the
    /// track list instead.
    public var isPlaceholder: Bool = false

    public var url: URL { URL(fileURLWithPath: path) }

    /// A stable identity for this track independent of where its file
    /// lives — `path` (this app's normal identity for everything else)
    /// is a local filesystem path, which won't match between two
    /// machines with different folder layouts. Used only for cross-
    /// machine sync (see `iCloudSyncService`): title/artist/album,
    /// normalized, plus duration rounded to the nearest second (cheap
    /// insurance against two different songs sharing a title/artist/
    /// album, without needing to hash actual audio content).
    public var syncFingerprint: String {
        func normalize(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return "\(normalize(title))|\(normalize(artist))|\(normalize(album))|\(Int(duration.rounded()))"
    }

    // Non-optional surrogate keys so Table can sort by these columns
    // (Optional<Int>/Optional<String> aren't Comparable).
    public var yearSortKey: Int { year ?? -1 }
    public var trackNumberSortKey: Int { trackNumber ?? -1 }
    public var discNumberSortKey: Int { discNumber ?? -1 }
    public var bpmSortKey: Int { bpm ?? -1 }
    public var keySortKey: String { key ?? "" }
    public var commentsSortKey: String { comments ?? "" }
    public var tagsSortKey: String { tags.joined(separator: ",") }

    public var durationString: String {
        guard duration.isFinite, duration > 0 else { return "--:--" }
        let total = Int(duration.rounded())
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    public init(
        path: String,
        title: String,
        artist: String,
        album: String,
        genre: String,
        duration: TimeInterval,
        year: Int? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        bpm: Int? = nil,
        key: String? = nil,
        comments: String? = nil,
        rating: Int = 0,
        tags: [String] = [],
        playCount: Double = 0
    ) {
        self.path = path
        self.title = title
        self.artist = artist
        self.album = album
        self.genre = genre
        self.originalTitle = title
        self.originalArtist = artist
        self.originalAlbum = album
        self.originalGenre = genre
        self.duration = duration
        self.year = year
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.bpm = bpm
        self.key = key
        self.comments = comments
        self.originalYear = year
        self.originalTrackNumber = trackNumber
        self.originalDiscNumber = discNumber
        self.originalBpm = bpm
        self.originalKey = key
        self.originalComments = comments
        self.rating = rating
        self.tags = tags
        self.playCount = playCount
    }
}
