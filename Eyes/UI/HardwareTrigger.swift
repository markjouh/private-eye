import AVKit
import SwiftUI

/// Lets the phone's hardware capture buttons do what a finger on the screen does: hold and speak to
/// ask, click for a quick description.
///
/// While the app is in front with the camera running, the system sends presses of the Camera Control
/// and of both volume buttons (and an AirPods stem click) here instead of acting on them itself. That
/// is all or nothing, so the modifier is never switched off: a press the app has no use for is simply
/// ignored, where handing the buttons back would let the Camera Control throw the user into the
/// Camera app.
private struct HardwareTrigger: ViewModifier {
    let onDown: @MainActor () -> Void
    let onUp: @MainActor () -> Void

    func body(content: Content) -> some View {
        let onDown = onDown, onUp = onUp
        // One handler for every button: while one is held, the system ignores the others. AVKit does
        // not say which thread calls it, so the handler is not tied to the main actor and hops there.
        content.onCameraCaptureEvent(action: { @Sendable event in
            let phase = event.phase
            let summary = "\(event)"
            DispatchQueue.main.async {
                switch phase {
                case .began:
                    print("[eyes] hardware button down: \(summary)")
                    onDown()
                case .ended:
                    print("[eyes] hardware button up: \(summary)")
                    onUp()
                case .cancelled:
                    // The system took the press away; like a cancelled touch, it counts as a release
                    // so the app is never left listening.
                    print("[eyes] hardware button cancelled: \(summary)")
                    onUp()
                @unknown default:
                    print("[eyes] hardware button, unknown phase \(phase.rawValue): \(summary)")
                }
            }
        })
    }
}

extension View {
    /// Calls `onDown` when a hardware capture button is pressed and `onUp` when it is let go.
    func hardwareTrigger(onDown: @escaping @MainActor () -> Void, onUp: @escaping @MainActor () -> Void) -> some View {
        modifier(HardwareTrigger(onDown: onDown, onUp: onUp))
    }
}
