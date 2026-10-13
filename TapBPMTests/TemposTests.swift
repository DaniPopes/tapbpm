import Testing

@testable import TapBPM

struct TemposTests {
    @Test func musicLeadsWithoutTaps() {
        let tempos = Tempos()
        #expect(tempos.leader(at: 100) == .music)
        #expect(!tempos.canScale(by: 2, at: 100))
        #expect(!tempos.canReset)
    }

    @Test func tapsLeadWhileTappingOrWithoutMusic() {
        var tempos = Tempos()
        tempos.taps.tap(at: 100)
        #expect(tempos.leader(at: 101) == .taps)
        #expect(tempos.canReset)
        tempos.taps.tap(at: 100.5)
        tempos.scale(by: 2, at: 101)
        #expect(tempos.taps.bpm == 240)
        // Without a music tempo, the held tap result keeps the lead.
        #expect(tempos.leader(at: 200) == .taps)
        tempos.reset()
        #expect(tempos.leader(at: 200) == .music)
    }
}
