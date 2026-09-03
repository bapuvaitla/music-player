import SwiftUI
import AppKit

/// Sets the hosting NSWindow's level so it floats above other windows (or
/// not), driven by a bound flag rather than being hardcoded — used by the
/// mini player's pin toggle.
struct WindowLevelController: NSViewRepresentable {
    let isFloating: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { apply(to: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { apply(to: nsView.window) }
    }

    private func apply(to window: NSWindow?) {
        guard let window else { return }
        window.level = isFloating ? .floating : .normal
        window.collectionBehavior.insert(.fullScreenAuxiliary)
    }
}
