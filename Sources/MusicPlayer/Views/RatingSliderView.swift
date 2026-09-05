import SwiftUI
import MusicPlayerKit

/// A 0–11 rating control. 0 means "unrated" and is shown as a dash. Dragging
/// is continuous (no built-in tick marks / discrete stepping, which reads as
/// jerky on macOS) and only snaps to the nearest whole number once the drag
/// ends, so the motion itself still feels smooth.
///
/// Defaults to white text for its original use — the selected
/// (blue-highlighted) row in the track table (see `RatingCellView`) — but
/// takes a style so it also reads correctly on a plain background, e.g. the
/// mini-player.
struct RatingSliderView: View {
    @Binding var rating: Int
    var style: Style = .onSelectionHighlight

    enum Style {
        /// White text, for use over the table row's blue selection color.
        case onSelectionHighlight
        /// Secondary/accent text, for use on an ordinary background.
        case plain
    }

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
                .foregroundStyle(textColor)
                .frame(minWidth: 18, alignment: .leading)
                .fixedSize()
        }
    }

    private var textColor: Color {
        switch style {
        case .onSelectionHighlight:
            return displayValue == 0 ? Color.white.opacity(0.6) : Color.white
        case .plain:
            return displayValue == 0 ? Color.secondary : Color.accentColor
        }
    }

    private var displayValue: Int {
        isDragging ? Int(liveValue.rounded()) : rating
    }
}
