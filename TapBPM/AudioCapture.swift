import AVFoundation
import Accelerate
import Synchronization

/// Audio input, resampled into a rolling window for `BeatTracker`.
final class AudioCapture {
    enum Source: String, CaseIterable {
        case microphone
        #if os(macOS)
        /// Everything the Mac plays, which iOS does not allow apps to record.
        case system
        #endif

        static var preferred: Source { allCases.last ?? .microphone }
    }

    struct Denied: Error {}

    struct Unavailable: Error {}

    let window = AudioWindow(count: BeatTracker.samples)

    private let input: any AudioInput

    init(_ source: Source) async throws {
        switch source {
        case .microphone:
            guard await AVAudioApplication.requestRecordPermission() else { throw Denied() }
            input = try Microphone(into: window)
        #if os(macOS)
        case .system:
            input = try SystemAudio(into: window)
        #endif
        }
    }

    func stop() {
        input.stop()
    }
}

protocol AudioInput {
    func stop()
}

/// The default input device, through `AVAudioEngine`.
private final class Microphone: AudioInput {
    private let engine = AVAudioEngine()

    init(into window: AudioWindow) throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // Measurement mode turns off voice processing; mixing keeps music from other apps playing.
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
        try session.setActive(true)
        #endif
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, let resampler = Resampler(from: format, to: BeatTracker.sampleRate, into: window) else {
            throw AudioCapture.Unavailable()
        }
        Self.installTap(on: input, format: format, resampler: resampler)
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// Nonisolated so the tap block, which runs on an audio thread, is not main-actor isolated.
    nonisolated private static func installTap(on input: AVAudioInputNode, format: AVAudioFormat, resampler: Resampler) {
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
            resampler.append(buffer, at: time)
        }
    }
}

/// The latest `count` samples, oldest first, shared between the audio thread and the main actor.
nonisolated final class AudioWindow: Sendable {
    struct Snapshot {
        var samples: [Float]
        /// Number of trailing samples that hold audio; the rest is silence.
        var filled: Int
        /// Uptime just after the last sample.
        var end: TimeInterval
    }

    private struct Ring {
        var samples: [Float]
        var next = 0
        var filled = 0
        var end: TimeInterval = 0
    }

    private let ring: Mutex<Ring>

    init(count: Int) {
        ring = Mutex(Ring(samples: [Float](repeating: 0, count: count)))
    }

    var filled: Int { ring.withLock { $0.filled } }

    /// Root mean square of the newest `count` samples.
    func level(ofLast count: Int) -> Float {
        ring.withLock { ring in
            let count = min(count, ring.samples.count)
            let head = min(count, ring.next)
            let sum = vDSP.sumOfSquares(ring.samples[(ring.next - head)..<ring.next])
                + vDSP.sumOfSquares(ring.samples[(ring.samples.count - count + head)...])
            return (sum / Float(count)).squareRoot()
        }
    }

    func append(_ samples: UnsafeBufferPointer<Float>, end: TimeInterval) {
        ring.withLock { ring in
            let count = ring.samples.count
            let newest = UnsafeBufferPointer(rebasing: samples.suffix(count))
            let head = min(newest.count, count - ring.next)
            ring.samples.replaceSubrange(ring.next..<ring.next + head, with: newest[..<head])
            ring.samples.replaceSubrange(..<(newest.count - head), with: newest[head...])
            ring.next = (ring.next + newest.count) % count
            ring.filled = min(ring.filled + newest.count, count)
            ring.end = end
        }
    }

    func snapshot() -> Snapshot {
        ring.withLock { ring in
            var samples = [Float]()
            samples.reserveCapacity(ring.samples.count)
            samples += ring.samples[ring.next...]
            samples += ring.samples[..<ring.next]
            return Snapshot(samples: samples, filled: ring.filled, end: ring.end)
        }
    }
}

/// Converts tap buffers to mono. Used only from one audio thread or queue at a time.
nonisolated final class Resampler: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let output: AVAudioFormat
    private let window: AudioWindow
    /// Reused across callbacks; replaced only when a larger one is needed.
    private var converted: AVAudioPCMBuffer?

    init?(from input: AVAudioFormat, to sampleRate: Double, into window: AudioWindow) {
        guard let output = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let converter = AVAudioConverter(from: input, to: output)
        else { return nil }
        self.converter = converter
        self.output = output
        self.window = window
    }

    func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((duration * output.sampleRate).rounded(.up)) + 32
        if (self.converted?.frameCapacity ?? 0) < capacity {
            self.converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity)
        }
        guard let converted = self.converted else { return }
        var consumed = false
        converter.convert(to: converted, error: nil) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard let channel = converted.floatChannelData?[0] else { return }
        let end = time.isHostTimeValid
            ? AVAudioTime.seconds(forHostTime: time.hostTime) + duration
            : ProcessInfo.processInfo.systemUptime
        window.append(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)), end: end)
    }
}
