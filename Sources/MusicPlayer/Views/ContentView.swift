import SwiftUI
import Foundation
import MusicPlayerKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var coordinator: PlaybackCoordinator
    @Environment(\.openWindow) private var openWindow
    @State private var showingImporter = false
    @State private var addFolderSummary: String?
    @State private var showingColumnsPopover = false
    @State private var showingFontPopover = false
    @State private var isImportDropTargeted = false
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
        VStack(spacing: 0) {
            NowPlayingBar()

            NavigationSplitView {
                SidebarView()
            } detail: {
                TrackListView()
            }
        }
        .environment(\.font, resolvedAppFont)
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
            ToolbarItem(placement: .automatic) {
                Button {
                    showingFontPopover = true
                } label: {
                    Label("Font", systemImage: "textformat")
                }
                .help("Choose the app's font")
                .popover(isPresented: $showingFontPopover) {
                    FontPickerPopover(selection: $appFontPostscriptName)
                }
            }

            ToolbarItem(placement: .automatic) {
                Button(action: decreaseFontSize) {
                    Label("Decrease Font Size", systemImage: "textformat.size.smaller")
                }
                .help("Decrease font size")
                .disabled(appFontSize <= Self.fontSizeRange.lowerBound)
            }

            ToolbarItem(placement: .automatic) {
                Button(action: increaseFontSize) {
                    Label("Increase Font Size", systemImage: "textformat.size.larger")
                }
                .help("Increase font size")
                .disabled(appFontSize >= Self.fontSizeRange.upperBound)
            }

            ToolbarItem(placement: .navigation) {
                Button {
                    showingImporter = true
                } label: {
                    Label("Add Music", systemImage: "folder.badge.plus")
                }
                .help("Add folders or individual tracks to your library")
            }

            ToolbarItem(placement: .navigation) {
                Button {
                    Task { await library.rescanAllFolders() }
                } label: {
                    Label("Rescan Library", systemImage: "arrow.clockwise")
                }
                .help("Re-scan every added folder for new or changed files")
                .disabled(library.scannedFolderPaths.isEmpty)
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    showingColumnsPopover = true
                } label: {
                    Label("Columns", systemImage: "line.3.horizontal")
                        .rotationEffect(.degrees(90))
                }
                .help("Choose and reorder columns")
                .popover(isPresented: $showingColumnsPopover) {
                    ColumnsOrderPopover()
                }
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    openWindow(id: "miniPlayer")
                } label: {
                    Label("Mini Player", systemImage: "pip")
                }
                .help("Open the floating mini player")
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
        .searchable(text: $library.searchText, placement: .toolbar, prompt: "Search")
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
        }
        .background(WindowConfigurator())
        .background(
            SpacebarPlayPauseMonitor {
                coordinator.togglePlayPause(fallbackQueue: library.visibleTracks)
            }
        )
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
