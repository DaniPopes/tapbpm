import Testing

@testable import TapBPM

struct TapTempoTests {
    private func tapped(_ times: [Double]) -> TapTempo {
        var tempo = TapTempo()
        for time in times { tempo.tap(at: time) }
        return tempo
    }

    private func expectBPM(
        _ tempo: TapTempo,
        _ expected: Double,
        tolerance: Double = 1e-9,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let bpm = try #require(tempo.bpm, sourceLocation: sourceLocation)
        #expect(abs(bpm - expected) < tolerance, sourceLocation: sourceLocation)
    }

    @Test func steadyTaps() throws {
        let tempo = tapped((0..<8).map { 100 + Double($0) * 0.5 })
        try expectBPM(tempo, 120)
        #expect(tempo.tapCount == 8)
        #expect(try #require(tempo.bpmError) < 1e-6)
    }

    @Test func noTempoFromOneTap() {
        let tempo = tapped([100])
        #expect(tempo.bpm == nil)
        #expect(tempo.isLive(at: 102))
        #expect(!tempo.isLive(at: 103.1))
    }

    @Test func jitterAveragesOut() throws {
        let jitter = [0.012, -0.009, 0.004, -0.015, 0.01, -0.003, 0.008, -0.011, 0.002, -0.006, 0.013, -0.005]
        let tempo = tapped(jitter.enumerated().map { 100 + Double($0.offset) * 0.5 + $0.element })
        try expectBPM(tempo, 120, tolerance: 0.5)
    }

    @Test func missedBeatCountsAsTwo() throws {
        let tempo = tapped([100, 100.5, 101, 102, 102.5])
        try expectBPM(tempo, 120)
        #expect(tempo.taps.map(\.beat) == [0, 1, 2, 4, 5])
    }

    @Test func doubleTapIgnored() throws {
        var tempo = tapped([100, 100.5, 101])
        let counted = tempo.tap(at: 101.1)
        #expect(!counted)
        tempo.tap(at: 101.5)
        try expectBPM(tempo, 120)
        #expect(tempo.tapCount == 4)
    }

    @Test func simultaneousTouchesCountOnce() {
        var tempo = tapped([100])
        let counted = tempo.tap(at: 100)
        #expect(!counted)
        #expect(tempo.tapCount == 1)
    }

    @Test func tempoJumpRestarts() throws {
        let tempo = tapped([100, 100.5, 101, 101.5, 102.1667])
        try expectBPM(tempo, 90, tolerance: 0.1)
        #expect(tempo.tapCount == 2)
    }

    @Test func timeoutStartsNewSessionAndHoldsResult() throws {
        var tempo = tapped([100, 100.5, 101, 101.5])
        #expect(!tempo.isLive(at: 103.6))
        tempo.tap(at: 110)
        #expect(tempo.tapCount == 1)
        #expect(tempo.liveBPM == nil)
        try expectBPM(tempo, 120)
        tempo.tap(at: 110.6)
        try expectBPM(tempo, 100)
    }

    @Test func slowTempo() throws {
        let tempo = tapped([100, 102.4, 104.8, 107.2])
        try expectBPM(tempo, 25)
    }

    @Test func remainingAndBeatPhase() throws {
        let tempo = tapped([100, 100.5])
        #expect(abs(tempo.remaining(at: 101.5) - 0.5) < 1e-9)
        #expect(tempo.remaining(at: 103) == 0)
        #expect(abs(try #require(tempo.beatPhase(at: 100.75)) - 0.5) < 1e-9)
    }

    @Test func scaleEndsSession() throws {
        var tempo = tapped([100, 100.5, 101])
        tempo.scale(by: 0.5)
        try expectBPM(tempo, 60)
        #expect(tempo.taps.isEmpty)
        tempo.scale(by: 2)
        tempo.scale(by: 2)
        try expectBPM(tempo, 240)
        #expect(!tempo.canScale(by: 4))
        tempo.scale(by: 4)
        try expectBPM(tempo, 240)
    }

    @Test func reset() {
        var tempo = tapped([100, 100.5, 101])
        tempo.reset()
        #expect(tempo.bpm == nil)
        #expect(tempo.anchor == nil)
        #expect(tempo.tapCount == 0)
    }
}
