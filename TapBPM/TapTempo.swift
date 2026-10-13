import Foundation

/// Estimates tempo from beat timestamps, tapped or detected, with a least-squares fit of tap
/// time against beat number.
///
/// A fit uses every tap in the window, unlike averaging intervals, where all but the first and
/// last tap cancel out. Missed beats are tolerated, accidental double taps are dropped, and a
/// sudden tempo change or a pause starts a new session.
struct TapTempo {
    struct Tap {
        var time: TimeInterval
        var beat: Int
    }

    /// Seconds per beat and its standard error, which needs at least three taps.
    struct Fit {
        var period: TimeInterval
        var error: TimeInterval? = nil

        var bpm: Double { 60 / period }

        var bpmError: Double? { error.map { 60 * $0 / (period * period) } }
    }

    /// Number of most recent taps used for the fit.
    static let window = 32
    /// Tempos that can be tapped or reached by scaling.
    static let bpmRange = 20.0...600.0
    /// How far, in beats, an interval may deviate from a whole number of beats.
    static let beatTolerance = 0.25

    private(set) var taps: [Tap] = []
    /// Taps in the current session, including those that fell out of the window.
    private(set) var tapCount = 0
    /// Result of the last ended session, shown until the next session has a tempo.
    private(set) var held: Double?
    /// Time of the last counted tap, kept across sessions to phase the beat indicator.
    private(set) var anchor: TimeInterval?

    /// Seconds per beat in the current session.
    var period: TimeInterval? { fit?.period }

    var liveBPM: Double? { fit?.bpm }

    var bpm: Double? { liveBPM ?? held }

    var bpmError: Double? { fit?.bpmError }

    /// Time without a tap after which the next tap starts a new session. Before a tempo is
    /// known, it allows the slowest tempo in `bpmRange`.
    var timeout: TimeInterval { period.map { max(2, 2.5 * $0) } ?? 60 / Self.bpmRange.lowerBound }

    /// Fraction of the timeout left since the last tap, or 0 outside a session.
    func remaining(at now: TimeInterval) -> Double {
        guard let last = taps.last else { return 0 }
        return max(0, 1 - (now - last.time) / timeout)
    }

    func isLive(at now: TimeInterval) -> Bool {
        remaining(at: now) > 0
    }

    /// Position within the current beat at the shown tempo, from 0 on a beat towards 1.
    func beatPhase(at now: TimeInterval) -> Double? {
        Self.beatPhase(at: now, bpm: bpm, anchor: anchor)
    }

    static func beatPhase(at now: TimeInterval, bpm: Double?, anchor: TimeInterval?) -> Double? {
        guard let bpm, let anchor else { return nil }
        return ((now - anchor) * bpm / 60).truncatingRemainder(dividingBy: 1)
    }

    func canScale(by factor: Double) -> Bool {
        Self.canScale(bpm, by: factor)
    }

    static func canScale(_ bpm: Double?, by factor: Double) -> Bool {
        bpm.map { bpmRange.contains($0 * factor) } ?? false
    }

    /// Records a tap and returns whether it was counted.
    @discardableResult
    mutating func tap(at time: TimeInterval) -> Bool {
        guard isLive(at: time), let last = taps.last else {
            endSession()
            append(Tap(time: time, beat: 0))
            return true
        }
        let interval = time - last.time
        guard interval >= 60 / Self.bpmRange.upperBound else { return false }

        var beat = last.beat + 1
        if let period {
            let ratio = interval / period
            if ratio < 0.5 { return false }
            let beats = ratio.rounded()
            if beats <= 2, abs(ratio - beats) <= Self.beatTolerance {
                beat = last.beat + Int(beats)
            } else {
                endSession()
                append(Tap(time: last.time, beat: 0))
                beat = 1
            }
        }
        append(Tap(time: time, beat: beat))
        return true
    }

    /// Ends the session and multiplies the shown tempo, to fix half- or double-time tapping.
    mutating func scale(by factor: Double) {
        guard canScale(by: factor), let bpm else { return }
        endSession()
        held = bpm * factor
    }

    mutating func reset() {
        self = TapTempo()
    }

    private mutating func endSession() {
        if let liveBPM { held = liveBPM }
        taps = []
        tapCount = 0
    }

    private mutating func append(_ tap: Tap) {
        taps.append(tap)
        if taps.count > Self.window { taps.removeFirst() }
        tapCount += 1
        anchor = tap.time
    }

    var fit: Fit? {
        guard taps.count >= 2 else { return nil }
        let n = Double(taps.count)
        let meanBeat = taps.reduce(0) { $0 + Double($1.beat) } / n
        let meanTime = taps.reduce(0) { $0 + $1.time } / n
        var sxx = 0.0
        var sxy = 0.0
        for tap in taps {
            let dx = Double(tap.beat) - meanBeat
            sxx += dx * dx
            sxy += dx * (tap.time - meanTime)
        }
        let slope = sxy / sxx
        guard taps.count >= 3 else { return Fit(period: slope) }
        let sse = taps.reduce(0) {
            let residual = $1.time - meanTime - slope * (Double($1.beat) - meanBeat)
            return $0 + residual * residual
        }
        return Fit(period: slope, error: (sse / (n - 2) / sxx).squareRoot())
    }
}
