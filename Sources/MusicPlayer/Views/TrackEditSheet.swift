import SwiftUI
import AppKit
import MusicPlayerKit
import UniformTypeIdentifiers

/// Edits one track (prefilled, with per-field Reset-to-file buttons, and
/// Previous/Next arrows to cycle through `navigationContext` without
/// closing the sheet) or a batch of tracks at once (fields start blank; a
/// blank field on save means "leave each track's value alone," not
/// "reset" — there's no single original to reset to across a batch).
struct TrackEditSheet: View {
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss

    let tracks: [Track]
    /// The broader list to step through with Previous/Next — e.g. the
    /// currently-sorted track table. Ignored in batch mode.
    let navigationContext: [Track]
    /// True only right after "Add Track…" creates a brand-new placeholder
    /// that hasn't been saved yet (see `LibraryModel.createPlaceholderTrack`
    /// — it doesn't persist until Save). Cancelling in that state deletes
    /// the never-saved track instead of just discarding in-progress edits,
    /// so an abandoned add doesn't leave an empty phantom row behind.
    var isNewlyCreatedPlaceholder = false

    /// The track actually being shown, when editing a single track. Changes
    /// as you navigate; `tracks` (the initial argument) does not.
    @State private var currentTrack: Track?
    @State private var batchTracks: [Track]

    @State private var title = ""
    @State private var artist = ""
    @State private var album = ""
    @State private var genre = ""
    @State private var yearText = ""
    @State private var trackNumberText = ""
    @State private var discNumberText = ""
    @State private var bpmText = ""
    @State private var key = ""
    @State private var comments = ""
    @State private var tagsText = ""
    @State private var rating = 0
    /// Batch mode only — rating has no file "original" to fall back to, so
    /// unlike the text fields (where blank means "leave unchanged"), batch
    /// rating needs an explicit opt-in before it touches every track.
    @State private var batchSetRating = false

    private enum ArtworkChange: Equatable {
        case none
        case reset
        case replace(Data)
    }
    @State private var artworkChange: ArtworkChange = .none
    /// Fetched on demand when "Reset to Embedded" is chosen, so that
    /// choice previews accurately instead of just leaving the old image
    /// showing until Save actually commits it.
    @State private var resetPreviewImage: NSImage?
    @State private var showingArtworkImporter = false

    @State private var showingFileReplaceImporter = false
    @State private var isReplacingFile = false

    private var isBatch: Bool { batchTracks.count > 1 }

    /// The track whose artwork this sheet is showing/replacing — the
    /// single track being edited, or (in batch mode) the first of the
    /// batch, since a batch edit is almost always "edit this whole album."
    private var previewTrack: Track? { currentTrack ?? batchTracks.first }

    private var currentIndex: Int? {
        guard let currentTrack else { return nil }
        return navigationContext.firstIndex(where: { $0.path == currentTrack.path })
    }

    private var hasPrevious: Bool {
        guard let currentIndex else { return false }
        return currentIndex > 0
    }

    private var hasNext: Bool {
        guard let currentIndex else { return false }
        return currentIndex + 1 < navigationContext.count
    }

    init(tracks: [Track], navigationContext: [Track] = [], isNewlyCreatedPlaceholder: Bool = false) {
        self.tracks = tracks
        self.navigationContext = navigationContext
        self.isNewlyCreatedPlaceholder = isNewlyCreatedPlaceholder
        _batchTracks = State(initialValue: tracks)
        _currentTrack = State(initialValue: tracks.count == 1 ? tracks.first : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(isBatch ? "Edit \(batchTracks.count) Tracks" : "Edit Info")
                    .font(.title3.weight(.semibold))
                Spacer()
                if !isBatch, !navigationContext.isEmpty {
                    HStack(spacing: 4) {
                        Button {
                            goToPrevious()
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .disabled(!hasPrevious)
                        .help("Previous track")

                        Button {
                            goToNext()
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .disabled(!hasNext)
                        .help("Next track")
                    }
                    .buttonStyle(.borderless)
                }
            }

            if isBatch {
                Text("Blank fields are left unchanged. Anything you fill in applies to all \(batchTracks.count) tracks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 16) {
                artworkSection

                VStack(alignment: .leading, spacing: 12) {
                    labeledField("Title", text: $title, original: currentTrack?.originalTitle)
                    labeledField("Artist", text: $artist, original: currentTrack?.originalArtist)
                    labeledField("Album", text: $album, original: currentTrack?.originalAlbum)
                    labeledField("Genre", text: $genre, original: currentTrack?.originalGenre)
                }
            }

            HStack(alignment: .top, spacing: 12) {
                labeledField("Year", text: $yearText, original: currentTrack?.originalYear.map(String.init))
                labeledField("Track #", text: $trackNumberText, original: currentTrack?.originalTrackNumber.map(String.init))
                labeledField("Disc #", text: $discNumberText, original: currentTrack?.originalDiscNumber.map(String.init))
                labeledField("BPM", text: $bpmText, original: currentTrack?.originalBpm.map(String.init))
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Rating")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if isBatch {
                        Toggle("Set Rating", isOn: $batchSetRating)
                            .toggleStyle(.checkbox)
                            .font(.caption)
                            .controlSize(.small)
                    }
                }
                HStack(spacing: 8) {
                    Slider(
                        value: Binding(
                            get: { Double(rating) },
                            set: { rating = Int($0.rounded()) }
                        ),
                        in: 0...11
                    )
                    .disabled(isBatch && !batchSetRating)
                    Text(rating == 0 ? "–" : "\(rating)")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .frame(minWidth: 16, alignment: .leading)
                }
            }

            labeledField("Key", text: $key, original: currentTrack?.originalKey)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Comments")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let currentTrack, comments != (currentTrack.originalComments ?? "") {
                        Button("Reset") { comments = currentTrack.originalComments ?? "" }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
                TextEditor(text: $comments)
                    .font(.system(size: 12))
                    .frame(height: 60)
                    .padding(4)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.secondary.opacity(0.3))
                    }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(isBatch ? "Add Tags" : "Tags")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("comma, separated, tags", text: $tagsText)
                    .textFieldStyle(.roundedBorder)
                if isBatch {
                    Text("Added to each track's existing tags, not replacing them.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if !isBatch, let currentTrack {
                fileSourceSection(for: currentTrack)
            }

            Text("Changes are stored locally and never written back to the audio file. Play count isn't editable — it's tracked automatically.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") {
                    if isNewlyCreatedPlaceholder, let currentTrack {
                        library.deletePlaceholderTrack(currentTrack)
                    }
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") { save(andDismiss: true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear {
            if let currentTrack {
                loadFields(from: currentTrack)
            }
        }
    }

    private func loadFields(from track: Track) {
        title = track.title
        artist = track.artist
        album = track.album
        genre = track.genre
        yearText = track.year.map(String.init) ?? ""
        trackNumberText = track.trackNumber.map(String.init) ?? ""
        discNumberText = track.discNumber.map(String.init) ?? ""
        bpmText = track.bpm.map(String.init) ?? ""
        key = track.key ?? ""
        comments = track.comments ?? ""
        tagsText = track.tags.joined(separator: ", ")
        rating = track.rating
        artworkChange = .none
        resetPreviewImage = nil
    }

    @ViewBuilder
    private var artworkSection: some View {
        VStack(spacing: 6) {
            artworkPreview
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contextMenu {
                    Button("Replace…") { showingArtworkImporter = true }
                    Button("Copy") { copyCurrentArtwork() }
                    Button("Paste") { pasteArtwork() }
                    Button("Reset to Embedded") { chooseResetArtwork() }
                }

            HStack(spacing: 8) {
                Button("Replace…") { showingArtworkImporter = true }
                Button("Reset") { chooseResetArtwork() }
            }
            .buttonStyle(.link)
            .font(.caption)

            if isBatch {
                Text("Applies to all \(batchTracks.count) tracks")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(width: 100)
            }
        }
        .fileImporter(
            isPresented: $showingArtworkImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first, let data = try? Data(contentsOf: url) {
                artworkChange = .replace(data)
            }
        }
    }

    @ViewBuilder
    private var artworkPreview: some View {
        switch artworkChange {
        case .replace(let data):
            if let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholderArtwork
            }
        case .reset:
            if let resetPreviewImage {
                Image(nsImage: resetPreviewImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholderArtwork.overlay { ProgressView().controlSize(.small) }
            }
        case .none:
            if let previewTrack {
                ArtworkView(track: previewTrack, size: 88, cornerRadius: 8)
            } else {
                placeholderArtwork
            }
        }
    }

    private var placeholderArtwork: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.secondary.opacity(0.15))
    }

    private func chooseResetArtwork() {
        artworkChange = .reset
        resetPreviewImage = nil
        guard let previewTrack else { return }
        Task {
            resetPreviewImage = await ArtworkLoader.shared.embeddedArtwork(for: previewTrack)
        }
    }

    private func copyCurrentArtwork() {
        Task {
            let image: NSImage?
            switch artworkChange {
            case .replace(let data):
                image = NSImage(data: data)
            case .reset:
                image = resetPreviewImage
            case .none:
                guard let previewTrack else { return }
                image = await ArtworkLoader.shared.artwork(for: previewTrack)
            }
            guard let image else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([image])
        }
    }

    /// Like Replace…, but pulling the image from the clipboard instead of
    /// a file picker — same deferred-to-Save behavior.
    private func pasteArtwork() {
        guard let image = NSImage(pasteboard: .general), let data = image.pngData else { return }
        artworkChange = .replace(data)
    }

    /// Shows which file backs this track and lets it be swapped for a
    /// different one on disk (e.g. a better-quality rip of the same song)
    /// — unlike every other field here, this is applied immediately rather
    /// than deferred to Save, since it re-derives the track's metadata
    /// fresh from the new file and the rest of this sheet needs to reflect
    /// that right away, not just on close.
    @ViewBuilder
    private func fileSourceSection(for track: Track) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("File")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(track.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                if isReplacingFile {
                    ProgressView().controlSize(.small)
                }

                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([track.url])
                }
                .buttonStyle(.link)
                .font(.caption)

                Button("Replace File…") {
                    showingFileReplaceImporter = true
                }
                .buttonStyle(.link)
                .font(.caption)
                .disabled(isReplacingFile)
            }
        }
        .fileImporter(
            isPresented: $showingFileReplaceImporter,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let newURL = urls.first else { return }
            isReplacingFile = true
            Task {
                if let updated = await library.replaceFile(for: track, withNewFile: newURL) {
                    currentTrack = updated
                    loadFields(from: updated)
                }
                isReplacingFile = false
            }
        }
    }

    /// Saves the currently-shown track's edits, then moves to the adjacent
    /// track and loads its fields — so cycling through an album to fix tags
    /// doesn't require an explicit Save click on every track.
    private func goToPrevious() {
        guard hasPrevious, let index = currentIndex else { return }
        save(andDismiss: false)
        let next = navigationContext[index - 1]
        currentTrack = next
        loadFields(from: next)
    }

    private func goToNext() {
        guard hasNext, let index = currentIndex else { return }
        save(andDismiss: false)
        let next = navigationContext[index + 1]
        currentTrack = next
        loadFields(from: next)
    }

    private func save(andDismiss shouldDismiss: Bool) {
        let tags = tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let year = Int(yearText.trimmingCharacters(in: .whitespaces))
        let trackNumber = Int(trackNumberText.trimmingCharacters(in: .whitespaces))
        let discNumber = Int(discNumberText.trimmingCharacters(in: .whitespaces))
        let bpm = Int(bpmText.trimmingCharacters(in: .whitespaces))

        if let currentTrack {
            library.setRating(rating, for: currentTrack)
            library.updateMetadata(
                for: currentTrack,
                title: title,
                artist: artist,
                album: album,
                genre: genre,
                year: year,
                trackNumber: trackNumber,
                discNumber: discNumber,
                bpm: bpm,
                key: key,
                comments: comments,
                tags: tags
            )
        } else {
            if batchSetRating {
                for track in batchTracks {
                    library.setRating(rating, for: track)
                }
            }
            library.batchUpdateMetadata(
                for: batchTracks,
                title: title,
                artist: artist,
                album: album,
                genre: genre,
                year: year,
                trackNumber: trackNumber,
                discNumber: discNumber,
                bpm: bpm,
                key: key,
                comments: comments,
                addTags: tags
            )
        }

        let targets = currentTrack.map { [$0] } ?? batchTracks
        switch artworkChange {
        case .none: break
        case .reset: library.setArtworkOverride(nil, for: targets)
        case .replace(let data): library.setArtworkOverride(data, for: targets)
        }

        if shouldDismiss { dismiss() }
    }

    @ViewBuilder
    private func labeledField(_ label: String, text: Binding<String>, original: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let original, text.wrappedValue != original {
                    Button("Reset") { text.wrappedValue = original }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            TextField(isBatch ? "Multiple Values" : (original ?? ""), text: text)
                .textFieldStyle(.roundedBorder)
        }
    }
}
