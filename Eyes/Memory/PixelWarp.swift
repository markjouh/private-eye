import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import ImageIO

/// Resampling of BGRA camera frames into the small fixed-size inputs the embedding models take.
/// Hand-rolled so the coordinate convention is unambiguous everywhere: (0, 0) is the top-left pixel.
enum PixelWarp {
    /// Produces a `width` x `height` BGRA buffer where output pixel (x, y) shows the source at
    /// `toSource` applied to (x, y). Source positions outside the image repeat its edge. When the
    /// output is a reduction, each output pixel averages a small grid of samples so fine detail does
    /// not alias.
    static func warp(_ source: CVPixelBuffer, toSource: CGAffineTransform, width: Int, height: Int) -> CVPixelBuffer? {
        guard CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &out)
        guard let out else { return nil }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(out, [])
        defer {
            CVPixelBufferUnlockBaseAddress(out, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        guard let srcBase = CVPixelBufferGetBaseAddress(source), let dstBase = CVPixelBufferGetBaseAddress(out) else { return nil }
        let src = srcBase.assumingMemoryBound(to: UInt8.self)
        let dst = dstBase.assumingMemoryBound(to: UInt8.self)
        let sw = CVPixelBufferGetWidth(source), sh = CVPixelBufferGetHeight(source)
        let srcRow = CVPixelBufferGetBytesPerRow(source), dstRow = CVPixelBufferGetBytesPerRow(out)

        let a = Float(toSource.a), b = Float(toSource.b), c = Float(toSource.c), d = Float(toSource.d)
        let tx = Float(toSource.tx), ty = Float(toSource.ty)
        // Source pixels covered by one output pixel, per axis.
        let scale = (abs(a * d - b * c)).squareRoot()
        let n = min(4, max(1, Int(scale.rounded(.up))))
        let inv = 1 / Float(n * n)
        let maxX = Float(sw - 1), maxY = Float(sh - 1)

        for y in 0..<height {
            for x in 0..<width {
                var sumB: Float = 0, sumG: Float = 0, sumR: Float = 0
                for j in 0..<n {
                    for i in 0..<n {
                        // Sample positions spread evenly across the output pixel's footprint.
                        let ox = Float(x) + (Float(i) + 0.5) / Float(n) - 0.5
                        let oy = Float(y) + (Float(j) + 0.5) / Float(n) - 0.5
                        let fx = min(max(a * ox + c * oy + tx, 0), maxX)
                        let fy = min(max(b * ox + d * oy + ty, 0), maxY)
                        let x0 = Int(fx), y0 = Int(fy)
                        let x1 = min(x0 + 1, sw - 1), y1 = min(y0 + 1, sh - 1)
                        let wx = fx - Float(x0), wy = fy - Float(y0)
                        let p00 = src + y0 * srcRow + x0 * 4, p10 = src + y0 * srcRow + x1 * 4
                        let p01 = src + y1 * srcRow + x0 * 4, p11 = src + y1 * srcRow + x1 * 4
                        let w00 = (1 - wx) * (1 - wy), w10 = wx * (1 - wy), w01 = (1 - wx) * wy, w11 = wx * wy
                        sumB += Float(p00[0]) * w00 + Float(p10[0]) * w10 + Float(p01[0]) * w01 + Float(p11[0]) * w11
                        sumG += Float(p00[1]) * w00 + Float(p10[1]) * w10 + Float(p01[1]) * w01 + Float(p11[1]) * w11
                        sumR += Float(p00[2]) * w00 + Float(p10[2]) * w10 + Float(p01[2]) * w01 + Float(p11[2]) * w11
                    }
                }
                let o = dst + y * dstRow + x * 4
                o[0] = UInt8(min(max(sumB * inv + 0.5, 0), 255))
                o[1] = UInt8(min(max(sumG * inv + 0.5, 0), 255))
                o[2] = UInt8(min(max(sumR * inv + 0.5, 0), 255))
                o[3] = 255
            }
        }
        return out
    }

    /// A BGRA pixel buffer holding `image`, for code paths that start from a CGImage.
    static func pixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }

    /// A small JPEG of a BGRA buffer, for showing what was remembered.
    static func jpeg(_ buffer: CVPixelBuffer) -> Data? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let image = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)?.makeImage()
        else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Reads a Core ML embedding output into a unit-length vector.
    static func unitVector(_ array: MLMultiArray) -> [Float] {
        unit((0..<array.count).map { array[$0].floatValue })
    }

    /// `values` scaled to unit length.
    static func unit(_ values: [Float]) -> [Float] {
        var norm: Float = 0
        for v in values { norm += v * v }
        norm = norm.squareRoot()
        return norm > 0 ? values.map { $0 / norm } : values
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return -1 }
        var dot: Float = 0
        for i in a.indices { dot += a[i] * b[i] }
        return dot   // both are unit length
    }
}
