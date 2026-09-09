import SwiftUI
import MusicPlayerKit

/// A simplified guitar tab display, laid out like a real score: wrapped
/// into multiple lines of a few bars each (rather than one long
/// horizontally-scrolling strip), with bar-number labels, a moving
/// playhead, tap-to-seek, and the view auto-scrolling to keep whichever
/// line is currently playing in view. Not engraved tab notation (rhythm
/// stems/beams) — just enough to follow along and see what's coming,
/// string/fret numbers with bar lines between them.
struct TabGridView: View {
    let sequence: NoteSequence
    let currentTime: TimeInterval
    var onSeek: (TimeInterval) -> Void = { _ in }
    /// When set (after a Record/Evaluate pass), colors each fret marker
    /// green (hit) or red (missed) instead of the neutral default.
    var evaluation: PerformanceEvaluator.Result?

    /// User-adjustable zoom, applied on top of `baseSecondsPerPixel` —
    /// "control zoom to control bar size." Smoothly adjustable two ways:
    /// the +/- buttons animate to their new value, and a trackpad pinch
    /// (`magnifyGesture`) tracks continuously.
    @State private var zoomScale: CGFloat = 1.0
    /// `zoomScale` as of the start of the current pinch gesture — pinch
    /// magnification is relative ("1.2x bigger than when you started
    /// pinching"), not absolute, so this is the baseline each new gesture
    /// scales from.
    @State private var zoomAtGestureStart: CGFloat = 1.0
    private static let zoomRange: ClosedRange<CGFloat> = 0.5...2.5

    private func clampZoom(_ value: CGFloat) -> CGFloat {
        min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, value))
    }

    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                zoomScale = clampZoom(zoomAtGestureStart * value)
            }
            .onEnded { _ in
                zoomAtGestureStart = zoomScale
            }
    }
    // 195, not 130 — at 100% zoom this puts ~4 bars on a line on a
    // typical laptop-width window instead of ~6, which read as too dense.
    private let basePixelsPerSecond: CGFloat = 195
    private var pixelsPerSecond: CGFloat { basePixelsPerSecond * zoomScale }
    private let rowHeight: CGFloat = 30
    private let labelWidth: CGFloat = 22
    /// Reserves room above the strings for bar-number labels and
    /// hammer-on/pull-off/slide tie glyphs on the top string, so neither
    /// gets clipped by the canvas's own top edge.
    private let headerHeight: CGFloat = 22
    /// Nudges every note a little right of its exact time position so the
    /// first note of a bar doesn't land right on top of that bar's
    /// dividing line.
    private let notePadding: CGFloat = 12
    /// Bar numbers are reference info, not core to reading the tab — off
    /// by default so the view opens calm (just strings/frets/playhead/
    /// ties/beat ticks), with detail one click away.
    @State private var showDetails = false
    /// String 1 (high e) through string 6 (low E), top to bottom.
    private let stringLabels = ["e", "B", "G", "D", "A", "E"]
    /// Room below the last string for a missed-note's "late"/"early"/
    /// "wrong"/"miss" label — without it, the bottom string's label had
    /// nowhere to render but past the canvas's own bottom edge, and got
    /// clipped away entirely.
    private let footerHeight: CGFloat = 14

    private var contentHeight: CGFloat {
        headerHeight + CGFloat(stringLabels.count) * rowHeight + footerHeight
    }

    private func stringY(_ index: Int) -> CGFloat {
        headerHeight + rowHeight * CGFloat(index) + rowHeight / 2
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
            .gesture(magnifyGesture)
        }
        .frame(minHeight: 280)
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
                    withAnimation(.easeInOut(duration: 0.15)) {
                        zoomScale = clampZoom(zoomScale - 0.25)
                    }
                    zoomAtGestureStart = zoomScale
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
                    withAnimation(.easeInOut(duration: 0.15)) {
                        zoomScale = clampZoom(zoomScale + 0.25)
                    }
                    zoomAtGestureStart = zoomScale
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
        let usableWidth = max(60, availableWidth - labelWidth - 16)

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
                // first bar belongs there only, not here too — a
                // `ClosedRange` (inclusive on both ends) was drawing that
                // note a second time at the tail of this line.
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
        // Sized to what this line actually needs, not just the available
        // width — a defensive floor under the bars-per-line estimate, so
        // if a piece has irregular bar lengths and a line runs a little
        // wide, its own ScrollView (below) still reaches every note
        // instead of clipping it with no way to get to it.
        let neededWidth = CGFloat(range.upperBound - lineStart) * pixelsPerSecond + notePadding + 20
        let lineWidth = max(availableWidth - labelWidth - 16, neededWidth)

        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Color.clear.frame(width: labelWidth, height: headerHeight)
                ForEach(stringLabels, id: \.self) { label in
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: labelWidth, height: rowHeight)
                }
                // Matches `footerHeight` so this column stays exactly as
                // tall as the canvas beside it — otherwise the HStack
                // centers it vertically and every string label drifts out
                // of alignment with its actual string line.
                Color.clear.frame(width: labelWidth, height: footerHeight)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        for index in stringLabels.indices {
                            let y = stringY(index)
                            var path = Path()
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: size.width, y: y))
                            context.stroke(path, with: .color(.secondary.opacity(0.32)), lineWidth: 1)
                        }

                        for (barIndex, barStart) in sequence.barStartTimes.enumerated() where range.contains(barStart) {
                            let x = CGFloat(barStart - lineStart) * pixelsPerSecond
                            if barStart > lineStart {
                                var path = Path()
                                path.move(to: CGPoint(x: x, y: headerHeight))
                                path.addLine(to: CGPoint(x: x, y: size.height))
                                context.stroke(path, with: .color(.primary.opacity(0.4)), lineWidth: 1.5)
                            }
                            if showDetails {
                                context.draw(
                                    Text("\(barIndex + 1)").font(.system(size: 9)).foregroundColor(.secondary.opacity(0.7)),
                                    at: CGPoint(x: x + 8, y: headerHeight / 2)
                                )
                            }

                            // Very subtle ticks at each interior beat of
                            // the bar (beat 1 is the barline itself, so
                            // it's skipped here) — shows rhythmic position
                            // at a glance without any text, always on
                            // since it's light enough not to add clutter.
                            // Offset by notePadding, same as notes
                            // themselves, so a tick passes through any
                            // note that actually falls on that beat
                            // instead of sitting just before it.
                            let barEnd = barIndex + 1 < sequence.barStartTimes.count ? sequence.barStartTimes[barIndex + 1] : sequence.duration
                            let beatDuration = (barEnd - barStart) / Double(max(sequence.beatsPerBar, 1))
                            for beat in 1..<max(sequence.beatsPerBar, 1) {
                                let beatTime = barStart + beatDuration * Double(beat)
                                guard range.contains(beatTime) else { continue }
                                let beatX = CGFloat(beatTime - lineStart) * pixelsPerSecond + notePadding
                                var tick = Path()
                                tick.move(to: CGPoint(x: beatX, y: headerHeight))
                                tick.addLine(to: CGPoint(x: beatX, y: size.height))
                                // Fine dotted rather than a solid stroke —
                                // a solid line at every beat, on top of the
                                // string lines, read as a grid.
                                context.stroke(
                                    tick,
                                    with: .color(.secondary.opacity(0.32)),
                                    style: StrokeStyle(lineWidth: 0.75, dash: [1.5, 2.5])
                                )
                            }
                        }

                        // Closes the line with a final barline at its
                        // right edge even though that boundary belongs to
                        // the *next* line's first bar — a real score's
                        // lines always end with a closing barline,
                        // regardless of how zoom happened to wrap it.
                        let closingX = CGFloat(range.upperBound - lineStart) * pixelsPerSecond
                        var closingLine = Path()
                        closingLine.move(to: CGPoint(x: closingX, y: headerHeight))
                        closingLine.addLine(to: CGPoint(x: closingX, y: size.height))
                        context.stroke(closingLine, with: .color(.primary.opacity(0.4)), lineWidth: 1.5)

                        if range.contains(currentTime) {
                            let playheadX = CGFloat(currentTime - lineStart) * pixelsPerSecond + notePadding
                            var playhead = Path()
                            playhead.move(to: CGPoint(x: playheadX, y: headerHeight))
                            playhead.addLine(to: CGPoint(x: playheadX, y: size.height))
                            context.stroke(playhead, with: .color(.accentColor), lineWidth: 2)
                        }

                        drawArticulationTies(in: range, lineStart: lineStart, context: &context)
                    }
                    .frame(width: lineWidth, height: contentHeight)

                    ForEach(Array(sequence.notes.enumerated()).filter { range.contains($0.element.startTime) }, id: \.offset) { _, note in
                        if let string = note.string, (1...stringLabels.count).contains(string) {
                            fretMarker(for: note)
                                .position(
                                    x: CGFloat(note.startTime - lineStart) * pixelsPerSecond + notePadding,
                                    y: stringY(string - 1)
                                )
                        }
                    }
                }
                .frame(width: lineWidth, height: contentHeight)
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture()
                        .onEnded { value in
                            onSeek(max(0, lineStart + Double((value.location.x - notePadding) / pixelsPerSecond)))
                        }
                )
            }
            .frame(width: lineWidth, height: contentHeight)
        }
    }

    @ViewBuilder
    private func fretMarker(for note: ScoreNote) -> some View {
        Text("\(note.fret ?? 0)")
            .font(.custom("HelveticaNeue-Light", size: 19))
            .fontWeight(isEvaluated(note) ? .regular : .bold)
            .monospacedDigit()
            .foregroundStyle(markerForeground(for: note))
            .frame(width: 26, height: 24)
            // An overlay, not layout content — keeps the fret number's own
            // centering on the string line untouched regardless of whether
            // a label is present.
            .overlay(alignment: .bottom) {
                if let label = missReasonLabel(for: note) {
                    Text(label)
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(markerForeground(for: note))
                        .fixedSize()
                        .offset(y: 11)
                }
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

    /// Draws a small connecting curve + "H"/"P"/"s" glyph between two
    /// consecutive same-string notes where the second is a hammer-on,
    /// pull-off, or slide destination — standard tab-notation shorthand
    /// for "don't re-pick this note." When the origin note fell on the
    /// *previous* line (the technique spans a line break), still marks
    /// the destination note with a short stub + label rather than
    /// dropping the tie entirely just because its other half is offscreen.
    private func drawArticulationTies(in range: Range<TimeInterval>, lineStart: TimeInterval, context: inout GraphicsContext) {
        for (index, note) in sequence.notes.enumerated() {
            guard range.contains(note.startTime), index > 0, let articulation = note.incomingArticulation else { continue }
            let previous = sequence.notes[index - 1]
            guard let string = note.string, previous.string == string, (1...stringLabels.count).contains(string) else { continue }
            let x2 = CGFloat(note.startTime - lineStart) * pixelsPerSecond + notePadding
            let y = stringY(string - 1)
            let label = switch articulation {
            case .hammerOn: "H"
            case .pullOff: "P"
            case .slide: "s"
            }

            if previous.startTime >= lineStart {
                let x1 = CGFloat(previous.startTime - lineStart) * pixelsPerSecond + notePadding
                guard x2 > x1 else { continue }
                var tie = Path()
                tie.move(to: CGPoint(x: x1 + 10, y: y - 12))
                tie.addQuadCurve(to: CGPoint(x: x2 - 10, y: y - 12), control: CGPoint(x: (x1 + x2) / 2, y: y - 19))
                context.stroke(tie, with: .color(.secondary), lineWidth: 1)
                context.draw(
                    Text(label).font(.system(size: 11, weight: .bold)).foregroundColor(.secondary),
                    at: CGPoint(x: (x1 + x2) / 2, y: max(y - 22, headerHeight - 4))
                )
            } else {
                // Origin note is on the previous line: a short stub
                // leading in from the left edge, so the technique is at
                // least visible on its destination note.
                var stub = Path()
                stub.move(to: CGPoint(x: max(x2 - 24, 0), y: y - 12))
                stub.addQuadCurve(to: CGPoint(x: x2 - 10, y: y - 12), control: CGPoint(x: x2 - 17, y: y - 19))
                context.stroke(stub, with: .color(.secondary), lineWidth: 1)
                context.draw(
                    Text(label).font(.system(size: 11, weight: .bold)).foregroundColor(.secondary),
                    at: CGPoint(x: max(x2 - 17, headerHeight), y: max(y - 22, headerHeight - 4))
                )
            }
        }
    }

    // Miss is amber, not red — this is a practice tool, not an alarm;
    // amber reads as "try again" rather than a scolding.
    private func isEvaluated(_ note: ScoreNote) -> Bool {
        evaluation?.perNote.contains(where: { $0.note == note }) ?? false
    }

    // Bold and neutral until a note's been played and scored — then it
    // switches to regular weight, colored by the result: green for a hit,
    // red for a clean miss or a confidently-wrong pitch (nothing was
    // close, or the wrong thing was clearly there), amber for early/late
    // (something right was there, just off in time — a lesser miss).
    private func markerForeground(for note: ScoreNote) -> Color {
        guard let result = evaluation?.perNote.first(where: { $0.note == note }) else { return .primary }
        if result.hit { return .green }
        switch result.missReason {
        case .missed, .wrongNote, .none: return .red
        case .early, .late: return .orange
        }
    }
}
