import SwiftUI

struct ContentView: View {
    @State private var tempo = TapTempo()
    @State private var listener = BeatListener()
    /// Whether the session ended without a tempo, leaving nothing to animate.
    @State private var timedOut = false

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color(.ink).ignoresSafeArea()
            // On macOS the pad stays below the hidden title bar so the window can still be dragged.
            TapPad { tempo.tap(at: $0) }
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
        .task(id: tempo.anchor) {
            timedOut = false
            guard (try? await Task.sleep(for: .seconds(tempo.timeout))) != nil else { return }
            timedOut = true
        }
        .task(id: scenePhase == .background) {
            if scenePhase != .background { await listener.listen() }
        }
    }

    private var animating: Bool {
        listener.bpm != nil || tempo.bpm != nil || (tempo.anchor != nil && !timedOut)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            ControlButton(title: "½×") { scale(by: 0.5) }
                .disabled(!canScale(by: 0.5))
            ControlButton(title: "Reset") {
                listener.reset()
                tempo.reset()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(tempo.anchor == nil && listener.bpm == nil)
            ControlButton(title: "2×") { scale(by: 2) }
                .disabled(!canScale(by: 2))
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    /// Taps lead while a tap session runs, or when the music has no tempo yet.
    private func tapsLead(at now: TimeInterval) -> Bool {
        tempo.isLive(at: now) || (tempo.bpm != nil && listener.bpm == nil)
    }

    private func reading(at now: TimeInterval) -> Reading {
        if tapsLead(at: now) {
            var reading = tempo.reading(at: now)
            reading.other = listener.bpm.map { "MUSIC \(Reading.format($0))" } ?? listener.status
            return reading
        }
        var reading = listener.reading(at: now)
        reading.other = tempo.bpm.map { "TAPS \(Reading.format($0))" } ?? TapPad.prompt
        return reading
    }

    private func canScale(by factor: Double) -> Bool {
        tapsLead(at: ProcessInfo.processInfo.systemUptime) ? tempo.canScale(by: factor) : listener.canScale(by: factor)
    }

    private func scale(by factor: Double) {
        if tapsLead(at: ProcessInfo.processInfo.systemUptime) { tempo.scale(by: factor) } else { listener.scale(by: factor) }
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
    /// Time since the last tap or beat, which drives the background flash.
    var sinceBeat: TimeInterval?
    /// Position within the beat, which drives the beat dot.
    var phase: Double?
    /// The tempo from the other source, or a hint.
    var other = ""

    static func format(_ bpm: Double) -> String {
        bpm.formatted(.number.precision(.fractionLength(1)))
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
        case .listening: bpm == nil ? "LISTENING…" : "MUSIC · \(beatCount) BEATS"
        case .denied: "MICROPHONE ACCESS DENIED"
        case .unavailable: "MICROPHONE UNAVAILABLE"
        }
    }

    func reading(at now: TimeInterval) -> Reading {
        Reading(
            status: status,
            bpm: bpm,
            error: bpmError,
            fresh: fresh,
            ring: state == .listening && bpm != nil ? 1 : 0,
            sinceBeat: sinceBeat(at: now),
            phase: beatPhase(at: now)
        )
    }
}

/// Per-frame layer: beat flash, ring and beat dot.
private struct Readout: View {
    let reading: Reading

    var body: some View {
        ZStack {
            Color.accentColor
                .opacity(0.2 * max(0, 1 - (reading.sinceBeat ?? .infinity) / 0.15))
                .ignoresSafeArea()
            VStack(spacing: 36) {
                Caption(text: reading.status)
                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.08), lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: reading.ring)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    BPMLabel(bpm: reading.bpm, error: reading.error, fresh: reading.fresh)
                }
                .frame(width: 300, height: 300)
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 18, height: 18)
                    .opacity(reading.phase.map { exp(-5 * $0) } ?? 0)
                Caption(text: reading.other)
            }
        }
    }
}

private struct Caption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(.footnote, design: .rounded).weight(.semibold))
            .tracking(2)
            .foregroundStyle(.white.opacity(0.5))
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
                .font(.system(size: 120, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(.white.opacity(bpm == nil ? 0.25 : fresh ? 1 : 0.45))
            Text(detail)
                .font(.system(.title3, design: .rounded).weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.5))
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

private struct ControlButton: View {
    let title: String
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(.headline, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(.white.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(isEnabled ? 0.85 : 0.3))
    }
}

#Preview {
    ContentView()
}
