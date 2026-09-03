import SwiftUI
import MusicPlayerKit

/// A 0–11 rating control. 0 means "unrated" and is shown as a dash. Dragging
/// is continuous (no built-in tick marks / discrete stepping, which reads as
/// jerky on macOS) and only snaps to the nearest whole number once the drag
/// ends, so the motion itself still feels smooth.
///
/// Only ever shown for the selected (blue-highlighted) row — see
/// `RatingCellView` — so its label is always rendered in white for contrast
/// against the selection background rather than the normal secondary/accent
/// colors used elsewhere.
struct RatingSliderView: View {
    @Binding var rating: Int

    @State private var isDragging = false
    @State private var liveValue: Double = 0

    private let range: ClosedRange<Double> = 0...11

    var body: some View {
        HStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { isDragging ? liveValue : Double(rating) },
                    set: { liveValue = $0 }
                ),
                in: range,
                onEditingChanged: { editing in
                    if editing {
                        isDragging = true
                        liveValue = Double(rating)
                    } else {
                        rating = Int(liveValue.rounded())
                        isDragging = false
                    }
                }
            )
            .controlSize(.small)
            .frame(minWidth: 70)

            Text(displayValue == 0 ? "–" : "\(displayValue)")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(displayValue == 0 ? Color.white.opacity(0.6) : Color.white)
                .frame(minWidth: 18, alignment: .leading)
                .fixedSize()
        }
    }

    private var displayValue: Int {
        isDragging ? Int(liveValue.rounded()) : rating
    }
}
