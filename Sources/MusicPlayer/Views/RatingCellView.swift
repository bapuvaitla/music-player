import SwiftUI

/// Shows a plain rating number for unselected rows, and swaps in the
/// interactive `RatingSliderView` only for the currently-selected row —
/// so the table stays quiet until you actually click into a track.
///
/// Both states are always present in the view tree (toggled via opacity,
/// not an `if`/`else` branch) so selecting a row is a cheap property
/// update rather than a structural rebuild — that rebuild was landing in
/// the middle of double-click's timing window and made double-click-to-play
/// feel unresponsive.
struct RatingCellView: View {
    @Binding var rating: Int
    let isSelected: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            Text(rating == 0 ? "–" : "\(rating)")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(rating == 0 ? Color.secondary : Color.accentColor)
                .opacity(isSelected ? 0 : 1)

            RatingSliderView(rating: $rating)
                .opacity(isSelected ? 1 : 0)
                .allowsHitTesting(isSelected)
        }
    }
}
