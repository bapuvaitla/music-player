import Foundation
import AVFoundation

public enum LibraryScanner {
    public static let supportedExtensions: Set<String> = ["mp3", "flac", "m4a", "aac", "wav", "aiff", "aif"]

    private static let genreIdentifiers: [AVMetadataIdentifier] = [
        .id3MetadataContentType,
        .iTunesMetadataUserGenre,
        .iTunesMetadataPredefinedGenre,
        .quickTimeMetadataGenre,
        AVMetadataIdentifier(rawValue: "vorb/GENRE")
    ]

    private static let yearIdentifiers: [AVMetadataIdentifier] = [
        AVMetadataIdentifier(rawValue: "id3/TDRC"),
        AVMetadataIdentifier(rawValue: "id3/TYER"),
        AVMetadataIdentifier(rawValue: "itsk/©day"),
        AVMetadataIdentifier(rawValue: "vorb/DATE"),
        AVMetadataIdentifier(rawValue: "vorb/YEAR")
    ]

    private static let trackNumberIdentifiers: [AVMetadataIdentifier] = [
        AVMetadataIdentifier(rawValue: "id3/TRCK"),
        AVMetadataIdentifier(rawValue: "itsk/trkn"),
        AVMetadataIdentifier(rawValue: "vorb/TRACKNUMBER")
    ]

    private static let discNumberIdentifiers: [AVMetadataIdentifier] = [
        AVMetadataIdentifier(rawValue: "id3/TPOS"),
        AVMetadataIdentifier(rawValue: "itsk/disk"),
        AVMetadataIdentifier(rawValue: "vorb/DISCNUMBER")
    ]

    private static let bpmIdentifiers: [AVMetadataIdentifier] = [
        AVMetadataIdentifier(rawValue: "id3/TBPM"),
        AVMetadataIdentifier(rawValue: "itsk/tmpo"),
        AVMetadataIdentifier(rawValue: "vorb/BPM")
    ]

    private static let keyIdentifiers: [AVMetadataIdentifier] = [
        AVMetadataIdentifier(rawValue: "id3/TKEY"),
        AVMetadataIdentifier(rawValue: "itsk/©key"),
        AVMetadataIdentifier(rawValue: "vorb/INITIALKEY"),
        AVMetadataIdentifier(rawValue: "vorb/KEY")
    ]

    private static let commentIdentifiers: [AVMetadataIdentifier] = [
        AVMetadataIdentifier(rawValue: "id3/COMM"),
        AVMetadataIdentifier(rawValue: "itsk/©cmt"),
        AVMetadataIdentifier(rawValue: "vorb/COMMENT")
    ]

    public static func scan(
        rootURL: URL,
        concurrency: Int = 6,
        progress: (@Sendable (_ completed: Int, _ total: Int) -> Void)? = nil
    ) async -> [Track] {
        await loadTracks(from: enumerateAudioFiles(at: rootURL), concurrency: concurrency, progress: progress)
    }

    /// Same as `scan(rootURL:)`, but for individually-picked files rather
    /// than a folder to walk — e.g. importing single tracks instead of a
    /// whole album folder. Non-audio files (by extension) are silently
    /// skipped rather than treated as an error.
    public static func scanFiles(
        _ urls: [URL],
        concurrency: Int = 6,
        progress: (@Sendable (_ completed: Int, _ total: Int) -> Void)? = nil
    ) async -> [Track] {
        let audioURLs = urls.filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
        return await loadTracks(from: audioURLs, concurrency: concurrency, progress: progress)
    }

    private static func loadTracks(
        from fileURLs: [URL],
        concurrency: Int,
        progress: (@Sendable (_ completed: Int, _ total: Int) -> Void)?
    ) async -> [Track] {
        guard !fileURLs.isEmpty else { return [] }

        var tracks: [Track] = []
        tracks.reserveCapacity(fileURLs.count)

        await withTaskGroup(of: Track.self) { group in
            var iterator = fileURLs.makeIterator()

            func addNext() {
                if let url = iterator.next() {
                    group.addTask { await loadTrack(from: url) }
                }
            }

            for _ in 0..<concurrency {
                addNext()
            }

            var completed = 0
            while let track = await group.next() {
                completed += 1
                tracks.append(track)
                progress?(completed, fileURLs.count)
                addNext()
            }
        }

        return tracks.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private static func enumerateAudioFiles(at root: URL) -> [URL] {
        var results: [URL] = []
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else { return results }

        for case let url as URL in enumerator {
            if supportedExtensions.contains(url.pathExtension.lowercased()) {
                results.append(url)
            }
        }
        return results
    }

    private static func loadTrack(from url: URL) async -> Track {
        let fallbackTitle = url.deletingPathExtension().lastPathComponent
        let asset = AVURLAsset(url: url)

        let duration: TimeInterval
        do {
            let cmDuration = try await asset.load(.duration)
            duration = cmDuration.isNumeric ? cmDuration.seconds : 0
        } catch {
            duration = 0
        }

        var items: [AVMetadataItem] = []
        do {
            items = try await asset.load(.metadata)
        } catch {
            items = []
        }

        var title = await string(in: items, commonKey: .commonKeyTitle) ?? ""
        var artist = await string(in: items, commonKey: .commonKeyArtist) ?? ""
        let album = await string(in: items, commonKey: .commonKeyAlbumName) ?? ""
        var genre = await string(in: items, identifiers: genreIdentifiers) ?? ""

        if title.isEmpty { title = fallbackTitle }
        if artist.isEmpty { artist = "Unknown Artist" }
        if genre.isEmpty { genre = "Unknown Genre" }

        let yearString = await string(in: items, identifiers: yearIdentifiers)
        let trackNumberString = await string(in: items, identifiers: trackNumberIdentifiers)
        let discNumberString = await string(in: items, identifiers: discNumberIdentifiers)
        let bpmString = await string(in: items, identifiers: bpmIdentifiers)
        let key = await string(in: items, identifiers: keyIdentifiers)
        let comments = await string(in: items, identifiers: commentIdentifiers)

        return Track(
            path: url.path,
            title: title,
            artist: artist,
            album: album.isEmpty ? "Unknown Album" : album,
            genre: genre,
            duration: duration,
            year: parseLeadingYear(yearString),
            trackNumber: parseLeadingInt(trackNumberString),
            discNumber: parseLeadingInt(discNumberString),
            bpm: parseLeadingInt(bpmString),
            key: (key?.isEmpty ?? true) ? nil : key,
            comments: (comments?.isEmpty ?? true) ? nil : comments
        )
    }

    /// Parses "9/10" or "9" style track/disc numbers, taking the leading integer.
    private static func parseLeadingInt(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        let leading = raw.split(separator: "/").first.map(String.init) ?? raw
        let digits = leading.trimmingCharacters(in: .whitespaces)
        if let intValue = Int(digits) { return intValue }
        if let doubleValue = Double(digits) { return Int(doubleValue.rounded()) }
        return nil
    }

    /// Parses a leading 4-digit year out of strings like "1979-10-02" or "1979".
    private static func parseLeadingYear(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        let digits = raw.prefix(while: { $0.isNumber })
        guard digits.count >= 4 else { return nil }
        return Int(digits.prefix(4))
    }

    private static func string(in items: [AVMetadataItem], commonKey: AVMetadataKey) async -> String? {
        for item in items where item.commonKey == commonKey {
            let loaded = (try? await item.load(.stringValue)) ?? nil
            if let value = loaded, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func string(in items: [AVMetadataItem], identifiers: [AVMetadataIdentifier]) async -> String? {
        for identifier in identifiers {
            for item in items where item.identifier == identifier {
                let loaded = (try? await item.load(.stringValue)) ?? nil
                if let value = loaded, !value.isEmpty {
                    return value
                }
            }
        }
        return nil
    }
}
