import SwiftUI
import AppKit

/// Hooks into the hosting NSWindow to enable AppKit's built-in frame
/// autosave (position + size persisted to UserDefaults automatically).
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.setFrameAutosaveName("MainWindow")
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
