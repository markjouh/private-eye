import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import Vision

struct Detection: Identifiable {
    let id = UUID()
    let label: String
    let confidence: Float
    /// Normalized to the camera frame, origin top-left.
    let box: CGRect
    /// Meters from the phone, measured by LiDAR; nil without a reading or beyond its range.
    var distance: Float?
}

/// YOLOE-26m (Core ML, fixed vocabulary baked in by tools/export_yoloe.py).
///
/// The model is NMS-free: it emits up to 300 rows of [x1, y1, x2, y2, confidence, class, mask coefficients…]
/// in input-pixel coordinates. The frame is stretched to the model input (which shares the camera's 3:4
/// aspect), so dividing by the input size gives frame-normalized boxes. A second output holds the mask
/// prototypes that the coefficients combine into each object's shape.
final class ObjectDetector {
    /// Boxes at or above this are worth drawing; weaker ones are still returned for safety checks.
    static let displayConfidence: Float = 0.35
    var confidenceThreshold: Float = 0.25
    private(set) var lastInferenceMs = 0.0
    /// The shapes of the drawn objects in the frame last given to `detect`, shaded into one small
    /// image that covers the whole frame; nil when there is nothing to draw. One image per frame,
    /// kept here rather than on each `Detection`, because detections are copied and filtered freely.
    private(set) var lastMask: CGImage?
    /// Time spent building `lastMask`, on top of `lastInferenceMs`.
    private(set) var lastMaskMs = 0.0

    private let request: VNCoreMLRequest
    private let labels: [String]
    private let inputSize: CGSize
    private let shader = MaskShader()

    /// Loads the detector bundled with the app.
    convenience init() throws {
        guard let url = Bundle.main.url(forResource: "yoloe26m", withExtension: "mlmodelc") else {
            throw LLMError("yoloe26m.mlmodelc missing from bundle")
        }
        guard let labelsURL = Bundle.main.url(forResource: "yoloe_labels", withExtension: "json") else {
            throw LLMError("yoloe_labels.json missing from bundle")
        }
        try self.init(compiledModel: url, labels: labelsURL)
    }

    init(compiledModel url: URL, labels labelsURL: URL) throws {
        labels = try JSONDecoder().decode([String].self, from: Data(contentsOf: labelsURL))

        let config = MLModelConfiguration()
        config.computeUnits = .all
        let model = try MLModel(contentsOf: url, configuration: config)
        let constraint = model.modelDescription.inputDescriptionsByName.values.first?.imageConstraint
        inputSize = CGSize(width: constraint?.pixelsWide ?? 480, height: constraint?.pixelsHigh ?? 640)
        request = VNCoreMLRequest(model: try VNCoreMLModel(for: model))
        request.imageCropAndScaleOption = .scaleFill
    }

    /// Runs synchronously on the calling thread.
    func detect(in pixelBuffer: CVPixelBuffer) -> [Detection] {
        lastMask = nil
        let start = Date()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        do { try handler.perform([request]) } catch { return [] }
        lastInferenceMs = Date().timeIntervalSince(start) * 1000

        // Two outputs with generated names, told apart by rank: detections [1, 300, 6 + 32] and mask
        // prototypes [1, 32, H, W].
        let arrays = (request.results as? [VNCoreMLFeatureValueObservation])?.compactMap { $0.featureValue.multiArrayValue }
        guard let out = arrays?.first(where: { $0.shape.count == 3 }) else { return [] }
        let rows = out.shape[1].intValue
        let cols = out.shape[2].intValue
        guard cols >= 6 else { return [] }
        // Core ML may pad rows, so step by the array's strides rather than its shape.
        let rowStride = out.strides[1].intValue
        let colStride = out.strides[2].intValue

        var found: [(detection: Detection, row: Int)] = []
        func read<T: BinaryFloatingPoint>(_ p: UnsafeMutablePointer<T>) {
            for r in 0..<rows {
                let o = r * rowStride
                func value(_ c: Int) -> Float { Float(p[o + c * colStride]) }
                let conf = value(4)
                guard conf >= confidenceThreshold else { continue }
                let cls = Int(value(5).rounded())
                guard cls >= 0, cls < labels.count else { continue }
                let x1 = CGFloat(value(0)) / inputSize.width
                let y1 = CGFloat(value(1)) / inputSize.height
                let x2 = CGFloat(value(2)) / inputSize.width
                let y2 = CGFloat(value(3)) / inputSize.height
                let box = CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
                    .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                guard !box.isNull, box.width > 0.01, box.height > 0.01 else { continue }
                found.append((Detection(label: labels[cls], confidence: conf, box: box), r))
            }
        }
        switch out.dataType {
        case .float32: read(out.dataPointer.assumingMemoryBound(to: Float.self))
        case .float16: read(out.dataPointer.assumingMemoryBound(to: Float16.self))
        case .double: read(out.dataPointer.assumingMemoryBound(to: Double.self))
        default: return []
        }
        found.sort { $0.detection.confidence > $1.detection.confidence }
        // The model ranks every (box, label) pair, so one outline can come back several times under
        // different labels ("jacket", "blanket", "towel"). Keep the most confident label for each.
        var unique: [(detection: Detection, row: Int)] = []
        for candidate in found where !unique.contains(where: { Self.overlap($0.detection.box, candidate.detection.box) > 0.9 }) {
            unique.append(candidate)
        }
        found = unique

        if let prototypes = arrays?.first(where: { $0.shape.count == 4 }) {
            let maskStart = Date()
            let drawn = found.prefix { $0.detection.confidence >= Self.displayConfidence }.prefix(MaskShader.maxObjects)
            lastMask = shader.shade(Array(drawn), output: out, prototypes: prototypes)
            lastMaskMs = Date().timeIntervalSince(maskStart) * 1000
        }
        return found.map(\.detection)
    }

    /// Intersection over union of two boxes.
    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let shared = a.intersection(b)
        guard !shared.isNull else { return 0 }
        let area = shared.width * shared.height
        return area / (a.width * a.height + b.width * b.height - area)
    }
}
