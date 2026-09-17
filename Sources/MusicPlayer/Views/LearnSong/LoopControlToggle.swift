import SwiftUI

/// The small toggle-style button shared by the region-select and loop
/// controls, in both `PlaybackLoopControl` (above each practice pane's
/// score) and `LargeNowPlayingBarView` (the song's own transport): a plain
/// gray box with a darker gray glyph when off, a solid green box with a
/// white glyph when on. A `Toggle` with `.toggleStyle(.button)` and a
/// `.tint` used to render this — its "off" state still read as green at
/// rest, which is exactly the ambiguity this replaces: the two states now
/// need to look nothing alike, not just a shade apart.
struct LoopControlToggle<Icon: View>: View {
    let isActive: Bool
    let help: String
    let action: () -> Void
    @ViewBuilder let icon: (Color) -> Icon

    var body: some View {
        Button(action: action) {
            icon(isActive ? .white : Color.secondary.opacity(0.85))
                .frame(width: 28, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isActive ? Color.green : Color.secondary.opacity(0.15))
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Two short vertical bars joined by a line — a miniature of the region
/// band/handles `LoopScrubBar` itself draws, so the button reads as "this
/// controls that shape on the bar" at a glance. There's no standard system
/// icon for "select a range" worth guessing a name for (unlike "repeat",
/// which SF Symbols already covers well), so this is drawn directly
/// instead, the same reasoning as the transpose control's plain-text glyph.
struct RegionSelectIcon: View {
    let color: Color

    var body: some View {
        // The connecting line used to have no explicit width, so as a
        // Shape with no intrinsic size it stretched to fill however much
        // space its parent offered — up to the full 28pt button box, with
        // no margin at all, which is what made this icon visually larger
        // than the loop button's fixed-size SF Symbol. Giving every piece
        // an explicit size makes the whole icon a fixed 16×13 that centers
        // (with real margin) inside the button, the same as the symbol
        // does.
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(color)
                .frame(width: 2.5, height: 13)
            Rectangle()
                .fill(color)
                .frame(width: 9, height: 2)
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(color)
                .frame(width: 2.5, height: 13)
        }
        .frame(width: 16, height: 13)
    }
}
