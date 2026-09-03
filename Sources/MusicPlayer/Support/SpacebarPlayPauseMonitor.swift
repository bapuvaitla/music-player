import SwiftUI
import AppKit

/// Binds a bare spacebar press to Play/Pause, without stealing spaces
/// typed into any text field (search, tags, comments, playlist names, …).
///
/// A `.keyboardShortcut(" ")` on a menu Command doesn't distinguish these
/// cases on its own — macOS checks the menu bar's key equivalents before
/// the responder chain gets a look at the keystroke, so a bare-space menu
/// shortcut would fire even while typing into a focused text field. Real
/// apps that bind spacebar this way (Music, Podcasts, QuickTime) instead
/// use a local event monitor that explicitly checks what currently has
/// keyboard focus — this does the same: if the key window's first
/// responder is actively editing text, the space is left alone to type
/// normally; otherwise it's consumed for Play/Pause.
struct SpacebarPlayPauseMonitor: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.charactersIgnoringModifiers == " ",
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else {
                return event
            }
            // A local monitor fires app-wide, not just for this NSView's
            // own window — checking that view's window missed any sheet
            // (like the "Add Track" edit sheet) presented on top of it,
            // since a sheet is its own separate NSWindow. NSApp.keyWindow
            // is whichever window — main or sheet — actually has keyboard
            // focus right now, which is the correct thing to check.
            if let responder = NSApp.keyWindow?.firstResponder, responder is NSTextView {
                return event
            }
            action()
            return nil
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var monitor: Any?
    }
}
