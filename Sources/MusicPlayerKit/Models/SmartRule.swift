import Foundation

/// A field a smart playlist rule can test — any track attribute, not just
/// tags.
public enum SmartRuleField: String, Codable, Sendable, CaseIterable, Identifiable {
    case title, artist, album, genre, year, trackNumber, discNumber, bpm, key, comments, tags, rating, playCount
    /// A track's *album's* total play count (every track on that album
    /// summed together) — an album-level characteristic, unlike every
    /// other field here, which reads straight off the one track being
    /// tested. See `SmartRule.matches(_:albumTotalPlays:)`.
    case albumTotalPlays

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .title: return "Title"
        case .artist: return "Artist"
        case .album: return "Album"
        case .genre: return "Genre"
        case .year: return "Year"
        case .trackNumber: return "Track #"
        case .discNumber: return "Disc #"
        case .bpm: return "BPM"
        case .key: return "Key"
        case .comments: return "Comments"
        case .tags: return "Tags"
        case .rating: return "Resonance"
        case .playCount: return "Play Count"
        case .albumTotalPlays: return "Album Total Plays"
        }
    }

    public var isNumeric: Bool {
        switch self {
        case .year, .trackNumber, .discNumber, .bpm, .rating, .playCount, .albumTotalPlays: return true
        case .title, .artist, .album, .genre, .key, .comments, .tags: return false
        }
    }

    /// Which comparisons make sense for this field's kind — numeric
    /// fields get ordering, text fields get substring/prefix/suffix, both
    /// share equals/not-equals. `tags` is text-shaped but matched against
    /// a track's whole tag set rather than one string (see `SmartRule`).
    public var availableComparisons: [SmartRuleComparison] {
        isNumeric
            ? [.equals, .notEquals, .greaterThan, .greaterThanOrEqual, .lessThan, .lessThanOrEqual]
            : [.contains, .notContains, .equals, .notEquals, .beginsWith, .endsWith]
    }
}

public enum SmartRuleComparison: String, Codable, Sendable, CaseIterable, Identifiable {
    case equals, notEquals, contains, notContains, beginsWith, endsWith
    case greaterThan, greaterThanOrEqual, lessThan, lessThanOrEqual

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .equals: return "is"
        case .notEquals: return "is not"
        case .contains: return "contains"
        case .notContains: return "does not contain"
        case .beginsWith: return "begins with"
        case .endsWith: return "ends with"
        case .greaterThan: return "is greater than"
        case .greaterThanOrEqual: return "is at least"
        case .lessThan: return "is less than"
        case .lessThanOrEqual: return "is at most"
        }
    }
}

/// One condition in a smart playlist's rule set — e.g. "Rating is at
/// least 8" or "Genre contains Jazz". A playlist's `smartMatchAll`
/// decides whether every rule must match (AND) or just one (OR).
public struct SmartRule: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var field: SmartRuleField
    public var comparison: SmartRuleComparison
    public var value: String

    public init(id: UUID = UUID(), field: SmartRuleField, comparison: SmartRuleComparison, value: String) {
        self.id = id
        self.field = field
        self.comparison = comparison
        self.value = value
    }

    /// - Parameter albumTotalPlays: every album's summed play count (see
    ///   `LibraryModel.albumTotalPlays`) — needed only for the one field
    ///   (`.albumTotalPlays`) that describes the track's *album* rather
    ///   than the track itself; every other field reads straight off
    ///   `track`. Defaults to empty, so a rule using any other field still
    ///   works without a caller having to compute this first.
    public func matches(_ track: Track, albumTotalPlays: [String: Double] = [:]) -> Bool {
        let trimmedValue = value.trimmingCharacters(in: .whitespaces)
        guard !trimmedValue.isEmpty else { return false }

        if field.isNumeric {
            guard let target = Double(trimmedValue), let actual = numericValue(for: track, albumTotalPlays: albumTotalPlays) else { return false }
            switch comparison {
            case .equals: return actual == target
            case .notEquals: return actual != target
            case .greaterThan: return actual > target
            case .greaterThanOrEqual: return actual >= target
            case .lessThan: return actual < target
            case .lessThanOrEqual: return actual <= target
            case .contains, .notContains, .beginsWith, .endsWith: return false
            }
        }

        if field == .tags {
            let needle = trimmedValue.lowercased()
            let tags = Set(track.tags.map { $0.lowercased() })
            switch comparison {
            case .contains, .equals: return tags.contains(needle)
            case .notContains, .notEquals: return !tags.contains(needle)
            case .beginsWith, .endsWith, .greaterThan, .greaterThanOrEqual, .lessThan, .lessThanOrEqual: return false
            }
        }

        let needle = trimmedValue.lowercased()
        let haystack = textValue(for: track).lowercased()
        switch comparison {
        case .contains: return haystack.contains(needle)
        case .notContains: return !haystack.contains(needle)
        case .equals: return haystack == needle
        case .notEquals: return haystack != needle
        case .beginsWith: return haystack.hasPrefix(needle)
        case .endsWith: return haystack.hasSuffix(needle)
        case .greaterThan, .greaterThanOrEqual, .lessThan, .lessThanOrEqual: return false
        }
    }

    private func numericValue(for track: Track, albumTotalPlays: [String: Double]) -> Double? {
        switch field {
        case .year: return track.year.map(Double.init)
        case .trackNumber: return track.trackNumber.map(Double.init)
        case .discNumber: return track.discNumber.map(Double.init)
        case .bpm: return track.bpm.map(Double.init)
        case .rating: return Double(track.rating)
        case .playCount: return track.playCount
        case .albumTotalPlays: return albumTotalPlays[track.album] ?? 0
        case .title, .artist, .album, .genre, .key, .comments, .tags: return nil
        }
    }

    private func textValue(for track: Track) -> String {
        switch field {
        case .title: return track.title
        case .artist: return track.artist
        case .album: return track.album
        case .genre: return track.genre
        case .key: return track.key ?? ""
        case .comments: return track.comments ?? ""
        case .tags, .year, .trackNumber, .discNumber, .bpm, .rating, .playCount, .albumTotalPlays: return ""
        }
    }
}
