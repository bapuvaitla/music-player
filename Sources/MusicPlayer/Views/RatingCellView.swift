import SwiftUI

/// Shows a plain rating number for unselected rows, and swaps in the
/// interactive `RatingSliderView` only for the currently-selected row —
/// so the table stays quiet until you actually click into a track.
///
/// `showSlider` (not just `isSelected`) gates which view actually gets
/// built: an earlier version built a real `RatingSliderView` — a genuine
/// AppKit `Slider` control — for *every* row all the time and just toggled
/// opacity, on the theory that avoiding a structural change would keep
/// selecting a row cheap. That backfired badly at real library scale:
/// switching to a few hundred rows meant instantiating a few hundred live
/// sliders at once, which is exactly what was blocking the main thread for
/// several seconds on "All Tracks." `showSlider` is only true once
/// `dragArmedIDs` (see `TrackListView`) has armed for the selected row —
/// i.e. ~400ms after selection settles, safely past the double-click
/// window — so this row's own structural swap still can't land mid-gesture
/// the way an immediate one did before, while the other few hundred rows
/// never pay for a slider at all. `isSelected` still drives text color
/// alone (matching `RatingSliderView`'s white-on-blue styling) so there's
/// no dark-text-on-blue flash during that short arming delay.
struct RatingCellView: View {
    @Binding var rating: Int
    let isSelected: Bool
    let showSlider: Bool

    var body: some View {
        if showSlider {
            RatingSliderView(rating: $rating)
        } else {
            Text(rating == 0 ? "–" : "\(rating)")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(textColor)
        }
    }

    private var textColor: Color {
        if isSelected {
            return rating == 0 ? Color.white.opacity(0.6) : Color.white
        }
        return rating == 0 ? Color.secondary : Color.accentColor
    }
}
