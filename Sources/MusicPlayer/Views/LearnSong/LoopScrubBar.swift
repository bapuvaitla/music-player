import SwiftUI

/// A scrub bar with two draggable handles marking a region, drawn as a
/// highlighted band between them — always visible and draggable, whether
/// or not `loopEnabled` is on (that only recolors the band/handles, as a
/// hint for whether the region will repeat or just play through once).
/// Used by the song's transport (`LargeNowPlayingBarView`) and each
/// practice pane/full score (`PlaybackLoopControl`) alike — all of them
/// read and write the same one shared region (see
/// `LearnSongView.applyLoopRegionToEngines`), not a region of their own.
///
/// `barTimes`/`snapPoints` (below) are proportioned against *this specific
/// call's* `duration` — `LargeNowPlayingBarView` deliberately leaves them
/// empty rather than passing a practiced stave's own bar times, since that
/// stave's `NoteSequence` timeline isn't guaranteed to span the same
/// length as the real song audio (`player.duration`) this bar is actually
/// scaled to; plotting one against the other bunched every bar tick up at
/// the left edge. `PlaybackLoopControl` is safe because it always passes
/// a sequence's bar times alongside that *same* sequence's own duration.
///
/// Uses a named coordinate space so each handle's drag (and the bar's own
/// tap-to-seek) reports its position relative to the *whole bar*, not the
/// small handle view it started on — the standard technique for a custom
/// range control like this in SwiftUI.
struct LoopScrubBar: View {
    let loopEnabled: Bool
    @Binding var loopStart: TimeInterval
    @Binding var loopEnd: TimeInterval
    let duration: TimeInterval
    let currentTime: TimeInterval
    let onSeek: (TimeInterval) -> Void
    /// Bar-start times (from the practiced sequence's own `<measure>`
    /// data, if any) — drawn as small tick marks so a loop region can be
    /// eyeballed against actual bar boundaries.
    var barTimes: [TimeInterval] = []
    /// Bar *and* beat positions (see `NoteSequence.beatTimes`) a dragged
    /// handle softly snaps to — "somewhat, not perfectly" sticky: within
    /// a small pixel radius of a marker it locks on, farther away it
    /// moves freely.
    var snapPoints: [TimeInterval] = []

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let safeDuration = max(duration, 0.1)
            let labelInterval = barLabelInterval(barCount: barTimes.count, width: width)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(height: 6)

                ForEach(barTimes.indices, id: \.self) { index in
                    let x = width * CGFloat(barTimes[index] / safeDuration)
                    Rectangle()
                        .fill(Color.secondary.opacity(0.35))
                        .frame(width: 1, height: 8)
                        .offset(x: x)
                    if index % labelInterval == 0 {
                        Text("\(index + 1)")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .offset(x: x + 2, y: 13)
                    }
                }

                // The band and handles are always shown, regardless of
                // `loopEnabled` — this is the only way to actually drag a
                // region in the first place, so gating it behind the loop
                // toggle (as this used to do) meant there was no way to
                // select a region at all without first turning looping
                // on. `loopEnabled` only changes the color/weight, as a
                // hint for whether it'll repeat (bold accent) or just play
                // through once (quiet gray) — deliberately a big contrast
                // rather than a subtle tint, so "this will loop" reads at
                // a glance.
                let startX = width * CGFloat(loopStart / safeDuration)
                let endX = width * CGFloat(loopEnd / safeDuration)
                Capsule()
                    .fill(loopEnabled ? Color.accentColor : Color.secondary.opacity(0.2))
                    .frame(width: max(2, endX - startX), height: loopEnabled ? 9 : 6)
                    .shadow(color: loopEnabled ? Color.accentColor.opacity(0.45) : .clear, radius: 3)
                    .offset(x: startX)

                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 13, height: 13)
                    .offset(x: width * CGFloat(min(1, max(0, currentTime / safeDuration))) - 6.5)

                handle(time: loopStart, width: width, duration: safeDuration, isLoopEnabled: loopEnabled) { newTime in
                    loopStart = min(newTime, loopEnd - 0.5)
                }
                handle(time: loopEnd, width: width, duration: safeDuration, isLoopEnabled: loopEnabled) { newTime in
                    loopEnd = max(newTime, loopStart + 0.5)
                }
            }
            .coordinateSpace(name: "loopBar")
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture(coordinateSpace: .named("loopBar"))
                    .onEnded { value in
                        onSeek(max(0, min(safeDuration, Double(value.location.x / width) * safeDuration)))
                    }
            )
        }
        .frame(height: 34)
    }

    /// Only every Nth bar gets a number label, spaced out enough that
    /// labels don't overlap given how many bars there are and how wide
    /// the bar actually is.
    private func barLabelInterval(barCount: Int, width: CGFloat) -> Int {
        guard barCount > 0 else { return 1 }
        let pixelsPerBar = width / CGFloat(barCount)
        let minLabelSpacing: CGFloat = 26
        return max(1, Int((minLabelSpacing / max(pixelsPerBar, 1)).rounded(.up)))
    }

    private func handle(
        time: TimeInterval,
        width: CGFloat,
        duration: TimeInterval,
        isLoopEnabled: Bool,
        onChange: @escaping (TimeInterval) -> Void
    ) -> some View {
        let x = width * CGFloat(time / duration)
        return RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(isLoopEnabled ? Color.accentColor : Color.secondary.opacity(0.45))
            .frame(width: isLoopEnabled ? 10 : 8, height: isLoopEnabled ? 24 : 20)
            .shadow(color: isLoopEnabled ? Color.accentColor.opacity(0.5) : .clear, radius: 2)
            .offset(x: x - (isLoopEnabled ? 5 : 4))
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("loopBar"))
                    .onChanged { value in
                        let rawTime = max(0, min(duration, Double(value.location.x / width) * duration))
                        onChange(snapped(rawTime, duration: duration, width: width))
                    }
            )
    }

    /// Softly snaps to the nearest bar/beat marker if it's within a small
    /// pixel radius of the raw drag position — "somewhat, not perfectly"
    /// sticky: far from a marker, the raw position passes through
    /// untouched.
    private func snapped(_ rawTime: TimeInterval, duration: TimeInterval, width: CGFloat) -> TimeInterval {
        guard !snapPoints.isEmpty, width > 0 else { return rawTime }
        let snapRadiusPixels: CGFloat = 6
        let snapRadiusSeconds = Double(snapRadiusPixels / width) * duration
        guard let nearest = snapPoints.min(by: { abs($0 - rawTime) < abs($1 - rawTime) }) else { return rawTime }
        return abs(nearest - rawTime) <= snapRadiusSeconds ? nearest : rawTime
    }
}
