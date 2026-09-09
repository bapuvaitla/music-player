import Foundation
import AppKit
import MusicPlayerKit

setbuf(stdout, nil)

// LibraryModel persists a handful of things (scannedFolderPaths,
// additionalTrackPaths, column layout, etc.) to UserDefaults.standard,
// which — unlike the scratch SQLite/JSON files this suite creates fresh
// each run — is a real, persistent, global store that survives across
// separate `swift run ScanTest` invocations. Without resetting it here,
// a relaunch-persistence assertion further down would silently
// accumulate stale paths from every previous run of this binary on this
// machine.
for key in ["scannedFolderPaths", "additionalTrackPaths"] {
    UserDefaults.standard.removeObject(forKey: key)
}

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

// MARK: - MusicXML parsing (Learn Song feature): a small hand-written tab
// fixture (chord grouping, string/fret, sharps) and vocal fixture (rests,
// tempo/divisions scaling, title).

let testTabXML = """
<?xml version="1.0" encoding="UTF-8"?>
<score-partwise version="3.1">
  <work><work-title>Test Tab</work-title></work>
  <part id="P1">
    <measure number="1">
      <attributes><divisions>1</divisions></attributes>
      <direction><sound tempo="60"/></direction>
      <note>
        <pitch><step>E</step><octave>2</octave></pitch>
        <duration>1</duration>
        <notations>
          <hammer-on type="start" number="1"/>
          <technical><string>6</string><fret>0</fret></technical>
        </notations>
      </note>
      <note>
        <pitch><step>F</step><octave>2</octave><alter>1</alter></pitch>
        <duration>1</duration>
        <notations>
          <hammer-on type="stop" number="1"/>
          <technical><string>6</string><fret>2</fret></technical>
        </notations>
      </note>
      <note>
        <pitch><step>A</step><octave>2</octave></pitch>
        <duration>1</duration>
        <notations><technical><string>5</string><fret>0</fret></technical></notations>
      </note>
      <note>
        <chord/>
        <pitch><step>E</step><octave>3</octave></pitch>
        <duration>1</duration>
        <notations><technical><string>4</string><fret>2</fret></technical></notations>
      </note>
    </measure>
    <measure number="2">
      <note>
        <pitch><step>G</step><octave>2</octave></pitch>
        <duration>1</duration>
        <notations><technical><string>6</string><fret>3</fret></technical></notations>
      </note>
    </measure>
  </part>
</score-partwise>
"""

let testVocalXML = """
<?xml version="1.0" encoding="UTF-8"?>
<score-partwise version="3.1">
  <work><work-title>Test Vocal</work-title></work>
  <part id="P1">
    <measure number="1">
      <attributes><divisions>2</divisions></attributes>
      <direction><sound tempo="120"/></direction>
      <note>
        <pitch><step>C</step><octave>4</octave></pitch>
        <duration>2</duration>
      </note>
      <note>
        <pitch><step>D</step><octave>4</octave></pitch>
        <duration>1</duration>
      </note>
      <note>
        <rest/>
        <duration>1</duration>
      </note>
      <note>
        <pitch><step>E</step><octave>4</octave></pitch>
        <duration>2</duration>
      </note>
    </measure>
  </part>
</score-partwise>
"""

let tabSequence = try! MusicXMLParser.parse(data: testTabXML.data(using: .utf8)!)
check(tabSequence.title == "Test Tab", "tab title should parse, got \(tabSequence.title ?? "nil")")
check(tabSequence.notes.count == 5, "expected 5 tab notes (incl. one chord note, across 2 measures), got \(tabSequence.notes.count)")
check(tabSequence.onsetTimes == [0, 1, 2, 3], "expected onsets at 0/1/2/3s (chord shares an onset, plus measure 2's note), got \(tabSequence.onsetTimes)")
guard let openLowE = tabSequence.notes.first(where: { $0.startTime == 0 }) else { fail("missing open low E note") }
check(openLowE.midiPitch == 40 && openLowE.string == 6 && openLowE.fret == 0, "open low E should be MIDI 40, string 6, fret 0 — got \(openLowE)")
guard let sharp = tabSequence.notes.first(where: { $0.startTime == 1 }) else { fail("missing F#2 note") }
check(sharp.midiPitch == 42, "alter (sharp) should be applied — expected F#2 = MIDI 42, got \(sharp.midiPitch)")
let chordNotes = tabSequence.notes(at: 2)
check(chordNotes.count == 2, "expected a 2-note chord at t=2s, got \(chordNotes.count)")
check(Set(chordNotes.map { $0.string }) == [5, 4], "chord notes should keep their own distinct string/fret, got \(chordNotes)")
print("PASS: MusicXML tab parsing (chord grouping, string/fret, sharps)")

// MARK: - Bar boundaries + hammer-on/pull-off/slide articulation, parsed
// from the same real MuseScore-exported structure (<measure> elements,
// <hammer-on>/<pull-off>/<slide> as siblings of <technical> inside
// <notations>, not nested inside it) confirmed against an actual
// MuseScore 4 tab export.
check(tabSequence.barStartTimes == [0, 3], "expected bar boundaries at 0s (measure 1) and 3s (measure 2), got \(tabSequence.barStartTimes)")
check(sharp.incomingArticulation == .hammerOn, "F#2 should carry the hammer-on 'stop' marker from the previous note, got \(String(describing: sharp.incomingArticulation))")
check(openLowE.incomingArticulation == nil, "the hammer-on's origin note itself shouldn't be marked as an incoming articulation")
check(tabSequence.barStart(before: 2.9) == 0, "barStart(before:) just before bar 2 should land on bar 1's start, got \(tabSequence.barStart(before: 2.9))")
check(tabSequence.barStart(before: 3.0) == 0, "sitting exactly at a bar start and going 'back' should land on the *previous* bar, got \(tabSequence.barStart(before: 3.0))")
check(tabSequence.barStart(after: 0.5) == 3, "barStart(after:) from partway through bar 1 should land on bar 2's start, got \(tabSequence.barStart(after: 0.5))")
check(tabSequence.barStart(after: 3.5) == tabSequence.duration, "barStart(after:) past the last bar should clamp to the sequence's end, got \(tabSequence.barStart(after: 3.5))")
print("PASS: bar boundaries + hammer-on/pull-off/slide articulation parsing")

// MARK: - NoteSequence.duration / averageBarLength must account for
// trailing rest-only bars — a real bug found against an actual MuseScore
// export where a guitar part rested for the back half of the piece:
// `duration` (built from note end times alone) undercounted badly,
// which fed a wildly wrong "average bar length" into the score view's
// bars-per-line estimate and made lines overflow with no way to scroll
// to the rest.
let trailingRestSequence = NoteSequence(
    notes: [ScoreNote(startTime: 0, duration: 1, midiPitch: 60)],
    barStartTimes: [0, 2, 4, 6, 8]
)
check(abs(trailingRestSequence.averageBarLength - 2.0) < 0.001, "average bar length should reflect actual bar-to-bar spacing (2.0s), got \(trailingRestSequence.averageBarLength)")
check(trailingRestSequence.duration >= 8.0, "duration should extend to cover trailing rest-only bars, not stop at the last sounding note, got \(trailingRestSequence.duration)")
print("PASS: NoteSequence.duration/averageBarLength account for trailing rest-only bars")

// MARK: - beatLabel: standard "1 e & a" rhythm count-off notation shown
// under the tab, and <time><beats> parsing that feeds it.
let beatTestSequence = NoteSequence(notes: [], barStartTimes: [0, 2], beatsPerBar: 4) // 2s bar, 4 beats -> 0.5s/beat
check(beatTestSequence.beatLabel(forStartTime: 0) == "1", "downbeat should read '1', got \(beatTestSequence.beatLabel(forStartTime: 0))")
check(beatTestSequence.beatLabel(forStartTime: 0.25) == "1&", "the off-beat halfway through beat 1 should read '1&', got \(beatTestSequence.beatLabel(forStartTime: 0.25))")
check(beatTestSequence.beatLabel(forStartTime: 0.125) == "1e", "the sixteenth before the off-beat should read '1e', got \(beatTestSequence.beatLabel(forStartTime: 0.125))")
check(beatTestSequence.beatLabel(forStartTime: 0.375) == "1a", "the sixteenth after the off-beat should read '1a', got \(beatTestSequence.beatLabel(forStartTime: 0.375))")
check(beatTestSequence.beatLabel(forStartTime: 0.5) == "2", "the second beat should read '2', got \(beatTestSequence.beatLabel(forStartTime: 0.5))")
check(beatTestSequence.beatLabel(forStartTime: 1.5) == "4", "the fourth beat should read '4', got \(beatTestSequence.beatLabel(forStartTime: 1.5))")

let beatsXML = """
<?xml version="1.0" encoding="UTF-8"?>
<score-partwise version="3.1">
  <part id="P1">
    <measure number="1">
      <attributes>
        <divisions>1</divisions>
        <time><beats>3</beats><beat-type>4</beat-type></time>
      </attributes>
      <note>
        <pitch><step>C</step><octave>4</octave></pitch>
        <duration>1</duration>
      </note>
    </measure>
  </part>
</score-partwise>
"""
let beatsSequence = try! MusicXMLParser.parse(data: beatsXML.data(using: .utf8)!)
check(beatsSequence.beatsPerBar == 3, "expected beatsPerBar=3 parsed from <time><beats>, got \(beatsSequence.beatsPerBar)")
print("PASS: beatLabel rhythm notation + <time><beats> parsing")

// MARK: - beatTimes: every bar's downbeat plus its interior beats, used
// for the loop-region scrub bar's "snap to bar/beat" drag behavior.
let beatTimesSequence = NoteSequence(notes: [], barStartTimes: [0, 2, 4], beatsPerBar: 4)
let expectedBeatTimes: [TimeInterval] = [0, 0.5, 1.0, 1.5, 2, 2.5, 3.0, 3.5, 4, 4.5, 5.0, 5.5]
check(beatTimesSequence.beatTimes == expectedBeatTimes, "expected every bar's downbeat + 3 interior beats, got \(beatTimesSequence.beatTimes)")
print("PASS: NoteSequence.beatTimes lists every bar/beat position for scrub-bar snapping")

let vocalSequence = try! MusicXMLParser.parse(data: testVocalXML.data(using: .utf8)!)
check(vocalSequence.notes.count == 3, "expected 3 vocal notes (rest produces none), got \(vocalSequence.notes.count)")
let vocalTimes = vocalSequence.notes.map { $0.startTime }
check(vocalTimes == [0, 0.5, 1.0], "divisions/tempo scaling + rest gap should give onsets at 0/0.5/1.0s, got \(vocalTimes)")
let vocalPitches = vocalSequence.notes.map { $0.midiPitch }
check(vocalPitches == [60, 62, 64], "expected C4/D4/E4 (60/62/64), got \(vocalPitches)")
check(vocalSequence.notes.allSatisfy { $0.string == nil && $0.fret == nil }, "vocal notes should carry no string/fret")
print("PASS: MusicXML vocal parsing (rests, tempo/divisions scaling)")

Task { @MainActor in
    do {
        try await generateFixtures(in: testDir)
    } catch {
        fail("failed to generate test fixtures in \(testDir.path): \(error)")
    }
    print("PASS: generated real audio test fixtures (m4a w/ artwork, aiff, wav, mp3, flac) under \(testDir.path)")

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
    // tracks above. Reset the shared-UserDefaults keys first (see the
    // file-top note) so the relaunch check below isn't contaminated by
    // `library`'s addFolder calls just above.
    for key in ["scannedFolderPaths", "additionalTrackPaths"] {
        UserDefaults.standard.removeObject(forKey: key)
    }
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

    // MARK: - Regression: individually-added files must survive a
    // relaunch. Previously only `addFolder`'s folders were remembered
    // (`scannedFolderPaths`) — anything added via `addFiles` (or, later,
    // `importKnownTracks`) vanished from the tracklist the moment the app
    // restarted, since `rescanAllFolders()` rebuilds `tracks` from
    // scratch at launch with nothing telling it to re-find these files.
    let relaunchedFilesLibrary = LibraryModel(ratingStore: filesStore, playlistStore: filesStore)
    await relaunchedFilesLibrary.rescanAllFolders()
    check(relaunchedFilesLibrary.visibleTracks.count == 2, "individually-added files should survive a relaunch (simulated: a fresh LibraryModel over the same store), got \(relaunchedFilesLibrary.visibleTracks.count)")
    print("PASS: addFiles-imported tracks survive a relaunch")

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

    // MARK: - Section looping (PlayerController.loopRegion, used by Learn
    // Song to loop part of a song while practicing).
    player.play(track: wavTrack)
    player.loopRegion = 0.2...0.6
    // wavTrack is ~1.65s; several loop cycles fit in this window, so
    // unlooped playback would be near the end by now while looped
    // playback stays contained near the region.
    try? await Task.sleep(nanoseconds: 1_500_000_000)
    check(player.isPlaying, "looped playback should still be playing, not have run to the end")
    check(player.currentTime <= 0.9, "currentTime should stay within the loop region (plus a timer tick's slop), got \(player.currentTime)")
    player.stop()

    player.play(track: wavTrack)
    check(player.loopRegion == nil, "loopRegion should reset automatically whenever a new track starts")
    player.stop()
    print("PASS: PlayerController.loopRegion loops a section; cleared automatically on a new track")

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

    // MARK: - NotePlaybackEngine (Learn Song): plays a synthetic note
    // sequence via the system's General MIDI sound bank without crashing,
    // including the volume-to-zero ("silent but still running") path.
    let playbackEngine = NotePlaybackEngine(midiProgram: 24)
    playbackEngine.load(NoteSequence(notes: [
        ScoreNote(startTime: 0, duration: 0.3, midiPitch: 40),
        ScoreNote(startTime: 0.3, duration: 0.3, midiPitch: 45),
        ScoreNote(startTime: 0.6, duration: 0.3, midiPitch: 50)
    ]))
    check(!playbackEngine.isPlaying, "engine should not be playing before play() is called")
    playbackEngine.play()
    check(playbackEngine.isPlaying, "engine should be playing right after play()")
    try? await Task.sleep(nanoseconds: 400_000_000)
    playbackEngine.volume = 0
    // Sequence is 0.9s total; already 0.4s in, so needs >0.5s more.
    try? await Task.sleep(nanoseconds: 700_000_000)
    check(!playbackEngine.isPlaying, "engine should auto-stop once the sequence finishes playing")
    playbackEngine.load(NoteSequence(notes: [ScoreNote(startTime: 0, duration: 0.2, midiPitch: 60)]))
    playbackEngine.play()
    try? await Task.sleep(nanoseconds: 100_000_000)
    playbackEngine.pause()
    check(!playbackEngine.isPlaying, "pause() should stop playback")
    playbackEngine.seek(to: 0)
    playbackEngine.stop()
    print("PASS: NotePlaybackEngine plays a synthetic sequence, including muted (volume 0) playback")

    // MARK: - NotePlaybackEngine.loopRegion: loops a section of the
    // tab/vocal playback, independent of (and mirroring) the song's own
    // loop region on PlayerController.
    let loopedNoteEngine = NotePlaybackEngine(midiProgram: 0)
    loopedNoteEngine.load(NoteSequence(notes: [
        ScoreNote(startTime: 0, duration: 0.2, midiPitch: 60),
        ScoreNote(startTime: 0.2, duration: 0.2, midiPitch: 62),
        ScoreNote(startTime: 0.4, duration: 0.2, midiPitch: 64),
        ScoreNote(startTime: 0.6, duration: 0.2, midiPitch: 65),
        ScoreNote(startTime: 0.8, duration: 0.2, midiPitch: 67)
    ]))
    loopedNoteEngine.loopRegion = 0.1...0.3
    loopedNoteEngine.play()
    // Full sequence is 1.0s; several loop cycles fit in 0.8s, so unlooped
    // playback would already be near the end.
    try? await Task.sleep(nanoseconds: 800_000_000)
    check(loopedNoteEngine.isPlaying, "looped tab/vocal playback should still be playing, not have run to the end")
    check(loopedNoteEngine.currentTime <= 0.4, "currentTime should stay within the loop region (plus a timer tick's slop), got \(loopedNoteEngine.currentTime)")
    loopedNoteEngine.stop()
    loopedNoteEngine.load(NoteSequence(notes: [ScoreNote(startTime: 0, duration: 0.1, midiPitch: 60)]))
    check(loopedNoteEngine.loopRegion == nil, "loopRegion should reset automatically whenever a new sequence is loaded")
    print("PASS: NotePlaybackEngine.loopRegion loops a section of the tab/vocal playback")

    // MARK: - NotePlaybackEngine.playbackRate: slows practice playback down
    // without affecting pitch (notes are re-scheduled further apart, not
    // resampled) — and a mid-playback rate change re-schedules cleanly
    // instead of crashing or losing track of position.
    let slowEngine = NotePlaybackEngine(midiProgram: 0)
    slowEngine.load(NoteSequence(notes: [ScoreNote(startTime: 0, duration: 1.0, midiPitch: 60)]))
    slowEngine.playbackRate = 0.5
    slowEngine.play()
    try? await Task.sleep(nanoseconds: 400_000_000)
    check(slowEngine.isPlaying, "half-speed playback of a 1.0s note should still be playing after 0.4s of real time")
    check(abs(slowEngine.currentTime - 0.2) < 0.1, "at half speed, ~0.4s of real time should read as ~0.2s of sequence time, got \(slowEngine.currentTime)")
    slowEngine.playbackRate = 1.0
    try? await Task.sleep(nanoseconds: 200_000_000)
    check(slowEngine.isPlaying, "changing rate back to normal mid-playback shouldn't crash or stop playback")
    slowEngine.stop()
    print("PASS: NotePlaybackEngine.playbackRate slows/resumes practice-speed playback")

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

    // MARK: - attachFile: promotes a placeholder to a real track once you
    // actually have the file, without waiting for a folder rescan/"Import
    // Known Tracks" to discover it — the track list's "Attach File…"
    // context-menu item on a placeholder row.
    for key in ["scannedFolderPaths", "additionalTrackPaths"] {
        UserDefaults.standard.removeObject(forKey: key)
    }
    let attachFileStore = InMemoryLocalStore()
    let attachFileLibrary = LibraryModel(ratingStore: attachFileStore, playlistStore: attachFileStore)
    let attachPlaceholder = attachFileLibrary.createPlaceholderTrack(album: "Some Unowned Album")
    attachFileLibrary.setRating(7, for: attachPlaceholder)
    attachFileLibrary.updateMetadata(
        for: attachPlaceholder, title: attachPlaceholder.title, artist: attachPlaceholder.artist,
        album: attachPlaceholder.album, genre: attachPlaceholder.genre,
        year: nil, trackNumber: nil, discNumber: nil, bpm: nil, key: "", comments: "", tags: ["favorite"]
    )
    guard let editedAttachPlaceholder = attachFileLibrary.tracks.first(where: { $0.path == attachPlaceholder.path }) else {
        fail("attach-file placeholder disappeared after editing")
    }
    attachFileLibrary.createPlaylist(name: "Wishlist")
    guard let wishlist = attachFileLibrary.playlists.first(where: { $0.name == "Wishlist" }) else {
        fail("expected the Wishlist playlist to exist")
    }
    attachFileLibrary.addTrack(editedAttachPlaceholder, toPlaylistID: wishlist.id)

    let fileToAttach = rockDir.appendingPathComponent("AlbumA/track1.m4a")
    guard let attachedTrack = await attachFileLibrary.attachFile(to: editedAttachPlaceholder, fileURL: fileToAttach) else {
        fail("attachFile should return the newly-promoted real track")
    }
    check(!attachedTrack.isPlaceholder, "the attached track should no longer be a placeholder")
    check(attachedTrack.path == fileToAttach.path, "the attached track's path should be the picked file's path, got \(attachedTrack.path)")
    check(attachedTrack.rating == 7, "the attached track should carry over the placeholder's rating, got \(attachedTrack.rating)")
    check(attachedTrack.tags == ["favorite"], "the attached track should carry over the placeholder's tags, got \(attachedTrack.tags)")
    check(!attachFileLibrary.tracks.contains { $0.path == editedAttachPlaceholder.path }, "the old placeholder entry should be gone")

    let placeholdersAfterAttach = (try? await attachFileStore.allPlaceholderTracks()) ?? []
    check(!placeholdersAfterAttach.contains { $0.path == editedAttachPlaceholder.path }, "the placeholder row should be removed from the store too")

    guard let wishlistAfterAttach = attachFileLibrary.playlists.first(where: { $0.id == wishlist.id }) else {
        fail("expected the Wishlist playlist to still exist")
    }
    check(wishlistAfterAttach.trackPaths == [fileToAttach.path], "the playlist should now reference the promoted track's real path, got \(wishlistAfterAttach.trackPaths)")

    let relaunchedAttachFileLibrary = LibraryModel(ratingStore: attachFileStore, playlistStore: attachFileStore)
    await relaunchedAttachFileLibrary.rescanAllFolders()
    check(relaunchedAttachFileLibrary.tracks.contains { $0.path == fileToAttach.path }, "the attached file should survive a relaunch like any other individually-added file")
    print("PASS: attachFile promotes a placeholder to a real track, carrying over rating/tags/playlist membership")

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

    // MARK: - Learn Song session persistence: which tab/vocal/notation
    // file is attached to a track, the full-score file, which stave was
    // last being practiced, and the loop region — all round-trip through
    // the store keyed by track path.
    let learnSessionData = LearnSessionData(
        tabFilePath: "/tmp/example-tab.musicxml",
        vocalFilePath: "/tmp/example-vocal.musicxml",
        notationFilePath: "/tmp/example-notation.musicxml",
        fullScoreFilePath: "/tmp/example-full-score.musicxml",
        practiceTarget: "notation",
        loopStart: 12.5,
        loopEnd: 30.0
    )
    try? await store.saveLearnSession(learnSessionData, forTrackPath: m4aTrack.path)
    let reloadedSession = try? await store.learnSession(forTrackPath: m4aTrack.path)
    check(reloadedSession?.tabFilePath == learnSessionData.tabFilePath, "tab file path should round-trip")
    check(reloadedSession?.vocalFilePath == learnSessionData.vocalFilePath, "vocal file path should round-trip")
    check(reloadedSession?.notationFilePath == learnSessionData.notationFilePath, "notation file path should round-trip")
    check(reloadedSession?.fullScoreFilePath == learnSessionData.fullScoreFilePath, "full-score file path should round-trip")
    check(reloadedSession?.practiceTarget == "notation", "practice target should round-trip")
    check(reloadedSession?.loopStart == 12.5 && reloadedSession?.loopEnd == 30.0, "loop region should round-trip")
    let noSession = try? await store.learnSession(forTrackPath: "/no/such/path")
    check(noSession == nil, "a track with no saved Learn Song session should return nil")

    // An "old-shape" session (as if saved before notation/full-score/
    // practice-target existed) should still load cleanly with those
    // fields nil — the regression guard for the existing two-file flow.
    let oldShapeSessionData = LearnSessionData(
        tabFilePath: "/tmp/example-tab.musicxml",
        vocalFilePath: "/tmp/example-vocal.musicxml",
        loopStart: 5.0,
        loopEnd: 15.0
    )
    try? await store.saveLearnSession(oldShapeSessionData, forTrackPath: flacTrack.path)
    let reloadedOldShapeSession = try? await store.learnSession(forTrackPath: flacTrack.path)
    check(reloadedOldShapeSession?.tabFilePath == oldShapeSessionData.tabFilePath, "old-shape session's tab file path should still round-trip")
    check(reloadedOldShapeSession?.notationFilePath == nil, "old-shape session should load with no notation file path")
    check(reloadedOldShapeSession?.fullScoreFilePath == nil, "old-shape session should load with no full-score file path")
    check(reloadedOldShapeSession?.practiceTarget == nil, "old-shape session should load with no practice target")
    print("PASS: Learn Song session persistence (tab/vocal/notation file paths, full-score file, practice target, loop region)")

    // MARK: - PerformanceEvaluator (Learn Song): verifies a recorded
    // performance against known expected notes using synthetic sine +
    // harmonic tone signals — single notes, a simultaneously-played chord,
    // a deliberately wrong note, silence, and vocal pitch tracking. No
    // real microphone/instrument needed: the detector only ever checks for
    // energy at specific known frequencies, so a synthetic tone at that
    // exact frequency is a faithful stand-in for a real performance.
    func makeTone(frequency: Double, duration: TimeInterval, sampleRate: Double) -> [Float] {
        let harmonicAmplitudes: [Double] = [1.0, 0.5, 0.25]
        let totalAmplitude = harmonicAmplitudes.reduce(0, +)
        let count = Int(duration * sampleRate)
        var samples = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / sampleRate
            var value = 0.0
            for (index, amplitude) in harmonicAmplitudes.enumerated() {
                value += amplitude * sin(2 * Double.pi * frequency * Double(index + 1) * t)
            }
            samples[i] = Float(value / totalAmplitude)
        }
        return samples
    }

    func synthesizeBuffer(playing notes: [ScoreNote], totalDuration: TimeInterval, sampleRate: Double) -> [Float] {
        var buffer = [Float](repeating: 0, count: Int(totalDuration * sampleRate))
        for note in notes {
            let tone = makeTone(frequency: note.frequency, duration: note.duration, sampleRate: sampleRate)
            let startSample = Int(note.startTime * sampleRate)
            for i in 0..<tone.count {
                let index = startSample + i
                guard index < buffer.count else { break }
                buffer[index] += tone[i]
            }
        }
        return buffer
    }

    let evalSampleRate = 44100.0

    // A single note, played cleanly and on time.
    let perfSingleNoteSequence = NoteSequence(notes: [ScoreNote(startTime: 0.5, duration: 1.0, midiPitch: 40)]) // E2
    let perfSingleNoteBuffer = synthesizeBuffer(playing: perfSingleNoteSequence.notes, totalDuration: 2.0, sampleRate: evalSampleRate)
    let perfSingleNoteResult = PerformanceEvaluator.evaluate(samples: perfSingleNoteBuffer, sampleRate: evalSampleRate, against: perfSingleNoteSequence)
    check(perfSingleNoteResult.perNote.count == 1, "single-note evaluation should return one result")
    check(perfSingleNoteResult.perNote[0].hit, "a cleanly played note should be detected as a hit")
    check(abs(perfSingleNoteResult.perNote[0].timingOffset ?? .infinity) < PerformanceEvaluator.onsetTolerance, "a note played exactly on time should have a small timing offset")
    print("PASS: PerformanceEvaluator detects a single cleanly-played note")

    // A chord: three notes struck simultaneously (open G major shape).
    let perfChordSequence = NoteSequence(notes: [
        ScoreNote(startTime: 0.3, duration: 0.8, midiPitch: 43), // G2
        ScoreNote(startTime: 0.3, duration: 0.8, midiPitch: 47), // B2
        ScoreNote(startTime: 0.3, duration: 0.8, midiPitch: 50)  // D3
    ])
    let perfChordBuffer = synthesizeBuffer(playing: perfChordSequence.notes, totalDuration: 1.5, sampleRate: evalSampleRate)
    let perfChordResult = PerformanceEvaluator.evaluate(samples: perfChordBuffer, sampleRate: evalSampleRate, against: perfChordSequence)
    check(perfChordResult.perNote.count == 3, "chord evaluation should return one result per expected note")
    check(perfChordResult.hitCount == 3, "every note of a simultaneously-played chord should be detected independently")
    print("PASS: PerformanceEvaluator detects every note of a simultaneously-played chord")

    // A wrong note: the sequence expects one pitch, but a different,
    // unrelated one was actually played at that moment.
    let perfWrongNoteSequence = NoteSequence(notes: [ScoreNote(startTime: 0.5, duration: 1.0, midiPitch: 40)]) // E2 expected
    let perfActuallyPlayed = ScoreNote(startTime: 0.5, duration: 1.0, midiPitch: 51) // D#3 actually played
    let perfWrongNoteBuffer = synthesizeBuffer(playing: [perfActuallyPlayed], totalDuration: 2.0, sampleRate: evalSampleRate)
    let perfWrongNoteResult = PerformanceEvaluator.evaluate(samples: perfWrongNoteBuffer, sampleRate: evalSampleRate, against: perfWrongNoteSequence)
    check(!perfWrongNoteResult.perNote[0].hit, "a different pitch than the one expected should not register as a hit")
    print("PASS: PerformanceEvaluator rejects a wrong note")

    // Silence: nothing played at all should be a clean miss, not a crash.
    let perfSilenceBuffer = [Float](repeating: 0, count: Int(2.0 * evalSampleRate))
    let perfSilenceResult = PerformanceEvaluator.evaluate(samples: perfSilenceBuffer, sampleRate: evalSampleRate, against: perfSingleNoteSequence)
    check(!perfSilenceResult.perNote[0].hit, "silence should not register as a hit")
    print("PASS: PerformanceEvaluator handles silence without crashing")

    // Vocal bonus: open-ended autocorrelation pitch tracking should land
    // close to the actual sung pitch, not just report hit/miss.
    let perfVocalSequence = NoteSequence(notes: [ScoreNote(startTime: 0.4, duration: 1.0, midiPitch: 64)]) // E4
    let perfVocalBuffer = synthesizeBuffer(playing: perfVocalSequence.notes, totalDuration: 2.0, sampleRate: evalSampleRate)
    let perfVocalResult = PerformanceEvaluator.evaluate(samples: perfVocalBuffer, sampleRate: evalSampleRate, against: perfVocalSequence, isVocal: true)
    check(perfVocalResult.perNote[0].hit, "a cleanly sung note should be a hit")
    guard let perfDetectedPitch = perfVocalResult.perNote[0].detectedPitch else { fail("vocal evaluation should report a detected pitch") }
    check(abs(perfDetectedPitch - 64) <= 1, "detected vocal pitch should be within a semitone of the sung note, got \(perfDetectedPitch)")
    print("PASS: PerformanceEvaluator vocal pitch tracking reports the sung pitch")

    // MARK: - TunerEngine (Learn Song): the standalone chromatic tuner's
    // YIN-based pitch detector, exercised against synthetic tones — same
    // rationale as PerformanceEvaluator above, no real microphone needed.
    let tunerSampleRate = 44100.0
    let inTuneA4 = makeTone(frequency: 440.0, duration: 0.3, sampleRate: tunerSampleRate)
    guard let inTuneReading = TunerEngine.detectPitch(samples: inTuneA4, sampleRate: tunerSampleRate) else {
        fail("tuner should detect a pitch from a clean 440Hz tone")
    }
    check(inTuneReading.noteName == "A4", "a clean 440Hz tone should read as A4, got \(inTuneReading.noteName)")
    check(abs(inTuneReading.cents) < 5, "a clean 440Hz tone should read within a few cents of in-tune, got \(inTuneReading.cents)")
    print("PASS: TunerEngine detects an in-tune 440Hz tone as A4")

    // A string tuned flat: E2 (open low E, 82.41Hz) pulled down ~35 cents.
    let flatFrequency = 82.41 * pow(2.0, -35.0 / 1200.0)
    let flatE2 = makeTone(frequency: flatFrequency, duration: 0.3, sampleRate: tunerSampleRate)
    guard let flatReading = TunerEngine.detectPitch(samples: flatE2, sampleRate: tunerSampleRate) else {
        fail("tuner should detect a pitch from a flat E2 tone")
    }
    check(flatReading.noteName == "E2", "a slightly-flat low E should still read as E2, got \(flatReading.noteName)")
    check(flatReading.cents < -20 && flatReading.cents > -50, "a string pulled ~35 cents flat should read clearly flat, got \(flatReading.cents)")
    print("PASS: TunerEngine detects a flat string and reports negative cents")

    let tunerSilence = [Float](repeating: 0, count: Int(0.3 * tunerSampleRate))
    check(TunerEngine.detectPitch(samples: tunerSilence, sampleRate: tunerSampleRate) == nil, "silence should not report a pitch")
    print("PASS: TunerEngine reports no pitch on silence")

    // MARK: - iCloudSyncService: two "machines" (separate stores, separate
    // paths for the same song) merging ratings/play counts through a
    // shared scratch JSON file standing in for the real iCloud Drive
    // location — proves fingerprint-based matching (not path-based) works
    // across machines with different folder layouts.
    let syncFileURL = URL(fileURLWithPath: NSTemporaryDirectory() + "regressiontest-sync-\(UUID().uuidString).json")
    let machineATrack = Track(path: "/machineA/Music/song.m4a", title: "Sync Song", artist: "Sync Artist", album: "Sync Album", genre: "Rock", duration: 180)
    let machineBTrack = Track(path: "/machineB/Music/song.m4a", title: "Sync Song", artist: "Sync Artist", album: "Sync Album", genre: "Rock", duration: 180)
    check(machineATrack.syncFingerprint == machineBTrack.syncFingerprint, "the same song at two different local paths should share a fingerprint")

    let machineAStore = InMemoryLocalStore()
    try? await machineAStore.setRating(9, forPath: machineATrack.path)
    try? await machineAStore.addPartialPlay(3.0, forPath: machineATrack.path)
    _ = try? await iCloudSyncService.sync(tracks: [machineATrack], store: machineAStore, fileURL: syncFileURL)

    let machineBStore = InMemoryLocalStore()
    _ = try? await iCloudSyncService.sync(tracks: [machineBTrack], store: machineBStore, fileURL: syncFileURL)
    let machineBAfterFirstSync = (try? await machineBStore.allRatings())?[machineBTrack.path]
    check(machineBAfterFirstSync?.rating == 9, "machine B should pick up machine A's rating via fingerprint match, got \(String(describing: machineBAfterFirstSync?.rating))")
    check(machineBAfterFirstSync?.playCount == 3.0, "machine B should pick up machine A's play count, got \(String(describing: machineBAfterFirstSync?.playCount))")
    print("PASS: iCloudSyncService matches tracks across machines by fingerprint, not path")

    try? await machineAStore.addPartialPlay(2.0, forPath: machineATrack.path) // A: 3.0 -> 5.0
    _ = try? await iCloudSyncService.sync(tracks: [machineATrack], store: machineAStore, fileURL: syncFileURL)
    _ = try? await iCloudSyncService.sync(tracks: [machineBTrack], store: machineBStore, fileURL: syncFileURL)
    let machineBAfterPlayMerge = (try? await machineBStore.allRatings())?[machineBTrack.path]
    check(machineBAfterPlayMerge?.playCount == 5.0, "play counts should merge by taking the max across machines, got \(String(describing: machineBAfterPlayMerge?.playCount))")
    print("PASS: iCloudSyncService merges play counts by max, never losing a play")

    // A small real delay, not just a later statement — otherwise A's and
    // B's `setRating` calls can land within the same clock tick and the
    // "more recent" comparison has nothing genuine to go on.
    try? await Task.sleep(nanoseconds: 10_000_000)
    try? await machineBStore.setRating(5, forPath: machineBTrack.path) // B rates it differently, more recently
    _ = try? await iCloudSyncService.sync(tracks: [machineBTrack], store: machineBStore, fileURL: syncFileURL)
    _ = try? await iCloudSyncService.sync(tracks: [machineATrack], store: machineAStore, fileURL: syncFileURL)
    let machineAAfterRatingConflict = (try? await machineAStore.allRatings())?[machineATrack.path]
    check(machineAAfterRatingConflict?.rating == 5, "the more recently-set rating should win on the next sync, got \(String(describing: machineAAfterRatingConflict?.rating))")
    print("PASS: iCloudSyncService resolves a rating conflict via last-write-wins")

    try? FileManager.default.removeItem(at: syncFileURL)

    // MARK: - importKnownTracks: scans a folder but keeps only files whose
    // fingerprint is already known from the iCloud sync catalog — lets a
    // second machine mirror what's catalogued elsewhere out of a larger
    // local folder without re-importing everything in it (see
    // iCloudSyncService.knownFingerprints / LibraryModel.importKnownTracks).
    let knownTracksSyncURL = URL(fileURLWithPath: NSTemporaryDirectory() + "regressiontest-knowntracks-\(UUID().uuidString).json")

    // Reset again (see the file-top UserDefaults note) so the relaunch
    // check below isn't contaminated by the addFiles section above.
    for key in ["scannedFolderPaths", "additionalTrackPaths"] {
        UserDefaults.standard.removeObject(forKey: key)
    }
    let importKnownStore = InMemoryLocalStore()
    let importKnownLibrary = LibraryModel(ratingStore: importKnownStore, playlistStore: importKnownStore)
    let noCatalogCount = await importKnownLibrary.importKnownTracks(from: rockDir, fileURL: knownTracksSyncURL)
    check(noCatalogCount == 0, "with no synced catalog yet, nothing should be imported, got \(noCatalogCount)")

    // Seed the catalog the way a real "other machine" would: sync a track
    // that shares Rock/AlbumA's "Track One" fingerprint but lives at a
    // different (that machine's own) path.
    let rockScan = await LibraryScanner.scan(rootURL: rockDir)
    check(rockScan.count == 2, "expected 2 fixture tracks in Rock/AlbumA, got \(rockScan.count)")
    guard let trackOne = rockScan.first(where: { $0.title == "Track One" }) else {
        fail("expected to find 'Track One' among the Rock fixtures")
    }
    let otherMachineTrack = Track(path: "/otherMachine/Track One.m4a", title: trackOne.title, artist: trackOne.artist, album: trackOne.album, genre: trackOne.genre, duration: trackOne.duration)
    check(otherMachineTrack.syncFingerprint == trackOne.syncFingerprint, "constructed fixture should share a fingerprint with the real Rock/AlbumA file")
    let otherMachineStore = InMemoryLocalStore()
    try? await otherMachineStore.setRating(8, forPath: otherMachineTrack.path)
    try? await otherMachineStore.addPartialPlay(4.0, forPath: otherMachineTrack.path)
    _ = try? await iCloudSyncService.sync(tracks: [otherMachineTrack], store: otherMachineStore, fileURL: knownTracksSyncURL)

    let known = iCloudSyncService.knownFingerprints(fileURL: knownTracksSyncURL)
    check(known.contains(trackOne.syncFingerprint), "knownFingerprints should include the fingerprint just synced from the other machine")
    print("PASS: iCloudSyncService.knownFingerprints reflects the synced catalog")

    let matchedKnownTrackCount = await importKnownLibrary.importKnownTracks(from: rockDir, fileURL: knownTracksSyncURL)
    check(matchedKnownTrackCount == 1, "only 'Track One' should match the known catalog, got \(matchedKnownTrackCount)")
    check(importKnownLibrary.visibleTracks.map { $0.title } == ["Track One"], "the imported track should be Track One, got \(importKnownLibrary.visibleTracks.map { $0.title })")
    print("PASS: LibraryModel.importKnownTracks imports only files matching the iCloud sync catalog")

    let importedTrackOne = importKnownLibrary.visibleTracks.first(where: { $0.title == "Track One" })
    check(importedTrackOne?.rating == 8, "a newly-matched track should pick up the rating already known from the catalog, got \(String(describing: importedTrackOne?.rating))")
    check(importedTrackOne?.playCount == 4.0, "a newly-matched track should pick up the play count already known from the catalog, got \(String(describing: importedTrackOne?.playCount))")
    print("PASS: LibraryModel.importKnownTracks applies the catalog's rating/play count to newly-matched tracks")

    // MARK: - Regression: importKnownTracks' matches must survive a
    // relaunch too, same as addFiles above — the folder it scanned is
    // deliberately *not* added to `scannedFolderPaths` (a plain rescan of
    // a large personal-archive folder would defeat the whole point of
    // matching only known tracks), so each matched file's own path needs
    // to be remembered individually instead.
    let relaunchedImportKnownLibrary = LibraryModel(ratingStore: importKnownStore, playlistStore: importKnownStore)
    await relaunchedImportKnownLibrary.rescanAllFolders()
    check(relaunchedImportKnownLibrary.visibleTracks.map { $0.title } == ["Track One"], "importKnownTracks' matches should survive a relaunch, got \(relaunchedImportKnownLibrary.visibleTracks.map { $0.title })")
    print("PASS: importKnownTracks-imported tracks survive a relaunch")

    try? FileManager.default.removeItem(at: knownTracksSyncURL)

    // MARK: - Backward compatibility: a snapshot file written before
    // `playlists`/`metadata` existed (this user has a real one with
    // hundreds of entries already) must still decode correctly — a
    // missing key, not corrupted data — so a sync never looks like
    // "start from empty" and silently drops every fingerprint this
    // machine doesn't have locally on its next write.
    let oldShapeSyncURL = URL(fileURLWithPath: NSTemporaryDirectory() + "regressiontest-oldshape-\(UUID().uuidString).json")
    let oldShapeFingerprint = "old song|old artist|old album|200"
    let oldShapeJSON = """
    {
      "entries": {
        "\(oldShapeFingerprint)": {"rating": 7, "playCount": 2.5}
      },
      "updatedAt": "2024-01-01T00:00:00.000Z"
    }
    """
    try? oldShapeJSON.write(to: oldShapeSyncURL, atomically: true, encoding: .utf8)

    let oldShapeKnownBeforeSync = iCloudSyncService.knownFingerprints(fileURL: oldShapeSyncURL)
    check(oldShapeKnownBeforeSync.contains(oldShapeFingerprint), "an old-shape snapshot (no playlists/metadata keys) should still decode its entries, got \(oldShapeKnownBeforeSync)")

    let oldShapeStore = InMemoryLocalStore()
    _ = try? await iCloudSyncService.sync(tracks: [], store: oldShapeStore, fileURL: oldShapeSyncURL)
    let oldShapeKnownAfterSync = iCloudSyncService.knownFingerprints(fileURL: oldShapeSyncURL)
    check(oldShapeKnownAfterSync.contains(oldShapeFingerprint), "syncing against an old-shape file (with no local tracks of its own) must not drop the pre-existing entry, got \(oldShapeKnownAfterSync)")
    print("PASS: an old-shape sync.json (no playlists/metadata keys) decodes without losing entries")

    try? FileManager.default.removeItem(at: oldShapeSyncURL)

    // MARK: - Synced placeholders: a fingerprint known from the catalog
    // but with no local file shows up as a grayed-out placeholder (see
    // iCloudSyncService.syncedPlaceholderPathPrefix / Track.isPlaceholder)
    // instead of not appearing at all, and gets promoted to a real track
    // the moment a matching local file does show up.
    let placeholderSyncURL = URL(fileURLWithPath: NSTemporaryDirectory() + "regressiontest-placeholder-\(UUID().uuidString).json")

    let onlyOnATrack = Track(path: "/machineA/Music/OnlyOnA.m4a", title: "Only On A", artist: "Placeholder Artist", album: "Placeholder Album", genre: "Rock", duration: 210)
    let machineAPlaceholderStore = InMemoryLocalStore()
    try? await machineAPlaceholderStore.setRating(9, forPath: onlyOnATrack.path)
    try? await machineAPlaceholderStore.addPartialPlay(3.0, forPath: onlyOnATrack.path)
    _ = try? await iCloudSyncService.sync(tracks: [onlyOnATrack], store: machineAPlaceholderStore, fileURL: placeholderSyncURL)

    let machineBPlaceholderStore = InMemoryLocalStore()
    _ = try? await iCloudSyncService.sync(tracks: [], store: machineBPlaceholderStore, fileURL: placeholderSyncURL)
    let placeholdersOnB = (try? await machineBPlaceholderStore.allPlaceholderTracks()) ?? []
    check(placeholdersOnB.count == 1, "machine B should get exactly one synced placeholder for the fingerprint it has no local file for, got \(placeholdersOnB.count)")
    let syncedPlaceholder = placeholdersOnB.first
    check(syncedPlaceholder?.path.hasPrefix(iCloudSyncService.syncedPlaceholderPathPrefix) == true, "a synced placeholder's path should carry the synced-placeholder prefix, got \(String(describing: syncedPlaceholder?.path))")
    check(syncedPlaceholder?.title == "Only On A", "the placeholder should carry the catalog's title, got \(String(describing: syncedPlaceholder?.title))")
    check(syncedPlaceholder?.rating == 9, "the placeholder should carry the catalog's rating, got \(String(describing: syncedPlaceholder?.rating))")
    check(syncedPlaceholder?.playCount == 3.0, "the placeholder should carry the catalog's play count, got \(String(describing: syncedPlaceholder?.playCount))")
    check(syncedPlaceholder?.duration == 210, "the placeholder should preserve duration for correct fingerprint round-tripping, got \(String(describing: syncedPlaceholder?.duration))")
    print("PASS: a fingerprint with no local file syncs in as a grayed-out placeholder")

    let onlyOnATrackOnB = Track(path: "/machineB/Music/OnlyOnA.m4a", title: "Only On A", artist: "Placeholder Artist", album: "Placeholder Album", genre: "Rock", duration: 210)
    check(onlyOnATrackOnB.syncFingerprint == onlyOnATrack.syncFingerprint, "sanity: the two machines' copies of the same song should share a fingerprint")
    _ = try? await iCloudSyncService.sync(tracks: [onlyOnATrackOnB], store: machineBPlaceholderStore, fileURL: placeholderSyncURL)
    let placeholdersAfterPromotion = (try? await machineBPlaceholderStore.allPlaceholderTracks()) ?? []
    check(placeholdersAfterPromotion.isEmpty, "the placeholder should be removed once a real local file matches its fingerprint, got \(placeholdersAfterPromotion.count) remaining")
    let ratingsAfterPromotion = (try? await machineBPlaceholderStore.allRatings()) ?? [:]
    check(ratingsAfterPromotion[onlyOnATrackOnB.path]?.rating == 9, "the real, promoted track should carry the rating the placeholder had, got \(String(describing: ratingsAfterPromotion[onlyOnATrackOnB.path]?.rating))")
    check(ratingsAfterPromotion[onlyOnATrackOnB.path]?.playCount == 3.0, "the real, promoted track should carry the play count the placeholder had, got \(String(describing: ratingsAfterPromotion[onlyOnATrackOnB.path]?.playCount))")
    print("PASS: a placeholder is promoted to a real track once a matching local file appears")

    try? FileManager.default.removeItem(at: placeholderSyncURL)

    // MARK: - Playlist sync: a regular playlist's ordered tracks travel by
    // fingerprint (never by path, which means nothing on another
    // machine), resolving to whatever local Track — real file or
    // placeholder — shares that fingerprint; a smart playlist just
    // carries its rules across, no fingerprints needed since rules match
    // on track fields directly.
    let playlistSyncURL = URL(fileURLWithPath: NSTemporaryDirectory() + "regressiontest-playlistsync-\(UUID().uuidString).json")

    let playlistTrackA = Track(path: "/machineA/Music/PlaylistSong.m4a", title: "Playlist Song", artist: "Playlist Artist", album: "Playlist Album", genre: "Pop", duration: 150)
    let playlistSeedStoreA = InMemoryLocalStore()
    _ = try? await iCloudSyncService.sync(tracks: [playlistTrackA], store: playlistSeedStoreA, fileURL: playlistSyncURL)

    let regularPlaylistA = Playlist(name: "Road Trip", trackPaths: [playlistTrackA.path])
    let smartPlaylistA = Playlist(name: "High Rated", isSmart: true, smartMatchAll: true, smartRules: [SmartRule(field: .rating, comparison: .greaterThanOrEqual, value: "8")])
    try? await iCloudSyncService.syncPlaylists(
        playlists: [regularPlaylistA, smartPlaylistA], tracks: [playlistTrackA], store: playlistSeedStoreA,
        excludedPlaylistIDs: [], fileURL: playlistSyncURL
    )

    // Machine B has no local file for playlistTrackA — sync tracks first
    // (so B gets a placeholder for its fingerprint), then playlists.
    let playlistStoreB = InMemoryLocalStore()
    _ = try? await iCloudSyncService.sync(tracks: [], store: playlistStoreB, fileURL: playlistSyncURL)
    let bPlaceholders = (try? await playlistStoreB.allPlaceholderTracks()) ?? []
    guard let bPlaceholderForPlaylistTrack = bPlaceholders.first(where: { $0.title == "Playlist Song" }) else {
        fail("machine B should have a synced placeholder for the playlist's track")
    }
    let bPlaceholderTrack = Track(
        path: bPlaceholderForPlaylistTrack.path, title: bPlaceholderForPlaylistTrack.title,
        artist: bPlaceholderForPlaylistTrack.artist, album: bPlaceholderForPlaylistTrack.album,
        genre: bPlaceholderForPlaylistTrack.genre, duration: bPlaceholderForPlaylistTrack.duration
    )
    try? await iCloudSyncService.syncPlaylists(
        playlists: [], tracks: [bPlaceholderTrack], store: playlistStoreB,
        excludedPlaylistIDs: [], fileURL: playlistSyncURL
    )
    let playlistsOnB = (try? await playlistStoreB.allPlaylists()) ?? []
    let regularOnB = playlistsOnB.first(where: { $0.id == regularPlaylistA.id })
    check(regularOnB?.trackPaths == [bPlaceholderForPlaylistTrack.path], "machine B's copy of the regular playlist should resolve its one track to B's placeholder path, got \(String(describing: regularOnB?.trackPaths))")
    let smartOnB = playlistsOnB.first(where: { $0.id == smartPlaylistA.id })
    check(smartOnB?.isSmart == true && smartOnB?.smartRules == smartPlaylistA.smartRules, "machine B should receive the smart playlist's rules as-is, got \(String(describing: smartOnB))")
    print("PASS: playlists sync by fingerprint, resolving to a placeholder when the file isn't local")

    // MARK: - Playlist deletion stays local-only (by design — see
    // iCloudSyncService.syncPlaylists's doc comment): deleting a playlist
    // must not have its own next sync resurrect it from the shared
    // catalog before the deletion has any chance to reach the other
    // machine too.
    // Mirrors LibraryModel.deletePlaylist: remove the local row, and
    // record the exclusion, exactly as machine A would after the user
    // deletes it there.
    try? await playlistSeedStoreA.deletePlaylist(id: regularPlaylistA.id)
    try? await playlistSeedStoreA.excludePlaylist(id: regularPlaylistA.id)
    let excludedIDsA = (try? await playlistSeedStoreA.excludedPlaylistIDs()) ?? []
    try? await iCloudSyncService.syncPlaylists(
        playlists: [smartPlaylistA], tracks: [playlistTrackA], store: playlistSeedStoreA,
        excludedPlaylistIDs: excludedIDsA, fileURL: playlistSyncURL
    )
    let playlistsOnAAfterDelete = (try? await playlistSeedStoreA.allPlaylists()) ?? []
    check(!playlistsOnAAfterDelete.contains(where: { $0.id == regularPlaylistA.id }), "a locally-deleted playlist should not be resurrected by this machine's own next sync, got \(playlistsOnAAfterDelete.map(\.name))")
    print("PASS: a locally-deleted playlist isn't resurrected by this machine's own sync")

    try? FileManager.default.removeItem(at: playlistSyncURL)

    // MARK: - LibraryModel.syncStatus: surfaced in the toolbar so a sync
    // failure or race (like the one that motivated this) is actually
    // visible instead of silent.
    let syncStatusURL = URL(fileURLWithPath: NSTemporaryDirectory() + "regressiontest-syncstatus-\(UUID().uuidString).json")
    let syncStatusStore = InMemoryLocalStore()
    let syncStatusLibrary = LibraryModel(ratingStore: syncStatusStore, playlistStore: syncStatusStore)
    check(syncStatusLibrary.syncStatus == .neverSynced, "a fresh LibraryModel should report neverSynced before any sync, got \(syncStatusLibrary.syncStatus)")
    _ = await syncStatusLibrary.syncWithiCloud(fileURL: syncStatusURL)
    guard case .succeeded = syncStatusLibrary.syncStatus else {
        fail("a successful sync against a writable scratch file should report succeeded, got \(syncStatusLibrary.syncStatus)")
    }
    print("PASS: LibraryModel.syncStatus reflects neverSynced -> succeeded")
    try? FileManager.default.removeItem(at: syncStatusURL)

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
