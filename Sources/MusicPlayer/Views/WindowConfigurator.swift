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
        }
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
