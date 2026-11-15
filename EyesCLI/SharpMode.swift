import CoreVideo
import Foundation

/// The sharpness score of image files, one line each: `score <tab> ms <tab> path`.
///   eyes-cli sharp <image> ...
/// With no images, checks the score on a made-up picture smeared by growing amounts.
func runSharpMode(_ paths: [String]) {
    if paths.isEmpty { return checkSharpness() }
    for path in paths {
        guard let buffer = loadPixelBuffer(path) else { print("could not read \(path)"); continue }
        let start = Date()
        let score = Sharpness.score(buffer)
        print(String(format: "%.1f\t%.2f\t%@", score, Date().timeIntervalSince(start) * 1000, path))
    }
}

/// A camera-sized picture of blocks of random brightness, smeared sideways as a moving phone would.
/// The score has to fall with every increase, and a smear the language model would notice (it sees
/// the frame at about 0.4 of its size, so 8 pixels and up) has to cost more than the app's margin.
private func checkSharpness() {
    let width = 1440, height = 1920, block = 12
    var generator = SystemRandomNumberGenerator()
    var levels = [UInt8](repeating: 0, count: (width / block + 1) * (height / block + 1))
    for i in levels.indices { levels[i] = UInt8.random(in: 40...215, using: &generator) }
    func picture(smear: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let columns = width / block + 1
        for y in 0..<height {
            for x in 0..<width {
                var sum = 0
                for dx in 0..<smear { sum += Int(levels[(y / block) * columns + min(x + dx, width - 1) / block]) }
                let level = UInt8(sum / smear)
                let pixel = base + y * rowBytes + x * 4
                pixel[0] = level; pixel[1] = level; pixel[2] = level; pixel[3] = 255
            }
        }
        return buffer
    }
    let smears = [1, 4, 8, 16, 32]
    let scores = smears.map { picture(smear: $0).map(Sharpness.score) ?? 0 }
    for (smear, score) in zip(smears, scores) { print(String(format: "smeared %2d px: %.0f", smear, score)) }
    let falling = zip(scores, scores.dropFirst()).allSatisfy { $0 > $1 }
    let clear = scores[0] > 1.5 * scores[2]
    print(falling && clear ? "sharpness: ok" : "sharpness: FAIL (falling \(falling), 8 px clearly lower \(clear))")
}
