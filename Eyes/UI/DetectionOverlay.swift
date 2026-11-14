import SwiftUI

/// Detected objects drawn over the preview: each one's shape shaded, a hairline box and a label tag.
struct DetectionOverlay: View {
    let detections: [Detection]
    /// The detector's shading of those objects' shapes (`ObjectDetector.lastMask`), covering the whole frame.
    var mask: CGImage?
    /// Pixel size of the camera frame the boxes are normalized to.
    let frameSize: CGSize
    /// Tag text follows the user's text size setting.
    @ScaledMetric(relativeTo: .footnote) private var tagTextSize: CGFloat = 13

    var body: some View {
        Canvas { context, size in
            // Same aspect-fill transform as the preview layer.
            let scale = max(size.width / frameSize.width, size.height / frameSize.height)
            let shown = CGSize(width: frameSize.width * scale, height: frameSize.height * scale)
            let origin = CGPoint(x: (size.width - shown.width) / 2, y: (size.height - shown.height) / 2)

            if let mask {
                // The mask is far coarser than the screen; smooth scaling keeps its edges from showing as blocks.
                context.draw(Image(decorative: mask, scale: 1).interpolation(.high), in: CGRect(origin: origin, size: shown))
            }

            // Weakest first, so where tags collide the surest one ends up on top.
            for detection in detections.sorted(by: { $0.confidence < $1.confidence }) {
                let rect = CGRect(
                    x: origin.x + detection.box.minX * shown.width,
                    y: origin.y + detection.box.minY * shown.height,
                    width: detection.box.width * shown.width,
                    height: detection.box.height * shown.height)
                // Aspect fill crops the sides of the frame; nothing to label for what fell outside.
                guard rect.intersects(CGRect(origin: .zero, size: size)) else { continue }
                let tint = MaskShader.tint(for: detection.label)
                // The same color the detector shaded this label's shape with.
                let color = Color(red: Double(tint.red), green: Double(tint.green), blue: Double(tint.blue))
                // The shading carries the shape; the box only ties the tag to it.
                context.stroke(Path(roundedRect: rect, cornerRadius: 4), with: .color(color.opacity(0.7)), lineWidth: 1)

                let text = context.resolve(
                    Text(detection.distance.map { "\(detection.label) \(Surroundings.tag($0))" } ?? detection.label)
                        .font(.system(size: tagTextSize, weight: .semibold))
                        .foregroundColor(Self.ink(on: tint)))
                let textSize = text.measure(in: size)
                // With no heavy box to carry it, the tag has to stay on screen even when its corner of the box is not.
                let tag = CGRect(
                    x: max(min(rect.minX, size.width - textSize.width - 8), 0), y: max(rect.minY - textSize.height - 4, 0),
                    width: textSize.width + 8, height: textSize.height + 4)
                context.fill(Path(roundedRect: tag, cornerRadius: 3), with: .color(color))
                context.draw(text, at: CGPoint(x: tag.minX + 4, y: tag.minY + 2), anchor: .topLeading)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Black or white, whichever reads better on a tag of this color. Black alone falls to 3.4:1 on
    /// the blues and violets; choosing by the tint's luminance keeps every hue above 4.5:1.
    private static func ink(on tint: (red: Float, green: Float, blue: Float)) -> Color {
        func linear(_ channel: Float) -> Float {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(tint.red) + 0.7152 * linear(tint.green) + 0.0722 * linear(tint.blue)
        // Where black on the tint and white on the tint contrast equally.
        return luminance > 0.179 ? .black : .white
    }
}
