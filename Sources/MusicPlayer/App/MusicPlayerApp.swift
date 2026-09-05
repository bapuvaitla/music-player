import SwiftUI
import AppKit
import MusicPlayerKit

/// Flushes the currently-playing track's fractional play to disk before the
/// process exits. `recordPartialPlay` normally fires an unstructured `Task`
/// that AppKit is free to tear down mid-write when the app quits — this
/// awaits the write instead, spinning the run loop (rather than blocking the
/// thread outright, which would deadlock a `@MainActor` continuation trying
/// to resume on that same thread) until it lands or a safety timeout passes.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var player: PlayerController?
    var library: LibraryModel?

    func applicationWillTerminate(_ notification: Notification) {
        guard let player, let library, let pending = player.pendingFractionalPlay else { return }
        var finished = false
        Task { @MainActor in
            await library.recordPartialPlayAndWait(pending.fraction, for: pending.track)
            finished = true
        }
        let deadline = Date().addingTimeInterval(2.0)
        while !finished && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }
}

@main
struct MusicPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var player: PlayerController
    @StateObject private var coordinator: PlaybackCoordinator
    @StateObject private var library: LibraryModel
    private let mediaKeyController: MediaKeyController
    @Environment(\.openWindow) private var openWindow

    init() {
        let player = PlayerController()
        let coordinator = PlaybackCoordinator(player: player)

        let library: LibraryModel
        if let store = Self.makeLocalStore() {
            library = LibraryModel(ratingStore: store, playlistStore: store)
        } else {
            let fallback = InMemoryLocalStore()
            library = LibraryModel(ratingStore: fallback, playlistStore: fallback)
        }

        player.onFractionalPlay = { [weak library] track, fraction in
            library?.recordPartialPlay(fraction, for: track)
        }

        // Claims the keyboard media keys / Control Center's Now Playing
        // widget for this app (via MPRemoteCommandCenter) instead of
        // whichever app — typically Music.app — last registered for them.
        mediaKeyController = MediaKeyController(player: player, coordinator: coordinator, library: library)

        _player = StateObject(wrappedValue: player)
        _coordinator = StateObject(wrappedValue: coordinator)
        _library = StateObject(wrappedValue: library)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(player)
                .environmentObject(coordinator)
                .environmentObject(library)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear {
                    appDelegate.player = player
                    appDelegate.library = library
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1100, height: 700)
        .commands {
            // Commands live here at the App/Scene level, so they have no
            // direct access to a window's local @State (which popover is
            // open, what's selected, etc.) — actions that need that post a
            // notification the owning view responds to (see AppCommands
            // and each view's .onReceive). Playback/library actions that
            // only need `player`/`coordinator`/`library` call straight
            // through since those are already right here.
            CommandGroup(replacing: .newItem) {
                Button("Add Music…") {
                    NotificationCenter.default.post(name: .requestAddMusic, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("Rescan Library") {
                    Task { await library.rescanAllFolders() }
                }
                .disabled(library.scannedFolderPaths.isEmpty)
            }

            CommandMenu("Playback") {
                Button(player.isPlaying ? "Pause" : "Play") {
                    coordinator.togglePlayPause(fallbackQueue: library.visibleTracks)
                }

                Button("Next Track") {
                    coordinator.next()
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command])

                Button("Previous Track") {
                    coordinator.previous()
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command])

                Divider()

                Button("Cycle Shuffle Mode") {
                    coordinator.cycleShuffleMode()
                }

                Button("Cycle Repeat Mode") {
                    coordinator.cycleRepeatMode()
                }
            }

            CommandMenu("Track") {
                Button("Edit Info…") {
                    NotificationCenter.default.post(name: .requestEditInfo, object: nil)
                }
                .keyboardShortcut("i", modifiers: [.command])

                Button("Locate Playing Track") {
                    NotificationCenter.default.post(name: .requestLocatePlayingTrack, object: nil)
                }
                .keyboardShortcut("l", modifiers: [.command])
            }

            CommandMenu("View") {
                Button("Columns…") {
                    NotificationCenter.default.post(name: .requestShowColumnsPopover, object: nil)
                }

                Button("Font…") {
                    NotificationCenter.default.post(name: .requestShowFontPopover, object: nil)
                }

                Divider()

                Button("Increase Font Size") {
                    NotificationCenter.default.post(name: .requestIncreaseFontSize, object: nil)
                }
                .keyboardShortcut("=", modifiers: [.command])

                Button("Decrease Font Size") {
                    NotificationCenter.default.post(name: .requestDecreaseFontSize, object: nil)
                }
                .keyboardShortcut("-", modifiers: [.command])
            }

            CommandGroup(after: .windowArrangement) {
                Button("Mini Player") {
                    openWindow(id: "miniPlayer")
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            }
        }

        Window("Mini Player", id: "miniPlayer") {
            MiniPlayerView()
                .environmentObject(player)
                .environmentObject(coordinator)
                .environmentObject(library)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultPosition(.topTrailing)
        .defaultSize(width: 190, height: 300)
    }

    private static func makeLocalStore() -> GRDBLocalStore? {
        do {
            let supportDir = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("MusicPlayer", isDirectory: true)

            try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
            let dbURL = supportDir.appendingPathComponent("library.sqlite")
            return try GRDBLocalStore(databaseURL: dbURL)
        } catch {
            print("Failed to open local database: \(error)")
            return nil
        }
    }
}
