import Foundation
import Observation

/// Streams the tempo of music heard by the microphone, re-estimated twice a second from the
/// last 10 s of audio. The estimate outlives `listen()`, so it stays on screen while the app is
/// in the background.
@Observable
final class BeatListener {
    enum State {
        case off
        case loading
        case listening
        case denied
        case unavailable
    }

    /// Seconds of audio needed before the first estimate.
    static let warmUp = 3.0
    /// Seconds between estimates.
    static let interval = 0.5
    /// Level of the last second below which the model is skipped, about -54 dBFS.
    static let silence: Float = 0.002

    private(set) var state = State.off
    private(set) var source = AudioCapture.Source.microphone
    /// Whether the latest window had a beat.
    private(set) var fresh = false
    /// Whether the last second was too quiet to hold music.
    private(set) var quiet = false
    private(set) var beatCount = 0
    /// Uptime of the latest detected beat.
    private(set) var lastBeat: TimeInterval?

    private var detected: TapTempo.Fit?
    /// Factor from ½× and 2×, to fix half- or double-time detection.
    private var multiplier = 1.0
    private var tracker: BeatTracker?
    private var confirmation = Confirmation()

    var bpm: Double? { detected.map { $0.bpm * multiplier } }

    var bpmError: Double? { detected?.bpmError.map { $0 * multiplier } }

    /// Whether beats are still arriving. Detected beats lag by up to a beat plus the half second
    /// between estimates, so this allows longer than `TapTempo.timeout` does for taps.
    func isLive(at now: TimeInterval) -> Bool {
        guard fresh, let bpm, let lastBeat else { return false }
        return now - lastBeat < max(2.5, 120 / bpm)
    }

    /// Position within the beat while beats are arriving, so the pulse stops with the music.
    func beatPhase(at now: TimeInterval) -> Double? {
        isLive(at: now) ? TapTempo.beatPhase(at: now, bpm: bpm, anchor: lastBeat) : nil
    }

    func canScale(by factor: Double) -> Bool {
        TapTempo.canScale(bpm, by: factor)
    }

    func scale(by factor: Double) {
        if canScale(by: factor) { multiplier *= factor }
    }

    /// Forgets the estimate and keeps listening.
    func reset() {
        fresh = false
        quiet = false
        beatCount = 0
        lastBeat = nil
        detected = nil
        multiplier = 1
        confirmation = Confirmation()
    }

    /// Listens until the calling task is cancelled.
    func listen(to source: AudioCapture.Source) async {
        self.source = source
        state = .loading
        var capture: AudioCapture?
        defer {
            capture?.stop()
            fresh = false
            if state == .loading || state == .listening { state = .off }
        }
        do {
            let tracker = try await loadTracker()
            let audio = try await AudioCapture(source)
            capture = audio
            state = .listening
            while true {
                try await Task.sleep(for: .seconds(Self.interval))
                guard Double(audio.window.filled) >= Self.warmUp * BeatTracker.sampleRate else { continue }
                quiet = audio.window.level(ofLast: Int(BeatTracker.sampleRate)) < Self.silence
                guard !quiet else {
                    fresh = false
                    continue
                }
                let window = audio.window.snapshot()
                let logits = try await tracker.beatLogits(window.samples)
                update(with: BeatAnalysis.estimate(logits: logits, filled: window.filled, end: window.end), at: window.end)
            }
        } catch is CancellationError {
        } catch is AudioCapture.Denied {
            state = .denied
        } catch {
            state = .unavailable
        }
    }

    private func loadTracker() async throws -> BeatTracker {
        if let tracker { return tracker }
        let tracker = try await BeatTracker()
        self.tracker = tracker
        return tracker
    }

    private func update(with estimate: BeatAnalysis.Estimate?, at time: TimeInterval) {
        guard let estimate,
              TapTempo.bpmRange.contains(estimate.fit.bpm),
              confirmation.confirm(estimate.fit.bpm, at: time)
        else {
            fresh = false
            return
        }
        detected = estimate.fit
        fresh = true
        beatCount = estimate.beats.count
        lastBeat = estimate.beats.last
    }
}

extension BeatListener {
    /// Accepts a tempo only when an estimate two to four intervals earlier agrees with it, which
    /// rejects the chance agreements left on speech and noise.
    struct Confirmation {
        private var recent: [(time: TimeInterval, bpm: Double)] = []

        mutating func confirm(_ bpm: Double, at time: TimeInterval) -> Bool {
            let slack = BeatListener.interval / 5
            recent.removeAll { time - $0.time > 4 * BeatListener.interval + slack }
            let confirmed = recent.contains {
                time - $0.time >= 2 * BeatListener.interval - slack
                    && BeatAnalysis.agree(bpm, $0.bpm, within: BeatAnalysis.tempoChange)
            }
            recent.append((time, bpm))
            return confirmed
        }
    }
}
