import AVFoundation
import CoreVideo

/// A LiDAR depth frame in meters, oriented like the (portrait) video frame it was captured with.
struct DepthMap {
    /// LiDAR readings beyond this are too noisy to report.
    static let maxRange: Float = 5.0

    let buffer: CVPixelBuffer   // kCVPixelFormatType_DepthFloat32
    var width: Int { CVPixelBufferGetWidth(buffer) }
    var height: Int { CVPixelBufferGetHeight(buffer) }

    /// `portrait` is whether the matching video frame is taller than wide; a depth map that arrives in
    /// the sensor's landscape orientation is rotated to match.
    init(_ depthData: AVDepthData, portrait: Bool) {
        var data = depthData
        if data.depthDataType != kCVPixelFormatType_DepthFloat32 {
            data = data.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        }
        let map = data.depthDataMap
        if portrait, CVPixelBufferGetWidth(map) > CVPixelBufferGetHeight(map) {
            data = data.applyingExifOrientation(.right)
        }
        buffer = data.depthDataMap
    }

    /// A map made from plain values, row by row from the top: synthetic scenes for tests.
    init?(width: Int, height: Int, meters: [Float]) {
        var made: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_DepthFloat32, nil, &made)
        guard let made, meters.count == width * height else { return nil }
        buffer = made
        CVPixelBufferLockBaseAddress(made, [])
        defer { CVPixelBufferUnlockBaseAddress(made, []) }
        guard let base = CVPixelBufferGetBaseAddress(made) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(made)
        let rowSize = width * MemoryLayout<Float32>.size
        meters.withUnsafeBytes { source in
            for y in 0..<height {
                (base + y * rowBytes).copyMemory(from: source.baseAddress! + y * rowSize, byteCount: rowSize)
            }
        }
    }

    /// Hands `body` the pixels: rows of Float32 meters, `rowBytes` apart, unusable ones NaN or 0.
    /// Nothing is copied, so a caller can read just the pixels it needs.
    func withMeters<Result>(_ body: (_ base: UnsafeRawPointer, _ rowBytes: Int) -> Result) -> Result? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        return body(base, CVPixelBufferGetBytesPerRow(buffer))
    }

    /// Distance in meters to whatever fills `box` (normalized, origin top-left), or nil when the
    /// sensor has no usable reading there.
    ///
    /// Samples the middle of the box and takes a low percentile, so the object wins over background
    /// showing through or around it.
    func distance(in box: CGRect) -> Float? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let core = box.insetBy(dx: box.width * 0.2, dy: box.height * 0.2)

        let grid = 9
        var samples: [Float] = []
        samples.reserveCapacity(grid * grid)
        for gy in 0..<grid {
            for gx in 0..<grid {
                let u = core.minX + core.width * (CGFloat(gx) + 0.5) / CGFloat(grid)
                let v = core.minY + core.height * (CGFloat(gy) + 0.5) / CGFloat(grid)
                let x = min(max(Int(u * CGFloat(width)), 0), width - 1)
                let y = min(max(Int(v * CGFloat(height)), 0), height - 1)
                let meters = base.load(fromByteOffset: y * rowBytes + x * MemoryLayout<Float32>.size, as: Float32.self)
                if meters.isFinite, meters > 0.05 { samples.append(meters) }
            }
        }
        guard samples.count >= grid * grid / 4 else { return nil }
        samples.sort()
        let value = samples[samples.count * 3 / 10]
        return value <= Self.maxRange ? value : nil
    }
}
