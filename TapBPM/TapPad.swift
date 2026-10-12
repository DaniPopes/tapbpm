import SwiftUI
import UIKit

/// Full-screen tap surface that reports touch-down timestamps.
///
/// SwiftUI tap gestures fire on touch-up and lose the hardware timestamp; a UIView sees every
/// finger as it lands, so two-finger drumming works and timing is exact.
struct TapPad: UIViewRepresentable {
    /// Called for each touch-down; returns whether the tap was counted.
    var onTap: (TimeInterval) -> Bool

    func makeUIView(context: Context) -> TapPadView {
        TapPadView()
    }

    func updateUIView(_ view: TapPadView, context: Context) {
        view.onTap = onTap
    }
}

final class TapPadView: UIView {
    var onTap: ((TimeInterval) -> Bool)?

    private let haptics = UIImpactFeedbackGenerator(style: .rigid)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        haptics.prepare()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        var counted = false
        for touch in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
            if onTap?(touch.timestamp) == true { counted = true }
        }
        guard counted else { return }
        haptics.impactOccurred(intensity: 0.7)
        haptics.prepare()
    }
}
