import Accelerate
import CoreGraphics
import CoreML

/// Turns YOLO segmentation output into one small image that shades each drawn object's shape.
///
/// An object's mask is its 32 coefficients applied to the model's 32 prototype planes: the object is
/// where that sum is positive (sigmoid above 0.5), inside its box. The image stays at prototype
/// resolution (120 x 160 for the whole frame) and is scaled up smoothly when drawn. This runs on every
/// detector frame on a phone that is already warm, so it is all vDSP over buffers kept between frames.
final class MaskShader {
    /// More shaded objects than this cost time and turn the picture to mush.
    static let maxObjects = 12
    /// How strongly a shape is tinted; the camera picture has to stay readable through it.
    static let opacity: Float = 0.4
    /// Coverage gained per unit of mask logit: the sigmoid's own slope at the threshold, so coverage is
    /// the model's probability with the tails clipped (and no exp). Keeping that soft edge, rather than
    /// cutting hard at 0.5, is what lets the scaled-up outline run between pixels instead of along them.
    private static let edgeGain: Float = 0.25

    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var scratch = UnsafeMutableBufferPointer<Float>.allocate(capacity: 0)

    deinit { scratch.deallocate() }

    /// Stable, distinct color per label, shared by the shading and the label tags.
    static func tint(for label: String) -> (red: Float, green: Float, blue: Float) {
        let hash = label.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        let hue = Float(hash % 360) / 60
        // HSB to RGB at saturation 0.75 and full brightness.
        func channel(_ n: Float) -> Float {
            let k = (n + hue).truncatingRemainder(dividingBy: 6)
            return 1 - 0.75 * max(0, min(k, 4 - k, 1))
        }
        return (channel(5), channel(3), channel(1))
    }

    /// Shades `objects` into one premultiplied RGBA image covering the whole frame, or nil if there is
    /// nothing to shade.
    ///
    /// `row` is the object's row in `output` ([1, rows, box + class + coefficients]); its mask
    /// coefficients are the last values of that row, one per plane of `prototypes` ([1, planes, H, W]).
    func shade(_ objects: [(detection: Detection, row: Int)], output: MLMultiArray, prototypes: MLMultiArray) -> CGImage? {
        guard !objects.isEmpty, output.shape.count == 3, prototypes.shape.count == 4 else { return nil }
        let planes = prototypes.shape[1].intValue
        let height = prototypes.shape[2].intValue
        let width = prototypes.shape[3].intValue
        let firstCoefficient = output.shape[2].intValue - planes
        guard planes > 0, firstCoefficient >= 0 else { return nil }
        let area = width * height

        // One allocation, laid out as: prototypes, the image's four channels, two working planes,
        // then an object's coefficients and color.
        let needed = (planes + 6) * area + planes + 4
        if scratch.count != needed {
            scratch.deallocate()
            scratch = .allocate(capacity: needed)
        }
        guard let protos = scratch.baseAddress else { return nil }
        let image = protos + planes * area
        let cover = image + 4 * area
        let keep = cover + area
        let coefficients = keep + area
        let color = coefficients + planes

        // Core ML pads rows and picks the element type, so gather the planes into contiguous Floats.
        let protoStrides = prototypes.strides.map(\.intValue)
        for plane in 0..<planes {
            guard prototypes.copyFloats(from: plane * protoStrides[1], rows: height, rowStride: protoStrides[2],
                                        columns: width, columnStride: protoStrides[3], to: protos + plane * area) else { return nil }
        }
        vDSP_vclr(image, 1, vDSP_Length(4 * area))

        // Largest first, so small things in front of big ones stay visible. Two labels for one box:
        // the surer one goes on top.
        let ordered = objects.sorted { a, b in
            let areaA = a.detection.box.width * a.detection.box.height
            let areaB = b.detection.box.width * b.detection.box.height
            return areaA != areaB ? areaA > areaB : a.detection.confidence < b.detection.confidence
        }
        let outputStrides = output.strides.map(\.intValue)
        var gain = Self.edgeGain, half: Float = 0.5, zero: Float = 0, one: Float = 1, minusOne: Float = -1
        for object in ordered {
            let box = object.detection.box
            let x0 = max(Int((box.minX * CGFloat(width)).rounded(.down)), 0)
            let x1 = min(Int((box.maxX * CGFloat(width)).rounded(.up)), width)
            let y0 = max(Int((box.minY * CGFloat(height)).rounded(.down)), 0)
            let y1 = min(Int((box.maxY * CGFloat(height)).rounded(.up)), height)
            guard x1 > x0, y1 > y0 else { continue }
            guard output.copyFloats(from: object.row * outputStrides[1] + firstCoefficient * outputStrides[2], rows: 1, rowStride: 0,
                                    columns: planes, columnStride: outputStrides[2], to: coefficients) else { return nil }

            // Mask logits for the box's rows at full width: whole rows are contiguous, columns are not.
            let first = y0 * width
            let count = vDSP_Length((y1 - y0) * width)
            vDSP_vsmul(protos + first, 1, coefficients, cover, 1, count)
            for plane in 1..<planes {
                vDSP_vsma(protos + plane * area + first, 1, coefficients + plane, cover, 1, cover, 1, count)
            }
            // Logit to coverage in 0...1, then drop what lies left and right of the box.
            vDSP_vsmsa(cover, 1, &gain, &half, cover, 1, count)
            vDSP_vclip(cover, 1, &zero, &one, cover, 1, count)
            for y in 0..<(y1 - y0) {
                vDSP_vclr(cover + y * width, 1, vDSP_Length(x0))
                vDSP_vclr(cover + y * width + x1, 1, vDSP_Length(width - x1))
            }

            // Replace what is underneath in proportion to coverage (rather than stacking translucent
            // layers), so overlapping objects keep their own color and the same opacity.
            let tint = Self.tint(for: object.detection.label)
            let level = Self.opacity * 255
            color[0] = tint.red * level
            color[1] = tint.green * level
            color[2] = tint.blue * level
            color[3] = level
            vDSP_vsmsa(cover, 1, &minusOne, &one, keep, 1, count)
            for channel in 0..<4 {
                let band = image + channel * area + first
                vDSP_vmul(band, 1, keep, 1, band, 1, count)
                vDSP_vsma(cover, 1, color + channel, band, 1, band, 1, count)
            }
        }

        var pixels = Data(count: area * 4)
        pixels.withUnsafeMutableBytes { bytes in
            guard let rgba = bytes.bindMemory(to: UInt8.self).baseAddress else { return }
            for channel in 0..<4 {
                vDSP_vfixru8(image + channel * area, 1, rgba + channel, 4, vDSP_Length(area))
            }
        }
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: Self.colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

private extension MLMultiArray {
    /// Copies a `rows` x `columns` block as contiguous Floats, starting `offset` elements in; false if
    /// the array does not hold floating point. Core ML pads rows, so the offset and strides must be
    /// built from `strides`, never from `shape`.
    func copyFloats(from offset: Int, rows: Int, rowStride: Int, columns: Int, columnStride: Int,
                    to out: UnsafeMutablePointer<Float>) -> Bool {
        func copy<T: BinaryFloatingPoint>(_ type: T.Type) {
            let source = dataPointer.assumingMemoryBound(to: T.self) + offset
            for y in 0..<rows {
                let from = source + y * rowStride
                let to = out + y * columns
                // The padding sits between rows, so in practice a row is contiguous; spelling that
                // case out lets it compile to a block copy, which halves the cost of a frame's masks.
                if columnStride == 1 {
                    for x in 0..<columns { to[x] = Float(from[x]) }
                } else {
                    for x in 0..<columns { to[x] = Float(from[x * columnStride]) }
                }
            }
        }
        switch dataType {
        case .float32: copy(Float.self)
        case .float16: copy(Float16.self)
        case .double: copy(Double.self)
        default: return false
        }
        return true
    }
}
