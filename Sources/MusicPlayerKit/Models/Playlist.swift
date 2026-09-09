import Foundation

public struct Playlist: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var isSmart: Bool

    /// Smart playlists only: true = a track must satisfy ALL of
    /// `smartRules`, false = ANY one of them.
    public var smartMatchAll: Bool
    public var smartRules: [SmartRule]

    /// Regular playlists only: ordered track paths.
    public var trackPaths: [String]

    /// When this playlist was last modified — used only for cross-machine
    /// sync (see `iCloudSyncService.syncPlaylists`), same last-write-wins
    /// role `StoredRating.ratedAt` plays for ratings. `nil` for a playlist
    /// saved before this field existed — deliberately not defaulted to
    /// "now" on load, or every pre-existing playlist would look newer
    /// than a genuinely recent edit on another machine the first time it
    /// syncs.
    public var updatedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        isSmart: Bool = false,
        smartMatchAll: Bool = false,
        smartRules: [SmartRule] = [],
        trackPaths: [String] = [],
        updatedAt: Date? = Date()
    ) {
        self.id = id
        self.name = name
        self.isSmart = isSmart
        self.smartMatchAll = smartMatchAll
        self.smartRules = smartRules
        self.trackPaths = trackPaths
        self.updatedAt = updatedAt
    }
}
