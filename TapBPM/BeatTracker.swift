import CoreML
import Foundation

/// Runs the bundled Beat This! small models on 10 s windows of mono 22050 Hz audio.
actor BeatTracker {
    /// These match `scripts/convert_beat_this.py`.
    static let models = 3
    static let sampleRate = 22050.0
    static let hop = 441
    static let fftSize = 1024
    static let frames = 500
    static let samples = (frames - 1) * hop + fftSize

    struct ModelMissing: Error {}

    private let model: MLModel
    /// Reused for every window to avoid allocating 860 KB per prediction.
    private let input: MLMultiArray
    private let features: MLFeatureProvider

    init() async throws {
        guard let url = Bundle.main.url(forResource: "BeatThis", withExtension: "mlmodelc") else {
            throw ModelMissing()
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        model = try await MLModel.load(contentsOf: url, configuration: configuration)
        input = try MLMultiArray(shape: [1, NSNumber(value: Self.samples)], dataType: .float32)
        features = try MLDictionaryFeatureProvider(dictionary: ["audio": input])
    }

    /// Beat logits of each model for each frame of `samples`, which must hold `Self.samples`
    /// values.
    func beatLogits(_ samples: [Float]) throws -> [[Float]] {
        input.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
            _ = buffer.update(from: samples)
        }
        let output = try model.prediction(from: features)
        guard let beat = output.featureValue(for: "beat")?.multiArrayValue else { return [] }
        let shaped = MLShapedArray<Float>(converting: beat)
        return (0..<shaped.shape[1]).map { shaped[0, $0].scalars }
    }
}

/// Turns Beat This! logits into beat times and a tempo.
enum BeatAnalysis {
    /// A tempo and the beats it was fitted to.
    struct Estimate {
        var fit: TapTempo.Fit
        var beats: [TimeInterval]
    }

    /// Frames at each window edge, which the model was not trained to predict.
    static let border = 6
    /// Seconds of the newest beats that override the whole window when their tempo differs.
    static let recent = 5.0

    /// Beats as fractional frames: logits above 0 that are the maximum within ±3 frames
    /// (±60 ms), with runs of adjacent peaks merged into their mean.
    static func beatFrames(_ logits: [Float], in range: Range<Int>) -> [Double] {
        var runs: [[Int]] = []
        for i in range where logits[i] > 0 {
            guard logits[max(0, i - 3)...min(logits.count - 1, i + 3)].allSatisfy({ $0 <= logits[i] }) else { continue }
            if let last = runs.last?.last, i - last == 1 {
                runs[runs.count - 1].append(i)
            } else {
                runs.append([i])
            }
        }
        return runs.map { Double($0.reduce(0, +)) / Double($0.count) }
    }

    /// Uptimes of the beats in a window ending at `end`, of which the last `filled` samples hold
    /// audio and the rest is silence.
    static func beatTimes(_ logits: [Float], filled: Int, end: TimeInterval) -> [TimeInterval] {
        let firstFull = (BeatTracker.samples - filled + BeatTracker.hop - 1) / BeatTracker.hop
        let lower = max(firstFull, border)
        return beatFrames(logits, in: lower..<max(lower, logits.count - border)).map {
            let centre = $0 * Double(BeatTracker.hop) + Double(BeatTracker.fftSize / 2)
            return end - (Double(BeatTracker.samples) - centre) / BeatTracker.sampleRate
        }
    }

    /// The median of the models' tempos, which is more accurate than any one model
    /// (https://github.com/CPJKU/beat_this/issues/13).
    static func estimate(logits: [[Float]], filled: Int, end: TimeInterval) -> Estimate? {
        let estimates = logits
            .compactMap { estimate(beats: beatTimes($0, filled: filled, end: end)) }
            .sorted { $0.fit.bpm < $1.fit.bpm }
        return estimates.isEmpty ? nil : estimates[estimates.count / 2]
    }

    /// Tempo of the beats, or of the last `recent` seconds of them when the two differ by more
    /// than 3%, so a new song replaces the old tempo before the old one leaves the window. This
    /// catches changes too small for `TapTempo` to start a new session.
    static func estimate(beats: [TimeInterval]) -> Estimate? {
        guard let last = beats.last else { return nil }
        let latest = fit(beats.filter { $0 > last - recent })
        guard let all = fit(beats) else { return latest }
        if let latest, abs(latest.fit.bpm / all.fit.bpm - 1) > 0.03 { return latest }
        return all
    }

    /// Reads detected beats like taps, so missed and double beats follow the same rules.
    private static func fit(_ beats: [TimeInterval]) -> Estimate? {
        var tempo = TapTempo()
        for beat in beats { tempo.tap(at: beat) }
        guard tempo.tapCount >= 4, let fit = tempo.fit else { return nil }
        return Estimate(fit: fit, beats: beats)
    }
}
