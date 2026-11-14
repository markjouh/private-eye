import SwiftUI

/// Name tags over the user's own things in the camera view ("your water bottle").
struct BelongingOverlay: View {
    let found: [FoundBelonging]
    /// Pixel size of the camera frame the boxes are normalized to.
    let frameSize: CGSize
    /// Tag text follows the user's text size setting.
    @ScaledMetric(relativeTo: .footnote) private var tagTextSize: CGFloat = 16

    var body: some View {
        Canvas { context, size in
            // Same aspect-fill transform as the preview layer.
            let scale = max(size.width / frameSize.width, size.height / frameSize.height)
            let shown = CGSize(width: frameSize.width * scale, height: frameSize.height * scale)
            let origin = CGPoint(x: (size.width - shown.width) / 2, y: (size.height - shown.height) / 2)

            for thing in found {
                let rect = CGRect(
                    x: origin.x + thing.box.minX * shown.width, y: origin.y + thing.box.minY * shown.height,
                    width: thing.box.width * shown.width, height: thing.box.height * shown.height)
                context.stroke(Path(roundedRect: rect, cornerRadius: 8), with: .color(.yellow),
                               style: StrokeStyle(lineWidth: 3, dash: thing.tentative ? [6, 4] : []))

                let label = thing.tentative ? "your \(thing.name)?" : "your \(thing.name)"
                let text = context.resolve(
                    Text(label).font(.system(size: tagTextSize, weight: .bold)).foregroundColor(.black))
                let textSize = text.measure(in: size)
                let tag = CGRect(
                    x: min(max(rect.midX - textSize.width / 2 - 8, 4), size.width - textSize.width - 20), y: rect.maxY + 6,
                    width: textSize.width + 16, height: textSize.height + 8)
                context.fill(Path(roundedRect: tag, cornerRadius: 8), with: .color(.yellow))
                context.draw(text, at: CGPoint(x: tag.midX, y: tag.midY), anchor: .center)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
