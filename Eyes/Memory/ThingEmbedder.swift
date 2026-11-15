import CoreGraphics
import CoreML
import CoreVideo
import Foundation

/// Turns a region of a camera frame into an appearance embedding that tells one particular object
/// from others of its kind: this bottle, not any bottle.
///
/// DINOv3 ViT-S/16 (Core ML, tools/export_embedders.py): a 224x224 crop in, the unit-length CLS token
/// out. Two crops of the same thing score a high cosine (`PixelWarp.cosine`); the thresholds below say
/// how high.
final class ThingEmbedder {
    /// A region scoring at least `acceptThreshold` against a belonging's stored views (best view
    /// counts) is that belonging; from `maybeThreshold` up it is only "possibly" it.
    ///
    /// Measured with `eyes-cli things eval` on 196 Objectron photos: 49 clips of 4 views each, showing
    /// 43 distinct objects (6 to 8 each of books, bottles, cameras, cups, laptops and shoes, and a
    /// chair). Every box was chosen by the detector and BelongingTargeting as in the app, and a photo's
    /// score is the best of up to 4 regions:
    ///
    ///             right object accepted       another object of the same kind accepted
    ///   enrolled  from 1 view | 2 views       1 view | 2 views
    ///   0.60      95% | 98%                   18% | 24%
    ///   0.70      87% | 95%                    4% |  6%
    ///   0.80      60% | 77%                   0.5% | 0.7%
    ///
    /// Objects of another kind were accepted in 0.1% of trials at 0.60 and under 0.05% at 0.70. Below
    /// 0.60 the right object gains almost nothing. The five objects filmed in more than one clip (three
    /// of them in different places) were accepted from another clip's enrolment nearly as often: 83% |
    /// 91% at 0.70.
    ///
    /// Those look-alikes differ more than the ones a person actually has to tell apart. On the phone,
    /// three dark backpacks in one room (13 saved frames, the same test): another backpack was
    /// accepted in 36% | 50% of trials at 0.70 and 10% | 18% at 0.75, and in none at 0.80 (the highest
    /// look-alike pair scored 0.78), while the right backpack was accepted as often at 0.80 as at 0.70
    /// (56% | 72%). The bars were 0.70 and 0.60 until then, and the app called every backpack the
    /// user's. So a sure match needs 0.80, and "possibly" starts at 0.75, not lower: 0.70 to 0.75 is
    /// mostly look-alikes when there are any about. The price is paid on poor views of the right
    /// thing: a steel bottle, out of focus or half hidden on many of 24 saved frames, is now sure on
    /// 8 of them, possibly on 5 and missed on 11, where the old bars matched all 24 (17 sure); on the
    /// Objectron photos the right object is at least "possibly" in 77% | 90% of trials, down from
    /// 95% | 98%. Teaching a thing from a second side wins much of that back.
    static let acceptThreshold: Float = 0.80
    static let maybeThreshold: Float = 0.75
    /// With several belongings remembered, the one asked about should also beat every other on the
    /// same region by this much. In the same test, with all objects enrolled, a look-alike that was
    /// itself a belonging was taken for the one asked about in 0.3% of trials instead of 3.8% at 0.70
    /// (0.5% instead of 17.5% at 0.60), for 3 (6) points fewer accepts of the right object.
    static let margin: Float = 0.03

    /// How the region around a box is cut out for the model.
    struct Crop: Equatable {
        enum Shape {
            /// The region is stretched to fill the square input, losing the object's proportions.
            case stretch
            /// A square around the box, as wide as its longer edge: proportions are kept, and a narrow
            /// object brings some of its surroundings with it.
            case square
            /// The same square, with everything outside the box painted flat grey.
            case padded
        }
        var shape: Shape
        /// Extra border on each side, as a fraction of the box's edge.
        var margin: CGFloat

        /// The tight box, proportions kept, nothing of the surroundings: the only crop that kept working
        /// when the background changed (`eyes-cli things policies`). At the threshold letting in 5% of
        /// look-alikes it accepted 86% of right objects whether or not the box was moved into another
        /// photo; a square crop fell from 81% to 61%, a 25% border from 83% to 38%, and stretching the
        /// tight box held at 82% but did worse on the objects filmed in two places (77% against 83%).
        static let standard = Crop(shape: .padded, margin: 0)
    }

    static let inputSide = 224
    /// Which hardware passed the self-check and runs the model.
    let computeUnits: MLComputeUnits
    private(set) var lastInferenceMs = 0.0

    private let model: MLModel

    convenience init() throws {
        guard let url = Bundle.main.url(forResource: "dinov3_s", withExtension: "mlmodelc") else {
            throw LLMError("dinov3_s.mlmodelc missing from bundle")
        }
        try self.init(compiledModel: url)
    }

    /// Loads the model on the fastest hardware that computes it correctly.
    ///
    /// Half-precision ViTs are fragile: an earlier export of this network gave plausible-looking but
    /// wrong embeddings on the Neural Engine only. So each choice of hardware first has to reproduce,
    /// on a fixed test picture, the embedding PyTorch gave at export (stored in the model's metadata).
    init(compiledModel url: URL) throws {
        var chosen: (MLModel, MLComputeUnits)?
        for units in [MLComputeUnits.all, .cpuAndGPU, .cpuOnly] {
            let config = MLModelConfiguration()
            config.computeUnits = units
            let candidate = try MLModel(contentsOf: url, configuration: config)
            guard let reference = Self.selfCheckReference(of: candidate) else {
                throw LLMError("dinov3_s has no self-check embedding; export it again")
            }
            if let got = Self.run(candidate, on: Self.selfCheckImage()), PixelWarp.cosine(got, reference) >= 0.99 {
                chosen = (candidate, units)
                break
            }
        }
        guard let chosen else { throw LLMError("dinov3_s gives wrong embeddings on every compute unit") }
        (model, computeUnits) = chosen
    }

    /// The embedding of what `box` (normalized, origin top-left) shows in a BGRA frame.
    func embed(_ frame: CVPixelBuffer, box: CGRect, crop: Crop = .standard) -> [Float]? {
        guard let input = Self.crop(frame, box: box, crop: crop) else { return nil }
        return embed(cropped: input)
    }

    /// Embeds a region that is already a 224x224 crop.
    func embed(cropped input: CVPixelBuffer) -> [Float]? {
        let start = Date()
        let embedding = Self.run(model, on: input)
        lastInferenceMs = Date().timeIntervalSince(start) * 1000
        return embedding
    }

    /// The 224x224 model input for `box`, also useful for inspecting what the model is shown.
    static func crop(_ frame: CVPixelBuffer, box: CGRect, crop: Crop = .standard) -> CVPixelBuffer? {
        let frameWidth = CGFloat(CVPixelBufferGetWidth(frame)), frameHeight = CGFloat(CVPixelBufferGetHeight(frame))
        let pixels = CGRect(x: box.minX * frameWidth, y: box.minY * frameHeight,
                            width: box.width * frameWidth, height: box.height * frameHeight)
        guard pixels.width >= 1, pixels.height >= 1 else { return nil }
        let object = pixels.insetBy(dx: -crop.margin * pixels.width, dy: -crop.margin * pixels.height)
        var region = object
        if crop.shape != .stretch {
            let side = max(object.width, object.height)
            region = CGRect(x: object.midX - side / 2, y: object.midY - side / 2, width: side, height: side)
        }
        // Output pixel centres are spread evenly over the region; pixel (0, 0)'s centre is at (0, 0).
        let side = CGFloat(inputSide)
        let sx = region.width / side, sy = region.height / side
        let toSource = CGAffineTransform(a: sx, b: 0, c: 0, d: sy,
                                         tx: region.minX + sx / 2 - 0.5, ty: region.minY + sy / 2 - 0.5)
        guard let out = PixelWarp.warp(frame, toSource: toSource, width: inputSide, height: inputSide) else { return nil }
        if crop.shape == .padded {
            let kept = CGRect(x: (object.minX - region.minX) / sx, y: (object.minY - region.minY) / sy,
                              width: object.width / sx, height: object.height / sy)
            paintGrey(out, outside: kept)
        }
        return out
    }

    // MARK: Internals

    private static func run(_ model: MLModel, on input: CVPixelBuffer) -> [Float]? {
        guard let features = try? MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: input)]),
              let output = try? model.prediction(from: features),
              let array = output.featureValue(for: "embedding")?.multiArrayValue
        else { return nil }
        return PixelWarp.unitVector(array)
    }

    /// Fills everything outside `kept` (output pixels) with the grey the model's normalisation maps to zero.
    private static func paintGrey(_ buffer: CVPixelBuffer, outside kept: CGRect) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let x0 = Int(kept.minX.rounded()), x1 = Int(kept.maxX.rounded())
        let y0 = Int(kept.minY.rounded()), y1 = Int(kept.maxY.rounded())
        for y in 0..<inputSide {
            for x in 0..<inputSide where x < x0 || x >= x1 || y < y0 || y >= y1 {
                let p = base + y * rowBytes + x * 4
                p[0] = 104; p[1] = 116; p[2] = 124   // B, G, R: the ImageNet mean
            }
        }
    }

    /// The picture tools/export_embedders.py `selfcheck_image` draws: two gradients and a checkerboard.
    private static func selfCheckImage() -> CVPixelBuffer {
        var made: CVPixelBuffer?
        CVPixelBufferCreate(nil, inputSide, inputSide, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &made)
        let buffer = made!
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<inputSide {
            for x in 0..<inputSide {
                let p = base + y * rowBytes + x * 4
                p[0] = UInt8((x / 16 + y / 16) % 2 * 255)
                p[1] = UInt8(y * 255 / (inputSide - 1))
                p[2] = UInt8(x * 255 / (inputSide - 1))
                p[3] = 255
            }
        }
        return buffer
    }

    private static func selfCheckReference(of model: MLModel) -> [Float]? {
        guard let custom = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String],
              let json = custom["selfcheck_embedding"]?.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode([Float].self, from: json)
    }
}
