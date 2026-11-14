import CoreGraphics
import CoreML
import CoreText
import CoreVideo
import Foundation

/// Runs the Core ML detector the way the app does (BGRA pixel buffer in, normalized boxes out).
/// `--out dir` also writes each photo as a PNG with the mask shading and labels on top, for checking
/// by eye that the shading follows the objects.
func runDetectMode(_ arguments: [String]) {
    var args = arguments
    guard args.count >= 3 else {
        print("usage: eyes-cli detect <yoloe26m.mlpackage> <yoloe_labels.json> [--out dir] <image> ...")
        return
    }
    let modelPath = args.removeFirst()
    let labelsPath = args.removeFirst()
    var outDir: String?
    while let first = args.first, first.hasPrefix("--") {
        args.removeFirst()
        switch first {
        case "--out": outDir = args.removeFirst()
        default: print("unknown flag \(first)"); return
        }
    }
    do {
        let compiled = try compileModel(modelPath)
        let detector = try ObjectDetector(compiledModel: compiled, labels: URL(fileURLWithPath: labelsPath))
        if let outDir { try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true) }
        for path in args {
            guard let cg = loadCGImage(path) else { print("could not read \(path)"); continue }
            guard let buffer = PixelWarp.pixelBuffer(from: cg) else { continue }
            _ = detector.detect(in: buffer)   // warm-up
            let found = detector.detect(in: buffer)
            let name = (path as NSString).lastPathComponent
            print(String(format: "%@ (%dx%d) %.1f ms, masks %.2f ms:", name, cg.width, cg.height,
                         detector.lastInferenceMs, detector.lastMaskMs))
            for d in found {
                print(String(format: "  %@ %.2f  x %.0f-%.0f  y %.0f-%.0f", d.label, d.confidence,
                             d.box.minX * Double(cg.width), d.box.maxX * Double(cg.width),
                             d.box.minY * Double(cg.height), d.box.maxY * Double(cg.height)))
            }
            if let outDir, let image = shaded(cg, mask: detector.lastMask, detections: found) {
                let stem = (name as NSString).deletingPathExtension
                writePNG(image, to: (outDir as NSString).appendingPathComponent(stem + ".png"))
            }
        }
    } catch {
        print("detector failed: \(error)")
    }
}

/// The photo with the detector's shading on top and the drawn objects outlined and tagged, laid out
/// like the app's overlay.
private func shaded(_ photo: CGImage, mask: CGImage?, detections: [Detection]) -> CGImage? {
    let size = CGSize(width: photo.width, height: photo.height)
    guard let context = CGContext(
        data: nil, width: photo.width, height: photo.height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    let full = CGRect(origin: .zero, size: size)
    context.draw(photo, in: full)
    if let mask {
        context.interpolationQuality = .high
        context.draw(mask, in: full)
    }

    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 11, nil)
    for detection in detections.reversed() where detection.confidence >= ObjectDetector.displayConfidence {
        let tint = MaskShader.tint(for: detection.label)
        let color = CGColor(srgbRed: CGFloat(tint.red), green: CGFloat(tint.green), blue: CGFloat(tint.blue), alpha: 1)
        // Core Graphics counts y from the bottom; boxes count from the top.
        let box = detection.box
        let rect = CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height,
                          width: box.width * size.width, height: box.height * size.height)
        context.setStrokeColor(color.copy(alpha: 0.7) ?? color)
        context.stroke(rect, width: 1)

        let text = NSAttributedString(string: detection.label, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(text)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        let tag = CGRect(x: max(min(rect.minX, size.width - textWidth - 8), 0), y: min(rect.maxY, size.height - ascent - descent - 4),
                         width: textWidth + 8, height: ascent + descent + 4)
        context.setFillColor(color)
        context.fill(tag)
        context.textPosition = CGPoint(x: tag.minX + 4, y: tag.minY + 2 + descent)
        CTLineDraw(line, context)
    }
    return context.makeImage()
}
