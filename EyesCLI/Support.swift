import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import ImageIO

func loadCGImage(_ path: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

/// The image as a BGRA pixel buffer, the format camera frames have in the app.
func loadPixelBuffer(_ path: String) -> CVPixelBuffer? {
    loadCGImage(path).flatMap(PixelWarp.pixelBuffer(from:))
}

/// Compiles an .mlpackage for use on this Mac (the app bundles the compiled form instead).
func compileModel(_ path: String) throws -> URL {
    try MLModel.compileModel(at: URL(fileURLWithPath: path))
}

func writePNG(_ image: CGImage, to path: String) {
    guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}
