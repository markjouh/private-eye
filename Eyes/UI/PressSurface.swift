import SwiftUI
import UIKit

/// A transparent full-screen touch surface that reports finger down and finger up.
///
/// Uses raw UIKit touches rather than a SwiftUI gesture: a gesture that the system cancels (for
/// example near the bottom edge, where the home swipe lives) never reports its end, which left the
/// button stuck. Touch cancellation is reported here as a normal release.
///
/// Deliberately not an accessibility element. As a direct-touch area covering the screen it took
/// every touch away from VoiceOver, so nothing else on screen could be explored, and the only name
/// it gave Voice Control was a sentence of instructions. The talk button in `ContentView` is what
/// assistive technology acts on; a VoiceOver double-tap-and-hold still arrives here as a press.
struct PressSurface: UIViewRepresentable {
    let onDown: () -> Void
    let onUp: () -> Void

    func makeUIView(context: Context) -> TouchView {
        let view = TouchView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = false
        return view
    }

    func updateUIView(_ view: TouchView, context: Context) {
        view.onDown = onDown
        view.onUp = onUp
    }

    final class TouchView: UIView {
        var onDown: (() -> Void)?
        var onUp: (() -> Void)?
        private var tracking: UITouch?

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard tracking == nil, let touch = touches.first else { return }
            tracking = touch
            onDown?()
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { release(touches) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { release(touches) }

        private func release(_ touches: Set<UITouch>) {
            guard let tracking, touches.contains(tracking) else { return }
            self.tracking = nil
            onUp?()
        }
    }
}
