import CoreVideo
import Foundation

/// A camera frame boiled down to a coarse grid of brightness, cheap enough to work out for every
/// frame the detector sees (about 50,000 pixel reads). Two of them say how much the scene changed
/// in between, which is what decides when a frame is worth keeping and when the language model is
/// worth asking; nothing here is ever shown to the model.
struct SceneSignature {
    static let columns = 24
    static let rows = 32

    /// Brightness of each cell, row by row from the top, with the frame's own mean taken out and
    /// its contrast scaled to one, so a change of exposure is not a change of scene.
    let cells: [Float]
    /// True for a frame with nothing in it to compare: a covered lens, a blank wall up close.
    let isBlank: Bool

    init?(_ frame: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(frame) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(frame) else { return nil }
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        let width = CVPixelBufferGetWidth(frame), height = CVPixelBufferGetHeight(frame)
        let rowBytes = CVPixelBufferGetBytesPerRow(frame)
        guard width >= Self.columns * 2, height >= Self.rows * 2 else { return nil }

        // About 8 x 8 samples a cell, spread across it: enough that a textured surface averages
        // out instead of flickering as the hand moves.
        let stepX = max(1, width / (Self.columns * 8)), stepY = max(1, height / (Self.rows * 8))
        var cells = [Float](repeating: 0, count: Self.columns * Self.rows)
        for row in 0..<Self.rows {
            let top = row * height / Self.rows, bottom = (row + 1) * height / Self.rows
            for column in 0..<Self.columns {
                let left = column * width / Self.columns, right = (column + 1) * width / Self.columns
                var sum = 0, count = 0
                var y = top
                while y < bottom {
                    var p = pixels + y * rowBytes + left * 4
                    var x = left
                    while x < right {
                        sum += Int(p[2]) * 77 + Int(p[1]) * 150 + Int(p[0]) * 29   // BGRA to luma, times 256
                        count += 1
                        x += stepX
                        p += stepX * 4
                    }
                    y += stepY
                }
                cells[row * Self.columns + column] = Float(sum) / Float(max(count, 1) * 256)
            }
        }
        cells = Self.blurred(cells)
        let mean = cells.reduce(0, +) / Float(cells.count)
        let spread = (cells.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(cells.count)).squareRoot()
        // Brightness is 0 to 255; a frame this flat is one colour edge to edge.
        isBlank = spread < 2
        self.cells = isBlank ? [Float](repeating: 0, count: cells.count) : cells.map { ($0 - mean) / spread }
    }

    /// Each cell mixed with its neighbours (weights 1, 2, 1 each way). An edge that moves by less
    /// than a cell then shifts its cells' values a little instead of flipping them, which is most
    /// of what a hand that is trying to hold still does to the picture.
    private static func blurred(_ cells: [Float]) -> [Float] {
        var across = cells, both = cells
        for row in 0..<rows {
            for column in 0..<columns {
                let i = row * columns + column
                across[i] = (cells[row * columns + max(column - 1, 0)] + 2 * cells[i] + cells[row * columns + min(column + 1, columns - 1)]) / 4
            }
        }
        for row in 0..<rows {
            for column in 0..<columns {
                let i = row * columns + column
                both[i] = (across[max(row - 1, 0) * columns + column] + 2 * across[i] + across[min(row + 1, rows - 1) * columns + column]) / 4
            }
        }
        return both
    }

    /// How different the scene is from `other`: 0 for the same view, around 2 for unrelated ones.
    ///
    /// It is the mean difference over the tenth of the grid that differs most, so something
    /// arriving in one part of the view counts in full instead of being averaged away over the
    /// rest. Before comparing, the grids are slid one cell each way and the best fit taken, so a
    /// small wobble of the hand counts for little.
    func change(from other: SceneSignature) -> Float {
        if isBlank || other.isBlank { return isBlank && other.isBlank ? 0 : 2 }
        let columns = Self.columns, rows = Self.rows
        var best = Float.infinity
        var differences = [Float]()
        differences.reserveCapacity(cells.count)
        for dy in -1...1 {
            for dx in -1...1 {
                differences.removeAll(keepingCapacity: true)
                for row in max(0, -dy)..<min(rows, rows - dy) {
                    for column in max(0, -dx)..<min(columns, columns - dx) {
                        differences.append(abs(cells[row * columns + column] - other.cells[(row + dy) * columns + column + dx]))
                    }
                }
                differences.sort(by: >)
                let top = max(1, differences.count / 10)
                best = min(best, differences[..<top].reduce(0, +) / Float(top))
            }
        }
        return best
    }
}
