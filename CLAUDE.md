# Working on Music Player

A native macOS music player, Swift Package Manager (no `.xcodeproj`), targeting macOS 15. See `README.md` for what the app does; this file is operational guidance for working on it.

## Build → test → ship, every change, no exceptions

After *any* code change, before considering it done:

```bash
swift build
swift run ScanTest <a-writable-scratch-directory>
./build_app.sh
```

- `ScanTest` is the regression suite (headless, no XCTest target) — it generates its own real audio fixtures (m4a/aiff/wav/mp3/flac, including embedded artwork) under the directory you pass it, so any writable scratch path works; nothing needs to be set up by hand first.
- `build_app.sh` produces `Build/Music Player.app`, code-signed with a local identity (see below).
- Reinstall and relaunch to actually verify a UI change:
  ```bash
  pkill -f "Music Player"
  rm -rf "/Applications/Music Player.app"
  cp -R "Build/Music Player.app" "/Applications/Music Player.app"
  open "/Applications/Music Player.app"
  ```

## Code-signing identity (first build on a new Mac)

`build_app.sh` signs with a local identity named `MusicPlayerLocalDev`. It won't exist on a fresh machine — without it, ad-hoc signing (`codesign --sign -`) produces a content-derived signature that changes on every rebuild, and macOS's privacy system (mic access, etc.) treats every rebuild as a new app and re-prompts for permissions constantly.

Set one up once per machine:

```bash
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes \
  -subj "/CN=MusicPlayerLocalDev" -addext "extendedKeyUsage=codeSigning"
openssl pkcs12 -export -out cert.p12 -inkey key.pem -in cert.pem -passout pass:temp
security import cert.p12 -k ~/Library/Keychains/login.keychain-db -P temp -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -k ~/Library/Keychains/login.keychain-db cert.pem
rm key.pem cert.pem cert.p12  # delete the temp key material once imported
```

You may need to mark the imported certificate "Always Trust" for code signing in Keychain Access if `codesign` still complains.

## Cross-machine sync

This app syncs ratings and play counts (not audio files, not the library scan itself) between machines via a small JSON snapshot in iCloud Drive — see `Sources/MusicPlayerKit/Services/iCloudSyncService.swift`. It matches tracks across machines by a `title|artist|album|duration` fingerprint, not file path (paths differ per machine). Runs automatically on launch; no per-machine setup needed beyond having iCloud Drive enabled. Each machine still has its own local SQLite database (`~/Library/Application Support/MusicPlayer/library.sqlite`) as the source of truth for everything else (playlists, metadata overrides, artwork, tags).

## Established lessons (read before re-deriving these the hard way)

- **Use `NSOpenPanel` directly, not SwiftUI's `.fileImporter`** — the latter has been unreliable on macOS in this project (silently fails to deliver a picked file). See `LearnSongView.swift`'s `presentImporter` for the pattern.
- **`Table` + `@EnvironmentObject` is a performance trap**: any view holding an `ObservableObject` via `@EnvironmentObject`/`@ObservedObject` gets its *entire* `body` re-evaluated on *any* published change on that object, even ones the view never reads — including a parent re-rendering because a *sibling* view legitimately needs to update. For an expensive view (a `Table` with hundreds of rows), this can mean a full rebuild several times a second. See `TrackListView`'s `Equatable`/`.equatable()` treatment and its `NowPlayingObserver` (a `@StateObject` wrapping a manually-scoped Combine subscription) for the fix, and its doc comments for the full diagnosis.
- **Don't build a "cheap-looking" SwiftUI trick that's actually O(rows)**: `RatingCellView` used to build a real interactive `Slider` for every row all the time and just toggle its opacity, on the theory that avoiding a structural view-tree change kept selection cheap — that meant instantiating a few hundred live sliders on every "All Tracks" render. Only build expensive per-row content for the row that actually needs it.
- **Double-click-to-play gesture code is fragile** — a past attempt to fix a minor double-click quirk there caused a *worse* regression (selection breaking entirely) and had to be reverted outright. Don't guess at changes to `ReorderModifier`/the Table's click handling without a way to verify live; prefer diagnosing via evidence (e.g., temporary logging to a file) over speculative fixes.
- **Ad-hoc GDB-style diagnosis over guessing**: when a performance/reliability bug resists a first fix, add temporary instrumentation (e.g., a small file-logging helper) rather than trying a second blind fix — see the git history around the `TrackListView` performance work for the pattern (mark timestamps at suspected chokepoints, read the log, remove the instrumentation once the real cause is found).
