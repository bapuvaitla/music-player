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

    public init(
        id: UUID = UUID(),
        name: String,
        isSmart: Bool = false,
        smartMatchAll: Bool = false,
        smartRules: [SmartRule] = [],
        trackPaths: [String] = []
    ) {
        self.id = id
        self.name = name
        self.isSmart = isSmart
        self.smartMatchAll = smartMatchAll
        self.smartRules = smartRules
        self.trackPaths = trackPaths
    }
}
