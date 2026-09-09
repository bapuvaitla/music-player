import SwiftUI
import Foundation
import AppKit
import MusicPlayerKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var coordinator: PlaybackCoordinator
    @State private var showingImporter = false
    @State private var addFolderSummary: String?
    @State private var isImportDropTargeted = false
    @State private var showingColumnsPopover = false
    @State private var showingFontPopover = false
    /// The selected font face's PostScript name, or "" for System Default.
    @AppStorage("appFontPostscriptName") private var appFontPostscriptName: String = ""
    @AppStorage("appFontSize") private var appFontSize: Double = 13

    private static let fontSizeRange: ClosedRange<Double> = 9...24

    private var resolvedAppFont: Font {
        guard !appFontPostscriptName.isEmpty else { return .system(size: appFontSize) }
        return .custom(appFontPostscriptName, size: appFontSize)
    }

    private func decreaseFontSize() {
        appFontSize = max(Self.fontSizeRange.lowerBound, appFontSize - 1)
    }

    private func increaseFontSize() {
        appFontSize = min(Self.fontSizeRange.upperBound, appFontSize + 1)
    }

    var body: some View {
        ZStack {
        // NowPlayingBar lives inside the detail column, not spanning the
        // whole window above both columns — it visually "belongs" to the
        // track list rather than sitting ambiguously above the
        // sidebar/detail split, and the sidebar now runs the full window
        // height instead of starting below a bar it has nothing to do
        // with.
        NavigationSplitView {
            SidebarView()
        } detail: {
            VStack(spacing: 0) {
                // `coordinator.player` (a plain reference, not another
                // `@EnvironmentObject` lookup) — see `TrackListView` for
                // why it takes `player` as a plain stored property instead
                // of observing it directly.
                TrackListView(player: coordinator.player)
                    .equatable()
                NowPlayingBar()
            }
        }
        .environment(\.font, resolvedAppFont)
        // Same background as NowPlayingBar right below it, so the native
        // toolbar (icons + the window's title, which doubles as "what
        // you're browsing") reads as one continuous header block rather
        // than a visually separate strip. In Learn Song mode there's no
        // sidebar showing underneath it anymore — just LearnSongView's own
        // `appBackground` — so match that instead, or the toolbar keeps
        // its sage-green sidebar tint sitting oddly above an unrelated page.
        .toolbarBackground(library.learningTrack == nil ? Color.sidebarBackground : Color.appBackground, for: .windowToolbar)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        // Drag folders or audio files from Finder anywhere onto the window
        // to import them — same merge logic as the toolbar's Add Music
        // picker. A thin accent border while something's hovering makes
        // the window itself read as a drop target.
        .overlay {
            if isImportDropTargeted {
                RoundedRectangle(cornerRadius: 0)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            Task { await importURLs(urls) }
            return true
        } isTargeted: { targeted in
            isImportDropTargeted = targeted
        }
        // Cmd+V after copying files/folders in Finder imports them the
        // same way.
        .onPasteCommand(of: [.fileURL]) { providers in
            Task {
                var urls: [URL] = []
                for provider in providers {
                    if let url = await Self.loadFileURL(from: provider) {
                        urls.append(url)
                    }
                }
                await importURLs(urls)
            }
        }
        // These mirror the toolbar buttons below but are triggered by the
        // menu bar's commands (see MusicPlayerApp), which live outside
        // this view and can't reach its local @State directly.
        .onReceive(NotificationCenter.default.publisher(for: .requestAddMusic)) { _ in
            showingImporter = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestShowColumnsPopover)) { _ in
            showingColumnsPopover = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestShowFontPopover)) { _ in
            showingFontPopover = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestIncreaseFontSize)) { _ in
            increaseFontSize()
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestDecreaseFontSize)) { _ in
            decreaseFontSize()
        }
        .toolbar {
            // Ordered left to right as: Columns, Font, Add Music, Rescan,
            // ending just before the trailing search field — all plain
            // `Label`s (icon-only, no custom font size) so macOS renders
            // them at one consistent native toolbar-icon size.
            if library.learningTrack == nil {
                // `.navigation` is the native spot for back/forward
                // controls — right next to the sidebar toggle, ahead of
                // the title — matching Finder/Xcode's own back/forward
                // placement rather than inventing a new one. `ControlGroup`
                // renders the pair as one segmented control, not two
                // separate buttons, which reads as more "native" here too.
                ToolbarItem(placement: .navigation) {
                    ControlGroup {
                        Button {
                            library.goBack()
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .disabled(!library.canGoBack)
                        .help("Back")

                        Button {
                            library.goForward()
                        } label: {
                            Image(systemName: "chevron.right")
                        }
                        .disabled(!library.canGoForward)
                        .help("Forward")
                    }
                }

                // A `.principal` item turned out to sit *alongside* the
                // native title rather than replacing it — two copies of
                // the same text. macOS owns that title's color; not
                // fightable from here, so this just accepts the native
                // black text instead of duplicating it.
                ToolbarItem(placement: .automatic) {
                    Button {
                        showingColumnsPopover = true
                    } label: {
                        Label("Columns", systemImage: "line.3.horizontal")
                    }
                    .help("Choose and reorder columns")
                    .popover(isPresented: $showingColumnsPopover) {
                        ColumnsOrderPopover()
                    }
                }

                ToolbarItem(placement: .automatic) {
                    Menu {
                        Button("Choose Font…") { showingFontPopover = true }
                        Divider()
                        Button(action: increaseFontSize) {
                            Label("Increase Font Size", systemImage: "textformat.size.larger")
                        }
                        .disabled(appFontSize >= Self.fontSizeRange.upperBound)
                        Button(action: decreaseFontSize) {
                            Label("Decrease Font Size", systemImage: "textformat.size.smaller")
                        }
                        .disabled(appFontSize <= Self.fontSizeRange.lowerBound)
                    } label: {
                        Label("Font", systemImage: "textformat")
                    }
                    .help("Font settings")
                    .popover(isPresented: $showingFontPopover) {
                        FontPickerPopover(selection: $appFontPostscriptName)
                    }
                }

                ToolbarItem(placement: .automatic) {
                    Button {
                        showingImporter = true
                    } label: {
                        Label("Add Music", systemImage: "folder.badge.plus")
                    }
                    .help("Add folders or individual tracks to your library")
                }

                ToolbarItem(placement: .automatic) {
                    Button {
                        Task { await library.rescanAllFolders() }
                    } label: {
                        Label("Rescan Library", systemImage: "arrow.clockwise")
                    }
                    .help("Re-scan every added folder for new or changed files")
                    .disabled(library.scannedFolderPaths.isEmpty)
                }

                if library.isScanning {
                    ToolbarItem(placement: .automatic) {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if let addFolderSummary {
                    ToolbarItem(placement: .automatic) {
                        Text(addFolderSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        // A plain `if` around `.searchable` doesn't compile as a modifier —
        // this is the standard way to make one conditional.
        .modifier(ConditionalSearchable(isActive: library.learningTrack == nil, text: $library.searchText))
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.folder, .audio],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result, !urls.isEmpty {
                Task { await importURLs(urls) }
            }
        }
        .task {
            await library.rescanAllFolders()
            await library.loadPlaylists()
            await library.loadPlaceholderTracks()
            // After ratings/play counts are loaded, not before — a sync
            // needs the local state to merge against.
            await library.syncWithiCloud()
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestSyncNow)) { _ in
            Task { await library.syncWithiCloud() }
        }
        // The native sidebar-toggle button is window-level chrome, so it
        // stays in the title bar even while Learn Song's overlay covers the
        // NavigationSplitView underneath — hide it there, since there's
        // nothing visible left for it to toggle.
        .background(WindowConfigurator(hideSidebarToggle: library.learningTrack != nil))
        .background(
            SpacebarPlayPauseMonitor {
                coordinator.togglePlayPause(fallbackQueue: library.visibleTracks)
            }
        )

        // Takes over the whole window rather than a sheet — there's a lot
        // to show at once (tab, melody, and the song's own transport).
        // The library view underneath stays mounted (not torn down), so
        // scroll position/selection survive a round trip through here.
        if let learningTrack = library.learningTrack {
            LearnSongView(track: learningTrack)
                .background(Color.appBackground)
                .transition(.opacity)
                // A sibling of NavigationSplitView in this ZStack, not a
                // descendant of it — `resolvedAppFont`'s `.environment`
                // above only reaches the library view, so without this
                // Learn Song ignored the user's chosen app font entirely.
                .environment(\.font, resolvedAppFont)
        }
        }
        .animation(.default, value: library.learningTrack != nil)
    }

    /// Shared by the toolbar's file importer, dropping files/folders onto
    /// the window, and pasting files copied from Finder — each just
    /// resolves its own `[URL]` and hands them here. Selections can mix
    /// folders and individual files, so each URL is routed to the matching
    /// import path and the counts added up.
    private func importURLs(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }

        var count = 0
        var fileURLs: [URL] = []
        for url in urls {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                count += await library.addFolder(url)
            } else {
                fileURLs.append(url)
            }
        }
        if !fileURLs.isEmpty {
            count += await library.addFiles(fileURLs)
        }

        // Otherwise newly added tracks can be invisible if you were still
        // viewing an unrelated artist/album/playlist filter from before —
        // looks like the add silently failed even though it worked.
        library.resetAllFilters()

        let label = urls.count == 1 ? "“\(urls[0].lastPathComponent)”" : "\(urls.count) items"
        addFolderSummary = count > 0
            ? "Added \(count) track\(count == 1 ? "" : "s") from \(label)"
            : "No audio files found in \(label)"
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        addFolderSummary = nil
    }

    private static func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }
}

/// Applies `.searchable` only when `isActive` — search doesn't make sense
/// while Learn Song has taken over the window, so it disappears from the
/// toolbar there entirely rather than sitting there unused.
private struct ConditionalSearchable: ViewModifier {
    let isActive: Bool
    @Binding var text: String

    func body(content: Content) -> some View {
        if isActive {
            content.searchable(text: $text, placement: .toolbar, prompt: "Search")
        } else {
            content
        }
    }
}
