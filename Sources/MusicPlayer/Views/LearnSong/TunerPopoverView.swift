import SwiftUI
import MusicPlayerKit

/// The pop-up content for the corner tuner button in `LearnSongView` — a
/// standalone chromatic tuner, independent of whatever tab/vocal sequence
/// is loaded. Starts listening when the popover opens, stops the moment it
/// closes (`.onDisappear`), so it never keeps a mic tap running in the
/// background.
struct TunerPopoverView: View {
    @StateObject private var tuner = TunerEngine()

    private var cents: Double { tuner.reading?.cents ?? 0 }

    private var statusColor: Color {
        guard tuner.reading != nil else { return .secondary }
        let magnitude = abs(cents)
        if magnitude < 5 { return .green }
        if magnitude < 15 { return .yellow }
        return .red
    }

    var body: some View {
        VStack(spacing: 14) {
            Text(tuner.reading?.noteName ?? "—")
                .font(.system(size: 52, weight: .semibold, design: .rounded))
                .foregroundStyle(statusColor)
                .frame(height: 60)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.12), value: tuner.reading?.noteName)

            waveform

            // The meter is the whole point of going wider — more pixels
            // per cent makes small tuning errors easier to actually see,
            // not just easier to read the number for.
            meter

            Text(frequencyText)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .frame(width: 640)
        .background(Color.tunerPopoverBackground)
        // The background is a fixed dark brown in both appearances (see
        // `tunerPopoverBackground`), so force dark text/secondary colors
        // too — otherwise light mode's dark-gray `.secondary` reads with
        // almost no contrast against it.
        .preferredColorScheme(.dark)
        .onAppear { tuner.start() }
        .onDisappear { tuner.stop() }
    }

    private var frequencyText: String {
        guard let reading = tuner.reading else { return "Listening…" }
        return String(format: "%.1f Hz", reading.frequency)
    }

    /// A live oscilloscope-style trace of the raw input signal — mostly
    /// decorative (the needle below is what you actually read the tuning
    /// off), but it makes the popover feel alive rather than a static
    /// readout, and doubles as a sanity check that the mic is picking
    /// something up at all. Deliberately undownsampled and unanimated: it
    /// draws every raw sample from the latest buffer exactly as captured,
    /// snapping straight to each new buffer rather than tweening toward
    /// it — a true (if jagged) trace of the actual signal, not a
    /// smoothed-looking approximation of one.
    private var waveform: some View {
        GeometryReader { geo in
            let samples = tuner.waveform
            let width = geo.size.width
            let midY = geo.size.height / 2

            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.panelBackground)
                Path { path in
                    guard samples.count > 1 else {
                        path.move(to: CGPoint(x: 0, y: midY))
                        path.addLine(to: CGPoint(x: width, y: midY))
                        return
                    }
                    let stepX = width / CGFloat(samples.count - 1)
                    for (index, sample) in samples.enumerated() {
                        let x = CGFloat(index) * stepX
                        let y = midY - CGFloat(sample) * midY * 0.85
                        if index == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(statusColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var meter: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let clampedCents = max(-50, min(50, cents))
            let needleX = tuner.reading != nil ? width / 2 + (clampedCents / 50) * (width / 2) : width / 2

            ZStack {
                Capsule()
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: 5)
                // Tick marks every 10 cents — with this much width now
                // available, they're what actually turns "the dot moved a
                // bit" into "that's about 15 cents flat" at a glance,
                // which is the whole reason to widen the meter at all.
                // The center tick (0 cents) reads taller than the rest.
                ForEach(Array(stride(from: -50, through: 50, by: 10)), id: \.self) { tickCents in
                    Rectangle()
                        .fill(Color.secondary.opacity(tickCents == 0 ? 0.6 : 0.3))
                        .frame(width: 1, height: tickCents == 0 ? 18 : 10)
                        .offset(x: (Double(tickCents) / 50) * (width / 2))
                }
                // The in-tune zone, centered — the only part of the track
                // that's actually "correct," so it's drawn in the same
                // green the needle turns when it lands there.
                Capsule()
                    .fill(Color.green.opacity(0.35))
                    .frame(width: width * 0.1, height: 5)
                Circle()
                    .fill(statusColor)
                    .frame(width: 15, height: 15)
                    .offset(x: needleX - width / 2)
                    .animation(.easeOut(duration: 0.08), value: needleX)
            }
            .frame(width: width, height: geo.size.height)
        }
        .frame(height: 32)
    }
}
