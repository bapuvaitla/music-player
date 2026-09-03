import Foundation
import AppKit
import MusicPlayerKit

setbuf(stdout, nil)

func makeTestPNG(size: NSSize, color: NSColor) -> Data {
    let image = NSImage(size: size)
    image.lockFocus()
    color.setFill()
    NSRect(origin: .zero, size: size).fill()
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        fail("failed to synthesize a test PNG")
    }
    return png
}

let testDir = URL(fileURLWithPath: CommandLine.arguments[1])

func fail(_ message: String) -> Never {
    print("FAIL: \(message)")
    exit(1)
}

func check(_ condition: Bool, _ message: String) {
    if !condition { fail(message) }
}

Task { @MainActor in
    let dbPath = NSTemporaryDirectory() + "regressiontest-\(UUID().uuidString).sqlite"
    let store = try! GRDBLocalStore(databaseURL: URL(fileURLWithPath: dbPath))
    let library = LibraryModel(ratingStore: store, playlistStore: store)

    // MARK: - Multi-folder merge (previously a real bug: adding a folder
    // wiped tracks from folders added earlier instead of merging).
    let rockDir = testDir.appendingPathComponent("Rock")
    let jazzDir = testDir.appendingPathComponent("Jazz")
    let electronicDir = testDir.appendingPathComponent("Electronic")

    _ = await library.addFolder(rockDir)
    let rockTitlesAfterRock = Set(library.visibleTracks.map { $0.title })
    check(!rockTitlesAfterRock.isEmpty, "after adding Rock, some tracks should be present")

    _ = await library.addFolder(jazzDir)
    let titlesAfterJazz = Set(library.visibleTracks.map { $0.title })
    check(rockTitlesAfterRock.isSubset(of: titlesAfterJazz), "adding Jazz folder should not wipe out tracks from Rock")
    check(titlesAfterJazz.count > rockTitlesAfterRock.count, "after adding Jazz, new tracks should be present")

    _ = await library.addFolder(electronicDir)
    check(library.visibleTracks.count == 6, "expected all 6 tracks across 3 folders after merge, got \(library.visibleTracks.count)")
    print("PASS: multi-folder merge (\(library.visibleTracks.count) tracks across Rock/Jazz/Electronic)")

    // MARK: - Importing individual files (not a whole folder) — a separate
    // library instance so this doesn't interact with the folder-merge
    // tracks above.
    let filesStore = try! GRDBLocalStore(databaseURL: URL(fileURLWithPath: NSTemporaryDirectory() + "regressiontest-files-\(UUID().uuidString).sqlite"))
    let filesLibrary = LibraryModel(ratingStore: filesStore, playlistStore: filesStore)
    let pickedFiles = [
        rockDir.appendingPathComponent("AlbumA/track1.m4a"),
        jazzDir.appendingPathComponent("AlbumB/track4.mp3")
    ]
    let importedCount = await filesLibrary.addFiles(pickedFiles)
    check(importedCount == 2, "expected 2 individually-imported tracks, got \(importedCount)")
    check(filesLibrary.visibleTracks.count == 2, "library should contain exactly the 2 imported files, got \(filesLibrary.visibleTracks.count)")
    // Not asserting scannedFolderPaths is empty: it's backed by shared
    // UserDefaults, so it can carry over folders the `library` instance
    // above already registered in this same process. What we actually
    // care about is that addFiles didn't register these files' parent
    // folders as newly watched.
    check(!filesLibrary.scannedFolderPaths.contains(rockDir.appendingPathComponent("AlbumA").path), "importing a file shouldn't register its parent folder as watched")
    check(!filesLibrary.scannedFolderPaths.contains(jazzDir.appendingPathComponent("AlbumB").path), "importing a file shouldn't register its parent folder as watched")
    print("PASS: import individual files without a folder (\(importedCount) tracks)")

    guard let m4aTrack = library.visibleTracks.first(where: { $0.path.hasSuffix(".m4a") }) else {
        fail("need an m4a test track with artwork")
    }
    guard let wavTrack = library.visibleTracks.first(where: { $0.path.hasSuffix(".wav") }) else {
        fail("need a wav test track")
    }

    // MARK: - Hidden tracks (excluded from browsing, but still counted
    // toward album rating averages).
    library.setRating(8, for: m4aTrack)
    let albumOfHidden = m4aTrack.album
    library.setHidden(true, for: m4aTrack)
    check(!library.visibleTracks.contains { $0.path == m4aTrack.path }, "hidden track should be excluded from visibleTracks")
    let avgWithHidden = library.albumAverageRatings[albumOfHidden]
    check(avgWithHidden != nil, "hidden track's rating should still count toward album average")
    library.unhideAllTracks(inAlbum: albumOfHidden)
    check(library.visibleTracks.contains { $0.path == m4aTrack.path }, "unhideAllTracks should restore the track")
    print("PASS: hidden tracks (excluded from browsing, retained in album rating average, restorable)")

    // MARK: - Deleting a real (file-backed) track: unlike Hide, this must
    // survive a rescan — the file is still on disk and would otherwise
    // just get found again. Uses its own library/store instance so it
    // doesn't disturb tracks the tests below still depend on.
    let deleteTestStore = try! GRDBLocalStore(databaseURL: URL(fileURLWithPath: NSTemporaryDirectory() + "regressiontest-delete-\(UUID().uuidString).sqlite"))
    let deleteTestLibrary = LibraryModel(ratingStore: deleteTestStore, playlistStore: deleteTestStore)
    _ = await deleteTestLibrary.addFolder(rockDir)
    guard let trackToDelete = deleteTestLibrary.visibleTracks.first else {
        fail("expected at least one track in Rock for the delete test")
    }
    let deletedPath = trackToDelete.path
    deleteTestLibrary.deleteTrack(trackToDelete)
    check(!deleteTestLibrary.tracks.contains { $0.path == deletedPath }, "deleted track should be gone immediately")

    await deleteTestLibrary.rescanAllFolders()
    check(!deleteTestLibrary.tracks.contains { $0.path == deletedPath }, "deleted track should not reappear after rescanning the same folder")
    print("PASS: deleting a real track survives a rescan (unlike Hide)")

    // MARK: - Batch metadata editing across multiple tracks.
    let batchTargets = Array(library.visibleTracks.prefix(2))
    library.batchUpdateMetadata(
        for: batchTargets,
        title: "",
        artist: "Batch Artist",
        album: "",
        genre: "",
        year: nil,
        trackNumber: nil,
        discNumber: nil,
        bpm: nil,
        key: "",
        comments: "",
        addTags: ["batch-tagged"]
    )
    for target in batchTargets {
        guard let updated = library.visibleTracks.first(where: { $0.path == target.path }) else {
            fail("batch-edited track disappeared from library")
        }
        check(updated.artist == "Batch Artist", "batch edit should set artist on \(updated.title)")
        check(updated.tags.contains("batch-tagged"), "batch edit should add tag on \(updated.title)")
    }
    print("PASS: batch metadata editing across \(batchTargets.count) tracks")

    // MARK: - Playlists: create, add tracks, reorder, smart playlist by tag.
    library.createPlaylist(name: "Regression Playlist")
    guard let playlist = library.playlists.first(where: { $0.name == "Regression Playlist" }) else {
        fail("created playlist not found after loadPlaylists")
    }
    let playlistTracks = Array(library.visibleTracks.prefix(3))
    for track in playlistTracks {
        library.addTrack(track, toPlaylistID: playlist.id)
    }
    guard let refreshedPlaylist = library.playlists.first(where: { $0.id == playlist.id }) else {
        fail("playlist disappeared after adding tracks")
    }
    check(refreshedPlaylist.trackPaths.count == 3, "expected 3 tracks in playlist, got \(refreshedPlaylist.trackPaths.count)")
    let firstPathBeforeMove = refreshedPlaylist.trackPaths[0]
    library.moveTracks(inPlaylistID: playlist.id, from: IndexSet(integer: 0), to: 3)
    guard let reorderedPlaylist = library.playlists.first(where: { $0.id == playlist.id }) else {
        fail("playlist disappeared after reorder")
    }
    check(reorderedPlaylist.trackPaths.last == firstPathBeforeMove, "moveTracks should move the first track to the end")
    print("PASS: playlist create/add/reorder")

    library.createSmartPlaylist(
        name: "Batch Tagged",
        rules: [SmartRule(field: .tags, comparison: .contains, value: "batch-tagged")],
        matchAll: true
    )
    guard let smartPlaylist = library.playlists.first(where: { $0.name == "Batch Tagged" }) else {
        fail("smart playlist not found after loadPlaylists")
    }
    let resolved = library.resolvedTracks(for: smartPlaylist)
    check(resolved.count == batchTargets.count, "smart playlist should resolve to the \(batchTargets.count) batch-tagged tracks, got \(resolved.count)")

    // MARK: - Smart playlist rules on non-tag fields (rating, artist, year,
    // etc.) — the point of this whole feature.
    library.setRating(10, for: batchTargets[0])
    library.createSmartPlaylist(
        name: "Top Rated",
        rules: [SmartRule(field: .rating, comparison: .greaterThanOrEqual, value: "10")],
        matchAll: true
    )
    guard let topRatedPlaylist = library.playlists.first(where: { $0.name == "Top Rated" }) else {
        fail("Top Rated smart playlist not found")
    }
    let topRatedResolved = library.resolvedTracks(for: topRatedPlaylist)
    check(topRatedResolved.contains { $0.path == batchTargets[0].path }, "rating>=10 rule should match the track just rated 10")
    check(!topRatedResolved.contains { $0.path == m4aTrack.path } || m4aTrack.rating >= 10, "rating>=10 rule should exclude tracks rated below 10")

    library.createSmartPlaylist(
        name: "Multi Rule Any",
        rules: [
            SmartRule(field: .artist, comparison: .equals, value: "Batch Artist"),
            SmartRule(field: .genre, comparison: .contains, value: "nonexistent-genre-xyz")
        ],
        matchAll: false
    )
    guard let anyRulePlaylist = library.playlists.first(where: { $0.name == "Multi Rule Any" }) else {
        fail("Multi Rule Any smart playlist not found")
    }
    let anyRuleResolved = library.resolvedTracks(for: anyRulePlaylist)
    check(anyRuleResolved.contains { $0.artist == "Batch Artist" }, "match-any should include tracks satisfying just the artist rule")
    print("PASS: smart playlist rules on non-tag fields (rating >=, artist equals, match-any)")
    print("PASS: smart playlist resolves by tag (\(resolved.count) matches)")

    // Give the fire-and-forget persistence Tasks a moment to land, then
    // verify playlists actually round-trip through the SQLite store.
    try? await Task.sleep(nanoseconds: 300_000_000)
    let reloadedStore = try! GRDBLocalStore(databaseURL: URL(fileURLWithPath: dbPath))
    let reloadedLibrary = LibraryModel(ratingStore: reloadedStore, playlistStore: reloadedStore)
    await reloadedLibrary.loadPlaylists()
    check(reloadedLibrary.playlists.contains { $0.name == "Regression Playlist" }, "playlist should persist to disk and survive a reload")
    check(reloadedLibrary.playlists.contains { $0.name == "Batch Tagged" }, "smart playlist should persist to disk and survive a reload")
    print("PASS: playlists persist across a fresh store reload")

    // MARK: - Rewind-aware play counting: replaying part of a track should
    // accumulate real listening seconds, not just credit final playhead
    // position.
    let player = PlayerController()
    let coordinator = PlaybackCoordinator(player: player)
    var recordedFraction: Double?
    player.onFractionalPlay = { _, fraction in recordedFraction = fraction }

    player.play(track: wavTrack)
    try? await Task.sleep(nanoseconds: 1_600_000_000)
    player.seek(to: 0)
    try? await Task.sleep(nanoseconds: 1_600_000_000)
    player.stop()
    try? await Task.sleep(nanoseconds: 200_000_000)

    guard let fraction = recordedFraction else {
        fail("expected onFractionalPlay to fire after playing and rewinding")
    }
    check(fraction > 0, "recorded play fraction should be positive, got \(fraction)")
    print("PASS: rewind-aware play counting (accumulated fraction: \(String(format: "%.3f", fraction)))")

    // MARK: - Artwork overrides: replacing a track's cover locally (never
    // touching the file), ArtworkLoader preferring it over embedded
    // artwork, and clearing it reverting back.
    guard let embeddedArtwork = await ArtworkLoader.shared.artwork(for: m4aTrack) else {
        fail("expected the m4a test track to have embedded artwork before any override")
    }
    let customArtwork = makeTestPNG(size: NSSize(width: 4, height: 4), color: .red)
    library.setArtworkOverride(customArtwork, for: [m4aTrack])
    try? await Task.sleep(nanoseconds: 300_000_000)
    guard let overriddenArtwork = await ArtworkLoader.shared.artwork(for: m4aTrack) else {
        fail("expected artwork to resolve after setting an override")
    }
    check(overriddenArtwork.size != embeddedArtwork.size, "overridden artwork should differ from the original embedded artwork")

    library.setArtworkOverride(nil, for: [m4aTrack])
    try? await Task.sleep(nanoseconds: 300_000_000)
    guard let revertedArtwork = await ArtworkLoader.shared.artwork(for: m4aTrack) else {
        fail("expected artwork to resolve after clearing the override")
    }
    check(revertedArtwork.size == embeddedArtwork.size, "clearing the override should revert to the original embedded artwork")
    print("PASS: artwork override replace/reset (never touches the file)")

    // MARK: - Replacing a track's backing file: rating/tags/playlist
    // membership should migrate from the old path to the new one, and the
    // track's metadata should reflect the new file, not the old one.
    guard let aiffTrack = library.visibleTracks.first(where: { $0.path.hasSuffix(".aiff") && $0.path.contains("AlbumA") }) else {
        fail("need an aiff test track in AlbumA")
    }
    guard let flacTrack = library.visibleTracks.first(where: { $0.path.hasSuffix(".flac") }) else {
        fail("need a flac test track to swap in")
    }
    let oldPath = aiffTrack.path
    library.setRating(7, for: aiffTrack)
    library.createPlaylist(name: "Replace File Test")
    guard let replacePlaylist = library.playlists.first(where: { $0.name == "Replace File Test" }) else {
        fail("created playlist not found")
    }
    library.addTrack(aiffTrack, toPlaylistID: replacePlaylist.id)

    guard let replaced = await library.replaceFile(for: aiffTrack, withNewFile: flacTrack.url) else {
        fail("replaceFile should return the updated track")
    }
    check(replaced.path == flacTrack.url.path, "replaced track's path should now point at the new file, got \(replaced.path)")
    check(replaced.rating == 7, "rating should carry over to the new path, got \(replaced.rating)")
    check(!library.visibleTracks.contains { $0.path == oldPath }, "old path should no longer be present in the library")
    check(library.visibleTracks.contains { $0.path == replaced.path }, "new path should be present in the library")
    guard let updatedPlaylist = library.playlists.first(where: { $0.id == replacePlaylist.id }) else {
        fail("playlist disappeared after file replacement")
    }
    check(updatedPlaylist.trackPaths.contains(replaced.path), "playlist should reference the new path after file replacement")
    check(!updatedPlaylist.trackPaths.contains(oldPath), "playlist should no longer reference the old path")
    print("PASS: replaceFile migrates rating and playlist membership to the new path")

    // MARK: - Placeholder tracks: file-less, manually-entered tracks for
    // rating a song you don't own — created via the sidebar's "Add
    // Track…", editable/ratable like any other, unplayable, grayed out,
    // and (unlike overrides) persisted as their own complete record since
    // there's no file scan to reapply them to.
    let placeholderAlbum = m4aTrack.album
    let referenceArtist = library.visibleTracks.first(where: { $0.album == placeholderAlbum })?.artist ?? ""
    let placeholder = library.createPlaceholderTrack(album: placeholderAlbum)
    check(placeholder.isPlaceholder, "created track should be marked as a placeholder")
    check(placeholder.album == placeholderAlbum, "placeholder should be created in the requested album")
    check(placeholder.artist == referenceArtist, "placeholder should prefill artist from an existing track in the album")
    check(library.visibleTracks.contains { $0.path == placeholder.path }, "placeholder should appear in visibleTracks like any other track")

    library.updateMetadata(
        for: placeholder,
        title: "Unowned Bonus Track",
        artist: placeholder.artist,
        album: placeholder.album,
        genre: placeholder.genre,
        year: nil, trackNumber: nil, discNumber: nil, bpm: nil,
        key: "", comments: "", tags: []
    )
    library.setRating(9, for: placeholder)
    guard let editedPlaceholder = library.visibleTracks.first(where: { $0.path == placeholder.path }) else {
        fail("placeholder disappeared after editing")
    }
    check(editedPlaceholder.title == "Unowned Bonus Track", "placeholder title should reflect the edit")
    check(editedPlaceholder.rating == 9, "placeholder rating should be settable like any other track")
    check((library.albumAverageRatings[placeholderAlbum] ?? 0) > 0, "placeholder's rating should count toward its album's average")

    // Attempting to "play" a placeholder must be a safe no-op, not a crash
    // or an attempt to open a bogus file.
    let placeholderPlayer = PlayerController()
    placeholderPlayer.play(track: editedPlaceholder)
    check(placeholderPlayer.currentTrack == nil, "playing a placeholder track should be a no-op")
    check(!placeholderPlayer.isPlaying, "playing a placeholder track should not start playback")

    try? await Task.sleep(nanoseconds: 300_000_000)
    let placeholderReloadStore = try! GRDBLocalStore(databaseURL: URL(fileURLWithPath: dbPath))
    let placeholderReloadLibrary = LibraryModel(ratingStore: placeholderReloadStore, playlistStore: placeholderReloadStore)
    await placeholderReloadLibrary.loadPlaceholderTracks()
    guard let reloadedPlaceholder = placeholderReloadLibrary.tracks.first(where: { $0.path == placeholder.path }) else {
        fail("placeholder should survive a fresh store reload")
    }
    check(reloadedPlaceholder.title == "Unowned Bonus Track", "reloaded placeholder should keep its edited title")
    check(reloadedPlaceholder.rating == 9, "reloaded placeholder should keep its rating")
    check(reloadedPlaceholder.isPlaceholder, "reloaded track should still be marked as a placeholder")

    library.deletePlaceholderTrack(placeholder)
    check(!library.tracks.contains { $0.path == placeholder.path }, "deleted placeholder should be gone from the in-memory library")
    try? await Task.sleep(nanoseconds: 300_000_000)
    let afterDeleteStore = try! GRDBLocalStore(databaseURL: URL(fileURLWithPath: dbPath))
    let afterDeleteLibrary = LibraryModel(ratingStore: afterDeleteStore, playlistStore: afterDeleteStore)
    await afterDeleteLibrary.loadPlaceholderTracks()
    check(!afterDeleteLibrary.tracks.contains { $0.path == placeholder.path }, "deleted placeholder should not come back after a reload")
    print("PASS: placeholder tracks (create/edit/rate, unplayable, persist, delete)")

    // MARK: - A newly-created placeholder must NOT be persisted until an
    // actual edit (Save) happens — abandoning "Add Track" without saving
    // shouldn't leave a stray empty row behind after a relaunch.
    let unsavedPlaceholder = library.createPlaceholderTrack(album: placeholderAlbum)
    check(library.tracks.contains { $0.path == unsavedPlaceholder.path }, "unsaved placeholder should still exist in-memory right after creation")
    try? await Task.sleep(nanoseconds: 300_000_000)
    let unsavedCheckStore = try! GRDBLocalStore(databaseURL: URL(fileURLWithPath: dbPath))
    let unsavedCheckLibrary = LibraryModel(ratingStore: unsavedCheckStore, playlistStore: unsavedCheckStore)
    await unsavedCheckLibrary.loadPlaceholderTracks()
    check(!unsavedCheckLibrary.tracks.contains { $0.path == unsavedPlaceholder.path }, "never-saved placeholder should not appear after a reload")
    library.deletePlaceholderTrack(unsavedPlaceholder)
    print("PASS: an un-saved placeholder track is never persisted")

    // MARK: - Media key controller: construct it, play a track with
    // embedded artwork, and drive the artwork-loading + state-change paths
    // that previously crashed with a Swift concurrency actor-isolation
    // trap inside MPMediaItemArtwork's request handler.
    print("Constructing MediaKeyController (registers MPRemoteCommandCenter + observes player state)...")
    let mediaKeyController = MediaKeyController(player: player, coordinator: coordinator, library: library)
    _ = mediaKeyController

    print("Playing track with embedded artwork: \(m4aTrack.title)")
    player.play(track: m4aTrack)
    try? await Task.sleep(nanoseconds: 1_500_000_000)
    print("Still alive after artwork load + MPNowPlayingInfoCenter update.")

    player.togglePlayPause()
    try? await Task.sleep(nanoseconds: 300_000_000)
    player.togglePlayPause()
    try? await Task.sleep(nanoseconds: 300_000_000)

    player.stop()
    try? await Task.sleep(nanoseconds: 300_000_000)
    print("PASS: media keys / Now Playing integration (no crash through play/pause/artwork-load/stop)")

    print("ALL TESTS PASSED")
    exit(0)
}

RunLoop.main.run()
