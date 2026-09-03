import SwiftUI
import AppKit

/// Scrolls the Table's underlying NSTableView to a given row — used by
/// Cmd+L to bring the currently-playing track into view. `trigger` should
/// be bumped on every invocation so this fires even when locating the same
/// row twice in a row.
struct TableScrollController: NSViewRepresentable {
    let rowIndex: Int?
    let trigger: Int

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let rowIndex else { return }
        DispatchQueue.main.async {
            guard let window = nsView.window,
                  let tableView = Self.findTableView(in: window.contentView) else { return }
            tableView.scrollRowToVisible(rowIndex)
        }
    }

    private static func findTableView(in view: NSView?) -> NSTableView? {
        guard let view else { return nil }
        if let tableView = view as? NSTableView { return tableView }
        for subview in view.subviews {
            if let found = findTableView(in: subview) { return found }
        }
        return nil
    }
}
