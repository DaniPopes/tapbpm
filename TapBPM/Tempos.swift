import Foundation

/// The tap tempo and the music tempo, and which of the two leads the screen.
struct Tempos {
    enum Source {
        case taps
        case music
    }

    var taps = TapTempo()
    let music = BeatListener()

    var canReset: Bool { taps.anchor != nil || music.bpm != nil }

    /// Taps lead while a tap session runs, or when the music has no tempo yet.
    func leader(at now: TimeInterval) -> Source {
        taps.isLive(at: now) || (taps.bpm != nil && music.bpm == nil) ? .taps : .music
    }

    func canScale(by factor: Double, at now: TimeInterval) -> Bool {
        switch leader(at: now) {
        case .taps: taps.canScale(by: factor)
        case .music: music.canScale(by: factor)
        }
    }

    mutating func scale(by factor: Double, at now: TimeInterval) {
        switch leader(at: now) {
        case .taps: taps.scale(by: factor)
        case .music: music.scale(by: factor)
        }
    }

    mutating func reset() {
        music.reset()
        taps.reset()
    }
}
