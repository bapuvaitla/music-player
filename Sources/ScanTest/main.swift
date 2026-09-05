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

    // MARK: - Learn Song session persistence: which tab/vocal file is
    // attached to a track, plus its loop region, round-trips through the
    // store keyed by track path.
    let learnSessionData = LearnSessionData(
        tabFilePath: "/tmp/example-tab.musicxml",
        vocalFilePath: "/tmp/example-vocal.musicxml",
        loopStart: 12.5,
        loopEnd: 30.0
    )
    try? await store.saveLearnSession(learnSessionData, forTrackPath: m4aTrack.path)
    let reloadedSession = try? await store.learnSession(forTrackPath: m4aTrack.path)
    check(reloadedSession?.tabFilePath == learnSessionData.tabFilePath, "tab file path should round-trip")
    check(reloadedSession?.vocalFilePath == learnSessionData.vocalFilePath, "vocal file path should round-trip")
    check(reloadedSession?.loopStart == 12.5 && reloadedSession?.loopEnd == 30.0, "loop region should round-trip")
    let noSession = try? await store.learnSession(forTrackPath: "/no/such/path")
    check(noSession == nil, "a track with no saved Learn Song session should return nil")
    print("PASS: Learn Song session persistence (tab/vocal file paths + loop region)")

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
