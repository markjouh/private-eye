import CoreGraphics
import CoreVideo
import Foundation

extension RGBImage {
    /// A BGRA camera frame scaled down so its longer side is at most `maxSide`, each pixel the
    /// average of the block it covers. Used for the frames kept in memory: it goes straight from
    /// the camera's buffer without building a full-size image first, so keeping a frame costs a
    /// few milliseconds on the camera's own queue.
    init?(pixelBuffer frame: CVPixelBuffer, maxSide: Int) {
        guard CVPixelBufferGetPixelFormatType(frame) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(frame) else { return nil }
        let source = base.assumingMemoryBound(to: UInt8.self)
        let sw = CVPixelBufferGetWidth(frame), sh = CVPixelBufferGetHeight(frame), rowBytes = CVPixelBufferGetBytesPerRow(frame)
        guard sw > 0, sh > 0 else { return nil }
        let scale = min(1.0, Double(maxSide) / Double(max(sw, sh)))
        let w = max(1, Int((Double(sw) * scale).rounded())), h = max(1, Int((Double(sh) * scale).rounded()))
        // As many samples each way as source pixels an output pixel covers, up to four; more would
        // cost time and change nothing visible.
        let samples = max(1, min(4, Int((Double(sw) / Double(w)).rounded(.up))))
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        rgb.withUnsafeMutableBufferPointer { out in
            for y in 0..<h {
                let top = y * sh / h, rows = max(1, (y + 1) * sh / h - top)
                for x in 0..<w {
                    let left = x * sw / w, columns = max(1, (x + 1) * sw / w - left)
                    var r = 0, g = 0, b = 0
                    for j in 0..<samples {
                        let row = source + (top + j * rows / samples) * rowBytes
                        for i in 0..<samples {
                            let p = row + (left + i * columns / samples) * 4
                            b += Int(p[0]); g += Int(p[1]); r += Int(p[2])
                        }
                    }
                    let n = samples * samples, o = (y * w + x) * 3
                    out[o] = UInt8(r / n); out[o + 1] = UInt8(g / n); out[o + 2] = UInt8(b / n)
                }
            }
        }
        self.init(width: w, height: h, pixels: rgb)
    }
}

extension RGBImage {
    /// The image as a BGRA pixel buffer, the form the text recogniser takes.
    func pixelBuffer() -> CVPixelBuffer? {
        var made: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &made)
        guard let buffer = made else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let out = base.assumingMemoryBound(to: UInt8.self), rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        pixels.withUnsafeBufferPointer { rgb in
            for y in 0..<height {
                var p = out + y * rowBytes
                var i = y * width * 3
                for _ in 0..<width {
                    p[0] = rgb[i + 2]; p[1] = rgb[i + 1]; p[2] = rgb[i]; p[3] = 255
                    p += 4
                    i += 3
                }
            }
        }
        return buffer
    }
}

/// A copy of a BGRA camera frame as an image, for handing to the language model. The copy is the
/// point: the camera reuses its buffers, and has only so many to lend.
func copiedImage(of frame: CVPixelBuffer) -> CGImage? {
    guard CVPixelBufferGetPixelFormatType(frame) == kCVPixelFormatType_32BGRA else { return nil }
    CVPixelBufferLockBaseAddress(frame, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
    return CGContext(
        data: CVPixelBufferGetBaseAddress(frame), width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame),
        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(frame), space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)?.makeImage()
}

/// Memory the process is charged for, in megabytes: the figure Xcode's gauge shows, and the one
/// iOS ends an app over. Logged while testing that the video features do not grow.
func memoryFootprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
}
