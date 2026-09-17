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
        // space its parent offered, with no margin at all. Every piece is
        // now a whole-number size (3/8/3 wide, 12 tall) that sums to
        // exactly the icon's own 14×12 frame — and 14/12 both divide the
        // outer 28×22 button evenly on each side (7pt and 5pt). The
        // previous 16×13 icon left a fractional 4.5pt vertical margin,
        // which rendered as a soft half-pixel offset — the two bars
        // technically the same width, but one landing on a slightly
        // different sub-pixel boundary than the other, so it read as
        // thinner/cut off.
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(color)
                .frame(width: 3, height: 12)
            Rectangle()
                .fill(color)
                .frame(width: 8, height: 2)
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(color)
                .frame(width: 3, height: 12)
        }
        .frame(width: 14, height: 12)
    }
}
