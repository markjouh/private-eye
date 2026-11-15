import CoreVideo

/// How much fine detail a camera frame holds. A frame smeared by a moving phone or a moving hand
/// scores a fraction of what the same view scores when still.
///
/// The number depends on what is in view (a bookshelf scores far above a bare wall), so it only means
/// something next to the score of another frame of the same view, taken a moment before or after.
enum Sharpness {
    /// Mean squared difference between neighbouring cells of a coarse brightness grid, about 360
    /// cells across. Each cell is the average of several pixels under it, which keeps sensor noise in
    /// a dim room from counting as detail. `buffer` is BGRA. Takes about half a millisecond.
    static func score(_ buffer: CVPixelBuffer) -> Float {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let cell = max(1, min(width, height) / 360)
        // Every pixel of a small cell, every second one (each way) of the camera's larger ones.
        let step = max(1, cell / 2)
        let across = cell / step
        let columns = width / cell, rows = height / cell
        guard columns > 1, rows > 1 else { return 0 }
        let pixels = base.assumingMemoryBound(to: UInt8.self)

        // Sums of the green channel (most of what brightness is) under each cell, one row of cells
        // at a time; only the row above is kept.
        var above = [Int32](repeating: 0, count: columns)
        var current = [Int32](repeating: 0, count: columns)
        var total: Int64 = 0
        for row in 0..<rows {
            for column in 0..<columns { current[column] = 0 }
            for y in stride(from: row * cell, to: (row + 1) * cell, by: step) {
                var pixel = pixels + y * rowBytes + 1
                for column in 0..<columns {
                    var sum: Int32 = 0
                    for _ in 0..<across {
                        sum += Int32(pixel.pointee)
                        pixel += 4 * step
                    }
                    current[column] += sum
                }
            }
            for column in 0..<columns {
                if column > 0 {
                    let sideways = Int64(current[column] - current[column - 1])
                    total += sideways * sideways
                }
                if row > 0 {
                    let down = Int64(current[column] - above[column])
                    total += down * down
                }
            }
            swap(&above, &current)
        }
        // Back to brightness levels (0...255) per cell, so the score does not depend on the cell size.
        let perCell = Float(across * across)
        return Float(total) / Float(columns * rows) / (perCell * perCell)
    }
}
