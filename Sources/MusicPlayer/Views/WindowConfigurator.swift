import SwiftUI
import AppKit

/// Hooks into the hosting NSWindow to enable AppKit's built-in frame
/// autosave (position + size persisted to UserDefaults automatically), and
/// to remove the sidebar-toggle button (and its adjoining separator) from
/// the native toolbar while Learn Song mode covers the sidebar they'd
/// otherwise control.
struct WindowConfigurator: NSViewRepresentable {
    var hideSidebarToggle: Bool = false

    /// SwiftUI's own `.toolbar(removing: .sidebarToggle)` doesn't reliably
    /// take effect when toggled reactively — verified by dumping the live
    /// toolbar's item identifiers, which still listed the sidebar toggle
    /// even with that modifier applied and its condition true. These reach
    /// into the underlying `NSToolbar` directly instead, keyed on the
    /// undocumented identifiers SwiftUI assigns a `NavigationSplitView`'s
    /// chrome — fragile across SwiftUI versions, but there's no public API
    /// for it. Just hiding the item's `view` left its toolbar-drawn
    /// button/separator background behind (a hollow capsule + a stray
    /// divider), so this actually removes the items from the toolbar
    /// instead, and reinserts them by identifier when they should return.
    private static let sidebarToggleIdentifier = NSToolbarItem.Identifier("com.apple.SwiftUI.navigationSplitView.toggleSidebar")
    private static let sidebarSeparatorIdentifier = NSToolbarItem.Identifier("com.apple.SwiftUI.splitViewSeparator-0")
    private static let managedIdentifiers = [sidebarToggleIdentifier, sidebarSeparatorIdentifier]

    /// Tracks which of the managed items this instance has pulled out of
    /// the toolbar, and at what index, so they can be put back in the same
    /// spot once Learn Song mode ends.
    final class Coordinator {
        var removedIndices: [NSToolbarItem.Identifier: Int] = [:]
        /// Whether `ensureMinimumSizeForLearnSong` has already run for the
        /// *current* stretch of Learn Song mode — reset back to false once
        /// `hideSidebarToggle` goes false (leaving Learn Song), so it fires
        /// again next time. Without this, every SwiftUI update while
        /// already in Learn Song would re-check the window size, which
        /// would keep fighting a user who deliberately shrinks the window
        /// back down below the minimum after entering.
        var appliedLearnSongMinSize = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.setFrameAutosaveName("MainWindow")
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let hide = hideSidebarToggle
        let coordinator = context.coordinator
        DispatchQueue.main.async {
            Self.setSplitViewChromeHidden(hide, on: nsView.window, coordinator: coordinator)
            Self.grayOutTitlebarText(in: nsView.window)
            if hide {
                if !coordinator.appliedLearnSongMinSize {
                    Self.ensureMinimumSizeForLearnSong(nsView.window)
                    coordinator.appliedLearnSongMinSize = true
                }
            } else {
                coordinator.appliedLearnSongMinSize = false
            }
        }
    }

    /// `LearnSongView` is swapped in in place of the library browser
    /// inside this same window (see `ContentView`), not opened as its own
    /// window — so unlike a fresh `WindowGroup`, nothing ever resizes the
    /// window to fit its `.frame(minWidth:900, minHeight:560)` on its
    /// own; the window just stays whatever size it already was for
    /// browsing the library (autosaved via `setFrameAutosaveName` above,
    /// so it can easily be a short, wide window that's perfectly fine for
    /// a track list but far short of Learn Song's real minimum). With no
    /// scroll container around the whole view, content that doesn't fit
    /// doesn't get a scrollbar — it's silently clipped by the window's
    /// own bounds, which is what made the stave switcher and the bottom
    /// transport bar (the two fixed-size pieces furthest from the top)
    /// disappear entirely with no error. This grows the window (only —
    /// never shrinks a window the user already made bigger) to match
    /// that same minimum content size, keeping its top edge in place so
    /// it grows downward rather than jumping the titlebar off-screen.
    private static func ensureMinimumSizeForLearnSong(_ window: NSWindow?) {
        guard let window else { return }
        // Matches `LearnSongView`'s own `.frame(minWidth:900, minHeight:
        // 560)` plus its `.padding` (56 horizontal each side, 20 top, 56
        // bottom) — plus a little extra for the window's own titlebar,
        // which isn't part of that content frame at all.
        let minContentWidth: CGFloat = 900 + 56 * 2
        let minContentHeight: CGFloat = 560 + 20 + 56 + 28
        var frame = window.frame
        let currentContentHeight = window.contentRect(forFrameRect: frame).height
        let currentContentWidth = window.contentRect(forFrameRect: frame).width
        guard currentContentWidth < minContentWidth || currentContentHeight < minContentHeight else { return }
        let newContentWidth = max(currentContentWidth, minContentWidth)
        let newContentHeight = max(currentContentHeight, minContentHeight)
        let heightDelta = newContentHeight - currentContentHeight
        frame.size.width += newContentWidth - currentContentWidth
        frame.size.height += heightDelta
        // AppKit's frame origin is its bottom-left corner (y increases
        // upward) — without this adjustment, growing `size.height` alone
        // extends the window *downward* from its current bottom edge but
        // also pushes its *top* edge up past where the titlebar was,
        // which reads as the window jumping rather than growing in place.
        frame.origin.y -= heightDelta
        window.setFrame(frame, display: true, animate: true)
    }

    /// The native title text (`library.currentViewTitle`, set via
    /// `TrackListView`'s `.navigationTitle`) always renders in the system's
    /// default title color — a `.principal` toolbar item meant to
    /// re-color it instead sat *alongside* it as a duplicate (see
    /// `ContentView`), so there's no SwiftUI-level way to touch it. This
    /// walks the titlebar's own view hierarchy for the `NSTextField`
    /// AppKit uses to draw that title and recolors it directly. Re-run on
    /// every update since the title text field isn't guaranteed to exist
    /// yet the first time this runs, and AppKit may swap it out.
    private static func grayOutTitlebarText(in window: NSWindow?) {
        guard let contentView = window?.contentView, let frameView = contentView.superview else { return }
        for subview in frameView.subviews where subview !== contentView {
            grayOutTextFields(in: subview)
        }
    }

    private static func grayOutTextFields(in view: NSView) {
        if let textField = view as? NSTextField {
            textField.textColor = .secondaryLabelColor
        }
        for subview in view.subviews {
            grayOutTextFields(in: subview)
        }
    }

    private static func setSplitViewChromeHidden(_ hidden: Bool, on window: NSWindow?, coordinator: Coordinator) {
        guard let toolbar = window?.toolbar else { return }
        for identifier in managedIdentifiers {
            let currentIndex = toolbar.items.firstIndex { $0.itemIdentifier == identifier }
            if hidden {
                guard let index = currentIndex else { continue }
                coordinator.removedIndices[identifier] = index
                toolbar.removeItem(at: index)
            } else if currentIndex == nil, let restoreIndex = coordinator.removedIndices[identifier] {
                toolbar.insertItem(withItemIdentifier: identifier, at: min(restoreIndex, toolbar.items.count))
                coordinator.removedIndices[identifier] = nil
            }
        }
    }
}
