import SwiftUI

/// Full-window tap surface that reports the hardware timestamp of each touch-down, click or
/// key press.
///
/// SwiftUI tap gestures fire on release and lose the event timestamp; a platform view sees every
/// finger or key as it lands, so two-finger drumming works and timing is exact.
struct TapPad {
    /// Called for each tap; returns whether the tap was counted.
    var onTap: (TimeInterval) -> Bool
}

#if os(iOS)
import UIKit

extension TapPad: UIViewRepresentable {
    static let prompt = "TAP ANYWHERE TO THE BEAT"

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
#else
import AppKit

extension TapPad: NSViewRepresentable {
    static let prompt = "CLICK OR PRESS ANY KEY TO THE BEAT"

    func makeNSView(context: Context) -> TapPadView {
        TapPadView()
    }

    func updateNSView(_ view: TapPadView, context: Context) {
        view.onTap = onTap
    }
}

final class TapPadView: NSView {
    var onTap: ((TimeInterval) -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        _ = onTap?(event.timestamp)
    }

    override func keyDown(with event: NSEvent) {
        guard !event.isARepeat else { return }
        _ = onTap?(event.timestamp)
    }
}
#endif
