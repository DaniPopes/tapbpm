import SwiftUI

struct ContentView: View {
    @State private var tempos = Tempos()
    @AppStorage("source") private var source = AudioCapture.Source.preferred
    /// Whether the session ended without a tempo, leaving nothing to animate.
    @State private var timedOut = false

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color(.paper).ignoresSafeArea()
            // On macOS the pad stays below the hidden title bar so the window can still be dragged.
            TapPad { tempos.taps.tap(at: $0) }
            #if os(iOS)
                .ignoresSafeArea()
            #endif
            TimelineView(.animation(minimumInterval: 1 / 60, paused: !animating)) { _ in
                Readout(reading: reading(at: ProcessInfo.processInfo.systemUptime))
            }
            .allowsHitTesting(false)
            VStack {
                Spacer()
                controls
            }
        }
        .task(id: tempos.taps.anchor) {
            timedOut = false
            guard (try? await Task.sleep(for: .seconds(tempos.taps.timeout))) != nil else { return }
            timedOut = true
        }
        .task(id: scenePhase == .background ? nil : source) {
            if scenePhase != .background { await tempos.music.listen(to: source) }
        }
    }

    private var animating: Bool {
        tempos.music.fresh || tempos.taps.bpm != nil || (tempos.taps.anchor != nil && !timedOut)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            scaleButton(title: "½×", factor: 0.5)
            ControlButton(title: "Reset", primary: true) { tempos.reset() }
                .keyboardShortcut(.cancelAction)
                .disabled(!tempos.canReset)
            scaleButton(title: "2×", factor: 2)
            if AudioCapture.Source.allCases.count > 1 {
                ControlButton(title: source.title) { source = source.next }
                    .help("Choose what to listen to")
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    private func scaleButton(title: String, factor: Double) -> some View {
        ControlButton(title: title) { tempos.scale(by: factor, at: ProcessInfo.processInfo.systemUptime) }
            .disabled(!tempos.canScale(by: factor, at: ProcessInfo.processInfo.systemUptime))
    }

    private func reading(at now: TimeInterval) -> Reading {
        switch tempos.leader(at: now) {
        case .taps:
            var reading = tempos.taps.reading(at: now)
            reading.other = tempos.music.bpm.map { .tempo("MUSIC", $0) } ?? .hint(tempos.music.status)
            return reading
        case .music:
            var reading = tempos.music.reading(at: now)
            reading.other = tempos.taps.bpm.map { .tempo("TAPS", $0) } ?? .hint(TapPad.prompt)
            return reading
        }
    }
}

/// What the screen shows at one instant, led by taps or by the music.
private struct Reading {
    var status: String
    var bpm: Double?
    var error: Double?
    var fresh: Bool
    /// Fill of the ring around the number, from 0 to 1.
    var ring: Double
    /// Time since the last tap, which drives the background flash.
    var sinceBeat: TimeInterval? = nil
    /// Position within the beat, which drives the beat dot.
    var phase: Double?
    /// The tempo from the other source, or a hint when it has none.
    var other = Other.hint("")

    enum Other: Equatable {
        case tempo(String, Double)
        case hint(String)
    }

    static func format(_ bpm: Double) -> String {
        bpm.formatted(.number.precision(.fractionLength(1)))
    }
}

private extension AudioCapture.Source {
    var title: String {
        switch self {
        case .microphone: "Mic"
        #if os(macOS)
        case .system: "System"
        #endif
        }
    }

    var quietStatus: String {
        switch self {
        case .microphone: "NO MUSIC"
        #if os(macOS)
        case .system: "NOTHING PLAYING"
        #endif
        }
    }

    var next: Self {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

private extension TapTempo {
    func reading(at now: TimeInterval) -> Reading {
        let live = isLive(at: now)
        let status = if !live {
            "TAP TO MEASURE AGAIN"
        } else {
            tapCount == 1 ? "KEEP TAPPING" : "\(tapCount) TAPS"
        }
        return Reading(
            status: status,
            bpm: bpm,
            error: bpmError,
            fresh: live && liveBPM != nil,
            ring: remaining(at: now),
            sinceBeat: anchor.map { now - $0 },
            phase: beatPhase(at: now)
        )
    }
}

private extension BeatListener {
    var status: String {
        switch state {
        case .off: "PAUSED"
        case .loading: "LOADING MODEL…"
        case .listening where quiet: source.quietStatus
        case .listening: bpm == nil ? "LISTENING…" : "MUSIC · \(beatCount) BEATS"
        case .denied: "MICROPHONE ACCESS DENIED"
        case .unavailable: "\(source.title.uppercased()) UNAVAILABLE"
        }
    }

    func reading(at now: TimeInterval) -> Reading {
        Reading(
            status: status,
            bpm: bpm,
            error: bpmError,
            fresh: fresh,
            ring: isLive(at: now) ? 1 : 0,
            phase: beatPhase(at: now)
        )
    }
}

/// Per-frame layer: beat flash, ring and beat dot.
private struct Readout: View {
    let reading: Reading

    var body: some View {
        ZStack {
            Color.primary
                .opacity(0.06 * max(0, 1 - (reading.sinceBeat ?? .infinity) / 0.15))
                .ignoresSafeArea()
            VStack(spacing: 36) {
                Caption(text: reading.status)
                ZStack {
                    Circle()
                        .stroke(.primary.opacity(0.08), lineWidth: 1.5)
                    Circle()
                        .trim(from: 0, to: reading.ring)
                        .stroke(.primary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    BPMLabel(bpm: reading.bpm, error: reading.error, fresh: reading.fresh)
                }
                .frame(width: 300, height: 300)
                Circle()
                    .fill(.primary)
                    .frame(width: 10, height: 10)
                    .opacity(reading.phase.map { exp(-5 * $0) } ?? 0)
                OtherCaption(other: reading.other)
            }
        }
    }
}

private struct Caption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .tracking(0.66)
            .foregroundStyle(.primary.opacity(0.4))
    }
}

/// Takes a plain value so SwiftUI skips formatting on frames where it did not change.
private struct OtherCaption: View {
    let other: Reading.Other

    var body: some View {
        switch other {
        case .tempo(let source, let bpm): Caption(text: "\(source) \(Reading.format(bpm))")
        case .hint(let hint): Caption(text: hint)
        }
    }
}

/// Takes plain values so SwiftUI skips formatting on frames where they did not change.
private struct BPMLabel: View {
    let bpm: Double?
    let error: Double?
    let fresh: Bool

    var body: some View {
        VStack(spacing: 2) {
            Text(bpm.map { "\(Int($0.rounded()))" } ?? "–")
                .font(.system(size: 128, weight: .medium))
                .tracking(-6.4)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(.primary.opacity(bpm == nil ? 0.25 : fresh ? 1 : 0.45))
            Text(detail)
                .font(.system(size: 13, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.primary.opacity(0.56))
        }
        .padding(.horizontal, 24)
    }

    private var detail: String {
        guard let bpm else { return "BPM" }
        let precise = "\(Reading.format(bpm)) BPM"
        guard let error else { return precise }
        return "\(precise)  ±\(Reading.format(error))"
    }
}

/// A pill button: black for the primary action, translucent gray otherwise.
private struct ControlButton: View {
    let title: String
    var primary = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .foregroundStyle(primary ? Color(.paper) : .primary)
                .background(primary ? AnyShapeStyle(.primary) : AnyShapeStyle(Color(white: 0.76, opacity: 0.24)), in: Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.35)
    }
}

#Preview {
    ContentView()
}
