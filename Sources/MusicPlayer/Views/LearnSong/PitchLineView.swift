import SwiftUI
import MusicPlayerKit

/// A simplified piano-roll view of a vocal melody, laid out like a real
/// score: wrapped into multiple lines of a few bars each, with bar-number
/// labels, a moving playhead, tap-to-seek, and auto-scroll to keep the
/// currently-playing line in view. Not engraved staff notation.
struct PitchLineView: View {
    let sequence: NoteSequence
    let currentTime: TimeInterval
    var onSeek: (TimeInterval) -> Void = { _ in }
    /// When set (after a Record/Evaluate pass), colors each note bar green
    /// (hit) or red (missed) instead of the neutral default.
    var evaluation: PerformanceEvaluator.Result?

    /// User-adjustable zoom, applied on top of `basePixelsPerSecond` —
    /// "control zoom to control bar size."
    @State private var zoomScale: CGFloat = 1.0
    // 195, not 130 — at 100% zoom this puts ~4 bars on a line on a
    // typical laptop-width window instead of ~6, which read as too dense.
    private let basePixelsPerSecond: CGFloat = 195
    private var pixelsPerSecond: CGFloat { basePixelsPerSecond * zoomScale }
    private let noteHeight: CGFloat = 11
    private let pitchAreaHeight: CGFloat = 120
    private let headerHeight: CGFloat = 22
    /// Nudges every note a little right of its exact time position so the
    /// first note of a bar doesn't land right on top of that bar's
    /// dividing line.
    private let notePadding: CGFloat = 12
    /// Bar numbers are reference info, not core to following the melody —
    /// off by default so the view opens calm, with detail one click away.
    @State private var showDetails = false
    /// Room below the lowest note for a missed-note's "late"/"early"/
    /// "wrong"/"miss" label — a wide-range melody's lowest note can sit
    /// close enough to the bottom edge that the label would otherwise be
    /// clipped away, same issue as `TabGridView`'s bottom string.
    private let footerHeight: CGFloat = 14

    private var lineHeight: CGFloat { headerHeight + pitchAreaHeight + footerHeight }

    private var pitchRange: ClosedRange<Int> {
        let pitches = sequence.notes.map(\.midiPitch)
        guard let lo = pitches.min(), let hi = pitches.max(), lo < hi else {
            let center = pitches.first ?? 60
            return (center - 5)...(center + 5)
        }
        return (lo - 2)...(hi + 2)
    }

    private func y(forPitch pitch: Int) -> CGFloat {
        let range = pitchRange
        let span = CGFloat(range.upperBound - range.lowerBound)
        guard span > 0 else { return headerHeight + pitchAreaHeight / 2 }
        let fraction = CGFloat(pitch - range.lowerBound) / span
        return headerHeight + pitchAreaHeight * (1 - fraction)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            zoomControl
            GeometryReader { geometry in
                let lineRanges = lines(for: geometry.size.width)
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(Array(lineRanges.enumerated()), id: \.offset) { index, range in
                                lineView(range: range, availableWidth: geometry.size.width)
                                    .id(index)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    // Keyed on currentTime itself (not a derived line
                    // index) so a loop wrapping back to its start — a
                    // backward jump in currentTime — is guaranteed to be
                    // seen; a jump-triggered scroll snaps instantly
                    // rather than animating, since a looping region can
                    // wrap several times a second for a short loop.
                    .onChange(of: currentTime) { oldTime, newTime in
                        guard let newIndex = lineRanges.firstIndex(where: { $0.contains(newTime) }),
                              newIndex != lastScrolledLineIndex else { return }
                        lastScrolledLineIndex = newIndex
                        if newTime < oldTime - 0.5 {
                            proxy.scrollTo(newIndex, anchor: .center)
                        } else {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                proxy.scrollTo(newIndex, anchor: .center)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(minHeight: 240)
    }

    @State private var lastScrolledLineIndex: Int?

    private var zoomControl: some View {
        HStack(spacing: 10) {
            Button {
                showDetails.toggle()
            } label: {
                Image(systemName: showDetails ? "number.circle.fill" : "number.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(showDetails ? Color.primary : Color.secondary)
            .help("Show bar numbers")

            HStack(spacing: 6) {
                Button {
                    zoomScale = max(0.5, zoomScale - 0.25)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .buttonStyle(.plain)
                .help("Zoom out (smaller bars)")

                Text("\(Int((zoomScale * 100).rounded()))%")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 38)

                Button {
                    zoomScale = min(2.5, zoomScale + 0.25)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .buttonStyle(.plain)
                .help("Zoom in (bigger bars)")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    /// Wraps the source's bars into lines the way text wraps into
    /// paragraphs: bars are added to the current line one at a time, and
    /// as soon as the next bar wouldn't *fully* fit in the remaining
    /// width, that bar starts a new line instead — no bar is ever
    /// partially cut off at the edge. Uses each bar's own real width (not
    /// an average), so it holds up even when bars vary in length. Falls
    /// back to a single line spanning the whole piece if the source had
    /// no `<measure>` data to wrap by.
    private func lines(for availableWidth: CGFloat) -> [Range<TimeInterval>] {
        let bars = sequence.barStartTimes
        guard !bars.isEmpty else { return [0..<max(sequence.duration + 0.001, 0.002)] }
        let usableWidth = max(60, availableWidth - 16)

        func barWidth(_ index: Int) -> CGFloat {
            let start = bars[index]
            let end = index + 1 < bars.count ? bars[index + 1] : sequence.duration
            return CGFloat(end - start) * pixelsPerSecond + notePadding
        }

        var result: [Range<TimeInterval>] = []
        var lineStartIndex = 0
        var accumulatedWidth: CGFloat = 0

        for index in bars.indices {
            let width = barWidth(index)
            if index > lineStartIndex, accumulatedWidth + width > usableWidth {
                // Half-open: a note starting exactly at the next line's
                // first bar belongs there only, not here too.
                result.append(bars[lineStartIndex]..<bars[index])
                lineStartIndex = index
                accumulatedWidth = 0
            }
            accumulatedWidth += width
        }
        result.append(bars[lineStartIndex]..<(sequence.duration + 0.001))
        return result
    }

    @ViewBuilder
    private func lineView(range: Range<TimeInterval>, availableWidth: CGFloat) -> some View {
        let lineStart = range.lowerBound
        let neededWidth = CGFloat(range.upperBound - lineStart) * pixelsPerSecond + notePadding + 20
        let lineWidth = max(availableWidth - 16, neededWidth)

        ScrollView(.horizontal, showsIndicators: false) {
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    for (barIndex, barStart) in sequence.barStartTimes.enumerated() where range.contains(barStart) {
                        let x = CGFloat(barStart - lineStart) * pixelsPerSecond
                        if barStart > lineStart {
                            var path = Path()
                            path.move(to: CGPoint(x: x, y: headerHeight))
                            path.addLine(to: CGPoint(x: x, y: size.height))
                            context.stroke(path, with: .color(.primary.opacity(0.32)), lineWidth: 1.5)
                        }
                        if showDetails {
                            context.draw(
                                Text("\(barIndex + 1)").font(.system(size: 9)).foregroundColor(.secondary.opacity(0.7)),
                                at: CGPoint(x: x + 8, y: headerHeight / 2)
                            )
                        }
                    }

                    // Closes the line with a final barline at its right
                    // edge, same as the tab view — a score line always
                    // ends with a closing barline regardless of zoom.
                    let closingX = CGFloat(range.upperBound - lineStart) * pixelsPerSecond
                    var closingLine = Path()
                    closingLine.move(to: CGPoint(x: closingX, y: headerHeight))
                    closingLine.addLine(to: CGPoint(x: closingX, y: size.height))
                    context.stroke(closingLine, with: .color(.primary.opacity(0.32)), lineWidth: 1.5)

                    if range.contains(currentTime) {
                        let playheadX = CGFloat(currentTime - lineStart) * pixelsPerSecond + notePadding
                        var path = Path()
                        path.move(to: CGPoint(x: playheadX, y: headerHeight))
                        path.addLine(to: CGPoint(x: playheadX, y: size.height))
                        context.stroke(path, with: .color(.accentColor), lineWidth: 2)
                    }
                }
                .frame(width: lineWidth, height: lineHeight)

                ForEach(Array(sequence.notes.enumerated()).filter { range.contains($0.element.startTime) }, id: \.offset) { _, note in
                    let width = max(4, CGFloat(note.duration) * pixelsPerSecond - 2)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(markerColor(for: note))
                        .frame(width: width, height: noteHeight)
                        // An overlay so the label doesn't shift the bar's
                        // own centered position.
                        .overlay(alignment: .bottom) {
                            if let label = missReasonLabel(for: note) {
                                Text(label)
                                    .font(.system(size: 7, weight: .semibold))
                                    .foregroundStyle(markerColor(for: note))
                                    .fixedSize()
                                    .offset(y: 10)
                            }
                        }
                        .position(
                            x: CGFloat(note.startTime - lineStart) * pixelsPerSecond + notePadding + width / 2,
                            y: y(forPitch: note.midiPitch)
                        )
                }
            }
            .frame(width: lineWidth, height: lineHeight)
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture()
                    .onEnded { value in
                        onSeek(max(0, lineStart + Double((value.location.x - notePadding) / pixelsPerSecond)))
                    }
            )
        }
    }

    // Miss is amber, not red — this is a practice tool, not an alarm;
    // amber reads as "try again" rather than a scolding.
    private func markerColor(for note: ScoreNote) -> Color {
        guard let result = evaluation?.perNote.first(where: { $0.note == note }) else { return .accentColor.opacity(0.55) }
        if result.hit { return .green.opacity(0.7) }
        switch result.missReason {
        case .missed, .wrongNote, .none: return .red.opacity(0.7)
        case .early, .late: return .orange.opacity(0.7)
        }
    }

    // "late"/"early"/"wrong"/"miss" printed right under a missed note, once
    // it's passed — asked for specifically so the checker's sensitivity is
    // visible and checkable, not just trusted.
    private func missReasonLabel(for note: ScoreNote) -> String? {
        guard let evaluation = evaluation?.perNote.first(where: { $0.note == note }), !evaluation.hit else { return nil }
        switch evaluation.missReason {
        case .wrongNote: return "wrong"
        case .early: return "early"
        case .late: return "late"
        case .missed: return "miss"
        case .none: return nil
        }
    }
}
