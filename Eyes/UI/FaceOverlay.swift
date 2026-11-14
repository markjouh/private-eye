import SwiftUI

/// Name tags over the faces of people the user has introduced.
struct FaceOverlay: View {
    let faces: [RecognizedFace]
    /// Pixel size of the camera frame the boxes are normalized to.
    let frameSize: CGSize
    /// Tag text follows the user's text size setting.
    @ScaledMetric(relativeTo: .footnote) private var tagTextSize: CGFloat = 18

    var body: some View {
        Canvas { context, size in
            // Same aspect-fill transform as the preview layer.
            let scale = max(size.width / frameSize.width, size.height / frameSize.height)
            let shown = CGSize(width: frameSize.width * scale, height: frameSize.height * scale)
            let origin = CGPoint(x: (size.width - shown.width) / 2, y: (size.height - shown.height) / 2)

            for face in faces {
                guard let name = face.name else { continue }
                let rect = CGRect(
                    x: origin.x + face.box.minX * shown.width, y: origin.y + face.box.minY * shown.height,
                    width: face.box.width * shown.width, height: face.box.height * shown.height)
                context.stroke(Path(roundedRect: rect, cornerRadius: 10), with: .color(.white), lineWidth: 3)

                var label = face.tentative ? "\(name)?" : name
                if let distance = face.distance { label += " " + Surroundings.tag(distance) }
                let text = context.resolve(
                    Text(label).font(.system(size: tagTextSize, weight: .bold)).foregroundColor(.black))
                let textSize = text.measure(in: size)
                let tag = CGRect(
                    x: rect.midX - textSize.width / 2 - 8, y: rect.maxY + 6,
                    width: textSize.width + 16, height: textSize.height + 8)
                context.fill(Path(roundedRect: tag, cornerRadius: 8), with: .color(.white))
                context.draw(text, at: CGPoint(x: tag.midX, y: tag.midY), anchor: .center)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
