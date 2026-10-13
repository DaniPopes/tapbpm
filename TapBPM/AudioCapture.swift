import AVFoundation
import Synchronization

/// Microphone input, resampled into a rolling window for `BeatTracker`.
final class AudioCapture {
    struct Unavailable: Error {}

    let window = AudioWindow(count: BeatTracker.samples)

    private let engine = AVAudioEngine()

    init() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // Measurement mode turns off voice processing; mixing keeps music from other apps playing.
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
        try session.setActive(true)
        #endif
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, let resampler = Resampler(from: format, to: BeatTracker.sampleRate, into: window) else {
            throw Unavailable()
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

    func append(_ samples: UnsafeBufferPointer<Float>, end: TimeInterval) {
        ring.withLock { ring in
            for sample in samples {
                ring.samples[ring.next] = sample
                ring.next = (ring.next + 1) % ring.samples.count
            }
            ring.filled = min(ring.filled + samples.count, ring.samples.count)
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

/// Converts tap buffers to mono. Used only from the audio tap's thread.
nonisolated private final class Resampler: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let output: AVAudioFormat
    private let window: AudioWindow

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
        guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return }
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
