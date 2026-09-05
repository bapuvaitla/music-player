import Foundation
import AVFoundation

/// Captures microphone input — or, if selected as the Mac's system default
/// input device, a directly-connected instrument — for
/// `PerformanceEvaluator` to analyze afterward. Buffers the whole
/// recording in memory and hands it back as one flat `[Float]` array on
/// `stop()`, rather than doing any real-time analysis while capturing.
@MainActor
public final class AudioRecorder: ObservableObject {
    @Published public private(set) var isRecording = false
    public private(set) var sampleRate: Double = 44100

    private let engine = AVAudioEngine()
    private let buffer = SampleBuffer()

    public init() {}

    /// Briefly starts and immediately stops capture, discarding whatever
    /// it hears. The very first time any recorder in the app adds a
    /// microphone input tap, Core Audio has to reconfigure the shared
    /// hardware device from output-only to input+output — which both
    /// corrupts whatever that first take was capturing and (see
    /// `NotePlaybackEngine`/`MetronomeEngine`) silently stops every other
    /// engine already running. Doing that reconfiguration once, quietly,
    /// before the user ever presses Record, means their actual first take
    /// doesn't land on top of it.
    public func prewarm() {
        guard !isRecording else { return }
        start()
        stop()
    }

    public func start() {
        guard !isRecording else { return }
        buffer.reset()
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        sampleRate = format.sampleRate
        let box = buffer
        // `@Sendable` here isn't decoration — without it, Swift infers this
        // closure inherits AudioRecorder's `@MainActor` isolation (since
        // AVAudioNodeTapBlock isn't itself marked Sendable in the SDK), and
        // generates a runtime isolation check expecting the block to run on
        // the main actor. AVAudioEngine actually invokes tap blocks on its
        // own real-time audio thread, never the main actor, so that check
        // trapped every time — this is what crashed on Record. The closure
        // only touches `box` (an `@unchecked Sendable`), never `self`, so
        // it's genuinely safe to run off the main actor.
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { @Sendable pcmBuffer, _ in
            guard let channelData = pcmBuffer.floatChannelData else { return }
            box.append(UnsafeBufferPointer(start: channelData[0], count: Int(pcmBuffer.frameLength)))
        }
        do {
            try engine.start()
            isRecording = true
        } catch {
            print("AudioRecorder: failed to start audio engine: \(error)")
            input.removeTap(onBus: 0)
        }
    }

    /// A non-destructive look at everything captured so far — unlike
    /// `stop()`, doesn't clear the buffer or stop the engine. Lets a
    /// caller show live pass/fail feedback partway through a take instead
    /// of only once recording finishes.
    public func peek() -> [Float] {
        buffer.snapshot()
    }

    /// Stops capture and returns everything recorded, in order.
    @discardableResult
    public func stop() -> [Float] {
        guard isRecording else { return buffer.snapshot() }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        return buffer.snapshot()
    }
}

/// A plain (non-actor) thread-safe accumulator. The input tap's callback
/// runs on a real-time audio thread, not the main actor, so it can't touch
/// `AudioRecorder`'s own `@MainActor` state directly — this is captured by
/// value instead, safe to call from any isolation context.
private final class SampleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []

    func append(_ newSamples: UnsafeBufferPointer<Float>) {
        lock.lock()
        samples.append(contentsOf: newSamples)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        samples.removeAll()
        lock.unlock()
    }

    func snapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }
}
