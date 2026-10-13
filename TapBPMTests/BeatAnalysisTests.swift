import Foundation
import Testing

@testable import TapBPM

struct BeatAnalysisTests {
    /// A rock beat: kick on 1 and 3, snare on 2 and 4, and hi-hats on every eighth note.
    private func drums(bpm: Double) -> [Float] {
        let count = BeatTracker.samples
        var audio = [Float](repeating: 0, count: count)
        var noise = SystemRandomNumberGenerator()
        func add(at start: Int, length: Int, _ sample: (Double) -> Double) {
            for n in 0..<min(length, count - start) {
                audio[start + n] += Float(sample(Double(n) / BeatTracker.sampleRate))
            }
        }
        let eighth = 30 / bpm
        var index = 0
        while Double(index) * eighth * BeatTracker.sampleRate < Double(count) {
            let start = Int(Double(index) * eighth * BeatTracker.sampleRate)
            add(at: start, length: 2000) { t in 0.15 * Double.random(in: -1...1, using: &noise) * exp(-t * 300) }
            switch index % 8 {
            case 0, 4:
                // Kick: a sine falling from 120 Hz to 50 Hz.
                add(at: start, length: 6000) { t in sin(2 * .pi * (50 * t + 70 / 30 * (1 - exp(-30 * t)))) * exp(-t * 12) }
            case 2, 6:
                add(at: start, length: 5000) { t in
                    0.6 * (Double.random(in: -1...1, using: &noise) + 0.5 * sin(2 * .pi * 200 * t)) * exp(-t * 25)
                }
            default:
                break
            }
            index += 1
        }
        let peak = audio.map(abs).max() ?? 1
        return audio.map { 0.5 * $0 / peak }
    }

    @Test func peaksAreLocalMaximaAboveZero() {
        var logits = [Float](repeating: -5, count: 100)
        logits[10] = 2
        logits[12] = 1
        logits[40] = -1
        logits[60] = 3
        logits[61] = 3
        logits[90] = 1
        #expect(BeatAnalysis.beatFrames(logits, in: 0..<100) == [10, 60.5, 90])
        #expect(BeatAnalysis.beatFrames(logits, in: 20..<80) == [60.5])
    }

    @Test func beatTimesSkipSilenceAndBorders() {
        var logits = [Float](repeating: -5, count: BeatTracker.frames)
        for frame in stride(from: 2, to: BeatTracker.frames, by: 25) { logits[frame] = 4 }
        let end = 1000.0
        let times = BeatAnalysis.beatTimes(logits, filled: BeatTracker.samples / 2, end: end)
        #expect(times.count == 10)
        #expect(times.allSatisfy { $0 > end - 5.1 && $0 < end })
        #expect(abs(times[1] - times[0] - 0.5) < 1e-9)
    }

    @Test func tempoCountsMissedBeats() throws {
        let beats = [10, 10.5, 11, 12, 12.5, 13, 13.5]
        let estimate = try #require(BeatAnalysis.estimate(beats: beats))
        #expect(abs(estimate.fit.bpm - 120) < 1e-9)
    }

    @Test func tempoNeedsFourBeats() {
        #expect(BeatAnalysis.estimate(beats: [1, 1.5, 2]) == nil)
    }

    private func logits(every spacing: Int) -> [Float] {
        (0..<BeatTracker.frames).map { $0 % spacing == 0 ? 4 : -5 }
    }

    @Test func modelsMustAgree() throws {
        let agreeing = [logits(every: 25), logits(every: 25), logits(every: 30)]
        let estimate = try #require(BeatAnalysis.estimate(logits: agreeing, filled: BeatTracker.samples, end: 0))
        #expect(abs(estimate.fit.bpm - 120) < 0.5)
        let disagreeing = [logits(every: 25), logits(every: 30), logits(every: 36)]
        #expect(BeatAnalysis.estimate(logits: disagreeing, filled: BeatTracker.samples, end: 0) == nil)
    }

    @Test func confirmationNeedsAnEarlierAgreeingEstimate() {
        var confirmation = BeatListener.Confirmation()
        let results = [(120.0, 0.0), (120.5, 0.5), (121, 1), (150, 2), (150, 3), (150, 6)].map {
            confirmation.confirm($0.0, at: $0.1)
        }
        #expect(results == [false, false, true, false, true, false])
    }

    @Test func tempoFollowsRecentChange() throws {
        let old = (0..<12).map { 100 + Double($0) * 0.5 }
        let new = (1...12).map { old.last! + Double($0) * 60 / 135 }
        let estimate = try #require(BeatAnalysis.estimate(beats: old + new))
        #expect(abs(estimate.fit.bpm - 135) < 0.5, "detected \(estimate.fit.bpm) BPM")
        #expect(estimate.beats.allSatisfy { $0 > new[0] - 1 })
    }

    @Test(arguments: [90.0, 100, 128, 174])
    func modelFindsTempoOfDrums(bpm: Double) async throws {
        let tracker = try await BeatTracker()
        let logits = try await tracker.beatLogits(drums(bpm: bpm))
        #expect(logits.count == BeatTracker.models && logits.allSatisfy { $0.count == BeatTracker.frames })
        let estimate = try #require(BeatAnalysis.estimate(logits: logits, filled: BeatTracker.samples, end: 0))
        #expect(abs(estimate.fit.bpm - bpm) < 1, "detected \(estimate.fit.bpm) BPM")
    }
}
