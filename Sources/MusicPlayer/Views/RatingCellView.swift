import SwiftUI

/// Shows a plain rating number for unselected rows, and swaps in the
/// interactive `RatingSliderView` only for the currently-selected row —
/// so the table stays quiet until you actually click into a track.
///
/// An internal `isArmed` flag (not just `isSelected`) gates which view
/// actually gets built: an earlier version built a real `RatingSliderView`
/// — a genuine AppKit `Slider` control — for *every* row all the time and
/// just toggled opacity, on the theory that avoiding a structural change
/// would keep selecting a row cheap. That backfired badly at real library
/// scale: switching to a few hundred rows meant instantiating a few
/// hundred live sliders at once, which is exactly what was blocking the
/// main thread for several seconds on "All Tracks." `isArmed` only
/// flips true ~400ms after `isSelected` does — safely past the
/// double-click window — so this row's own structural swap still can't
/// land mid-gesture the way an immediate one did before, while the other
/// few hundred rows never pay for a slider at all.
///
/// The arming timer lives *inside* this view (via `.task(id:)`) rather
/// than as external state `TrackListView` computes and passes in — an
/// earlier version did exactly that (a `showSlider` parameter driven by a
/// `dragArmedIDs` set that `TrackListView` armed on a delay), and it
/// silently never worked: `Table` only re-invokes a column's cell-building
/// closure in reaction to things it specifically tracks (selection, sort,
/// the row's own value) — a plain ambient `@State` change elsewhere in
/// the parent view doesn't cause a repaint, confirmed by logging every
/// closure invocation live. The slider only ever appeared because some
/// *unrelated* event (starting playback) happened to trigger a fresh
/// redraw after the 400ms had already passed. Managing the timer here
/// keeps it inside this view's own lifecycle, which SwiftUI reliably
/// re-renders on its own `@State` changes regardless of what `Table`
/// decides to recompute from the outside. `isSelected` still drives text
/// color alone (matching `RatingSliderView`'s white-on-blue styling) so
/// there's no dark-text-on-blue flash during the arming delay.
struct RatingCellView: View {
    @Binding var rating: Int
    let isSelected: Bool

    @State private var isArmed = false

    var body: some View {
        Group {
            if isSelected && isArmed {
                RatingSliderView(rating: $rating)
            } else {
                Text(rating == 0 ? "–" : "\(rating)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(textColor)
            }
        }
        // `.task(id:)` cancels and restarts automatically whenever
        // `isSelected` changes — exactly "re-arm from scratch every time
        // selection changes," with cancellation (not a manually-checked
        // stale flag) handling a selection change that happens again
        // before the delay elapses.
        .task(id: isSelected) {
            isArmed = false
            guard isSelected else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            isArmed = true
        }
    }

    private var textColor: Color {
        if isSelected {
            return rating == 0 ? Color.white.opacity(0.6) : Color.white
        }
        return rating == 0 ? Color.secondary : Color.accentColor
    }
}
