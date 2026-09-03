# Music Player

A native macOS music player built with SwiftUI and AVFoundation. Points at folders of local audio files and plays them — no library import, no cloud sync, no telemetry. Ratings, tags, and edits are stored locally in SQLite and are never written back to your audio files.

## Features

- **Library browsing** — two-pane view with a faceted sidebar (Artists / Albums / Genres, multi-select with Cmd/Shift-click) and a sortable, user-configurable track table
- **Formats** — MP3, FLAC, M4A/AAC, WAV, AIFF, read via AVFoundation
- **Ratings & tags** — a 0–11 rating scale and free-form tags, stored locally and layered on top of each file's own metadata without ever touching the file
- **Metadata editing** — per-track or batch edits with per-field reset-to-file, Previous/Next navigation across a filtered view, and a file-source display with a "Replace File…" option for swapping in a different rip of the same track without losing its rating or playlist membership
- **Artwork** — replace, copy, and paste cover art per track or per album, independent of the file's embedded artwork
- **Placeholder tracks** — manually add a track you don't own a file for (an unreleased b-side, a song you've only heard live) so its rating still counts toward an album's average
- **Playlists** — regular drag-to-reorder playlists, plus smart playlists with rules over any field (rating, year, artist, genre, tags, play count, …) and match-all/match-any logic
- **Playback** — shuffle, repeat (off/all/one), manual "Play Next"/"Add to Queue", rewind-aware play counting (replaying a passage adds to the count instead of the position simply overwriting it)
- **Mini player** — a floating, resizable, optionally always-on-top window
- **System integration** — responds to the keyboard media keys and Control Center's Now Playing widget; spacebar toggles play/pause without stealing focus from text fields
- **Customization** — pick any installed font and size for the whole app; toggle and reorder track table columns
- **Import** — add folders or individual files from a picker, by dragging from Finder, or by pasting files copied in Finder

## Requirements

- macOS 15 (Sequoia) or later
- Swift 6 toolchain (Xcode 16+, or the Swift toolchain installed standalone)

## Building

This is a Swift Package with no `.xcodeproj` — build and run it with `swift`:

```bash
swift build
swift run MusicPlayer
```

Or open the folder in Xcode (`File > Open…` on `Package.swift`) and run the `MusicPlayer` scheme.

### Building a standalone `.app`

```bash
./build_app.sh
```

This builds a release binary and assembles `Build/Music Player.app`, ready to drag into `/Applications`.

## Project layout

- **`Sources/MusicPlayerKit`** — the library: models (`Track`, `Playlist`, `SmartRule`), services (`LibraryScanner`, `LibraryModel`, `PlayerController`, `PlaybackCoordinator`, `LocalStore`, `ArtworkLoader`, `MediaKeyController`). No SwiftUI dependency — this is the app's logic and data layer.
- **`Sources/MusicPlayer`** — the SwiftUI app: views, and small AppKit-bridging helpers (window configuration, the spacebar monitor, font enumeration) under `Support/`.
- **`Sources/ScanTest`** — a headless executable that exercises `MusicPlayerKit` directly against a real, synthetic test library. There's no XCTest target; this is how the app's logic gets regression-tested — see the file for what it covers (library scanning/merging, hidden vs. deleted tracks, batch editing, playlists, rewind-aware play counting, artwork overrides, file replacement, placeholder tracks, media key integration).

## Data storage

Ratings, tags, hidden/deleted state, metadata overrides, artwork overrides, playlists, and placeholder tracks live in a local SQLite database at `~/Library/Application Support/MusicPlayer/library.sqlite`, managed via [GRDB.swift](https://github.com/groue/GRDB.swift). None of this ever touches your audio files.

## License

MIT — see [LICENSE](LICENSE).
