import SwiftUI

struct ContentView: View {
    @State private var tempo = TapTempo()
    /// Whether the session ended without a tempo, leaving nothing to animate.
    @State private var timedOut = false

    var body: some View {
        ZStack {
            Color(.ink).ignoresSafeArea()
            // On macOS the pad stays below the hidden title bar so the window can still be dragged.
            TapPad { tempo.tap(at: $0) }
            #if os(iOS)
                .ignoresSafeArea()
            #endif
            TimelineView(.animation(minimumInterval: 1 / 60, paused: tempo.bpm == nil && (tempo.anchor == nil || timedOut))) { _ in
                Readout(tempo: tempo, now: ProcessInfo.processInfo.systemUptime)
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
    }

    private var controls: some View {
        HStack(spacing: 12) {
            ControlButton(title: "½×") { tempo.scale(by: 0.5) }
                .disabled(!tempo.canScale(by: 0.5))
            ControlButton(title: "Reset") { tempo.reset() }
                .keyboardShortcut(.cancelAction)
                .disabled(tempo.anchor == nil)
            ControlButton(title: "2×") { tempo.scale(by: 2) }
                .disabled(!tempo.canScale(by: 2))
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }
}

/// Per-frame layer: tap flash, timeout ring and beat dot.
private struct Readout: View {
    let tempo: TapTempo
    let now: TimeInterval

    var body: some View {
        let live = tempo.isLive(at: now)
        let sinceTap = tempo.anchor.map { now - $0 } ?? .infinity

        ZStack {
            Color.accentColor
                .opacity(0.2 * max(0, 1 - sinceTap / 0.15))
                .ignoresSafeArea()
            VStack(spacing: 36) {
                Text(status(live: live))
                    .font(.system(.footnote, design: .rounded).weight(.semibold))
                    .tracking(2)
                    .foregroundStyle(.white.opacity(0.5))
                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.08), lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: tempo.remaining(at: now))
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    BPMLabel(bpm: tempo.bpm, error: tempo.bpmError, fresh: live && tempo.liveBPM != nil)
                }
                .frame(width: 300, height: 300)
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 18, height: 18)
                    .opacity(tempo.beatPhase(at: now).map { exp(-5 * $0) } ?? 0)
            }
        }
    }

    private func status(live: Bool) -> String {
        if tempo.anchor == nil { return TapPad.prompt }
        if !live { return "TAP TO MEASURE AGAIN" }
        return tempo.tapCount == 1 ? "KEEP TAPPING" : "\(tempo.tapCount) TAPS"
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
        let precise = "\(bpm.formatted(.number.precision(.fractionLength(1)))) BPM"
        guard let error else { return precise }
        return "\(precise)  ±\(error.formatted(.number.precision(.fractionLength(1))))"
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
