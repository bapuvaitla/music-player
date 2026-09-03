import Foundation
import AVFoundation
#if canImport(AppKit)
import AppKit
#endif

/// Lazily loads and caches embedded album artwork per file path. Kept
/// separate from `LibraryScanner` so a full library scan never has to
/// decode every track's artwork up front — only the track that's actually
/// playing pays that cost.
public actor ArtworkLoader {
    public static let shared = ArtworkLoader()

    private var cache: [String: NSImage?] = [:]
    private var store: RatingStore?

    /// Wires up the store to check for a locally-replaced cover image
    /// before falling back to a track's embedded artwork. Call once at
    /// launch, after the app's store is constructed.
    public func configure(store: RatingStore) {
        self.store = store
    }

    public func artwork(for track: Track) async -> NSImage? {
        if let cached = cache[track.path] {
            return cached
        }

        let image = await resolveArtwork(for: track)
        cache[track.path] = image
        return image
    }

    /// Drops the cached image for a path so the next `artwork(for:)` call
    /// re-resolves it — call after replacing or clearing a track's
    /// artwork override.
    public func invalidate(path: String) {
        cache[path] = nil
    }

    /// A track's embedded artwork specifically, ignoring any stored
    /// override — used to preview what "Reset to Embedded" would revert
    /// to, before that choice is actually saved. Not cached: this is only
    /// used for that occasional interactive preview, not the hot path.
    public func embeddedArtwork(for track: Track) async -> NSImage? {
        await Self.loadArtwork(from: track.url)
    }

    private func resolveArtwork(for track: Track) async -> NSImage? {
        if let store,
           let overrideData = try? await store.artworkOverride(forPath: track.path),
           let image = NSImage(data: overrideData) {
            return image
        }
        return await Self.loadArtwork(from: track.url)
    }

    private static func loadArtwork(from url: URL) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.metadata) else { return nil }

        for item in items where item.commonKey == .commonKeyArtwork {
            if let data = (try? await item.load(.dataValue)) ?? nil, let image = NSImage(data: data) {
                return image
            }
        }
        return nil
    }
}
