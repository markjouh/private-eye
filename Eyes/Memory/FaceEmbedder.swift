import CoreML
import CoreVideo
import Foundation
import Vision

/// A face found in a frame, with the identity embedding used to recognise it.
struct FaceObservation {
    /// Normalized to the frame, origin top-left.
    let box: CGRect
    /// Unit-length ArcFace embedding; cosine similarity between two is their dot product.
    let embedding: [Float]
    /// Width of the face in frame pixels. Small faces give unreliable embeddings.
    let pixelWidth: CGFloat
    /// Head turn away from the camera in radians (0 = facing it), when Vision reports it.
    let yaw: CGFloat?
    /// The aligned 112x112 crop the embedding was computed from.
    let crop: CVPixelBuffer
    /// How sure Vision is that this is a face at all, 0...1.
    let confidence: Float
    /// Vision's capture quality, 0...1 (sharp, lit, frontal faces score high; things that only
    /// resemble a face score low). Only measured when asked for.
    let quality: Float?
}

/// Finds faces and turns each into an identity embedding.
///
/// Pipeline: Vision face landmarks -> five reference points (eyes, nose, mouth corners) -> similarity
/// transform onto ArcFace's canonical 112x112 layout -> ArcFace ResNet-50 (Core ML).
/// ArcFace only works on faces aligned this way, so the alignment is as important as the network.
final class FaceEmbedder {
    /// Faces narrower than this many pixels are skipped: too little detail to identify anyone. At a
    /// median of 35 px, identification on LFW was still 98 to 100% correct with no stranger named;
    /// below about 28 px Vision stops finding the face at all.
    var minFaceWidth: CGFloat = 30
    /// Embeds each face together with its mirror image. A face and its mirror are the same person, so
    /// combining the two evens out pose and lighting: small but consistent gains on LFW, and no rise
    /// in false matches.
    var mirrorAugment = true

    private let model: MLModel
    private let landmarksRequest = VNDetectFaceLandmarksRequest()
    private let qualityRequest = VNDetectFaceCaptureQualityRequest()

    /// Where the five reference points sit in the 112x112 input ArcFace was trained on
    /// (image-left eye, image-right eye, nose tip, image-left mouth corner, image-right mouth corner).
    static let template: [CGPoint] = [
        CGPoint(x: 38.2946, y: 51.6963), CGPoint(x: 73.5318, y: 51.5014), CGPoint(x: 56.0252, y: 71.7366),
        CGPoint(x: 41.5493, y: 92.3655), CGPoint(x: 70.7299, y: 92.2041),
    ]

    convenience init() throws {
        guard let url = Bundle.main.url(forResource: "arcface_r50", withExtension: "mlmodelc") else {
            throw LLMError("arcface_r50.mlmodelc missing from bundle")
        }
        try self.init(compiledModel: url)
    }

    init(compiledModel url: URL) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .all
        model = try MLModel(contentsOf: url, configuration: config)
    }

    /// All usable faces in a BGRA frame, largest first. `measuringQuality` adds Vision's capture-quality
    /// score to each, at the cost of a second pass; enrolment needs it, live recognition does not.
    func faces(in frame: CVPixelBuffer, limit: Int = 4, measuringQuality: Bool = false) -> [FaceObservation] {
        let handler = VNImageRequestHandler(cvPixelBuffer: frame, orientation: .up)
        guard (try? handler.perform([landmarksRequest])) != nil, let found = landmarksRequest.results else { return [] }
        let size = CGSize(width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame))
        var quality: [UUID: Float] = [:]
        if measuringQuality, !found.isEmpty {
            qualityRequest.inputFaceObservations = found
            if (try? handler.perform([qualityRequest])) != nil {
                for scored in qualityRequest.results ?? [] { quality[scored.uuid] = scored.faceCaptureQuality }
            }
        }

        var faces: [FaceObservation] = []
        for face in found.sorted(by: { $0.boundingBox.width > $1.boundingBox.width }).prefix(limit) {
            let pixelWidth = face.boundingBox.width * size.width
            guard pixelWidth >= minFaceWidth,
                  let points = Self.referencePoints(of: face, imageSize: size),
                  let toTemplate = Self.similarity(from: points, to: Self.template),
                  let crop = PixelWarp.warp(frame, toSource: toTemplate.inverted(), width: 112, height: 112),
                  let embedding = embed(aligned: crop)
            else { continue }
            // Vision's box has its origin at the bottom-left; flip it.
            let b = face.boundingBox
            let box = CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
            faces.append(FaceObservation(box: box, embedding: embedding, pixelWidth: pixelWidth,
                                         yaw: face.yaw.map { CGFloat(truncating: $0) }, crop: crop,
                                         confidence: face.confidence, quality: quality[face.uuid]))
        }
        return faces
    }

    /// Embeds a face that is already a 112x112 aligned crop.
    func embed(aligned crop: CVPixelBuffer) -> [Float]? {
        guard let straight = raw(crop) else { return nil }
        guard mirrorAugment,
              let flipped = PixelWarp.warp(crop, toSource: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 111, ty: 0), width: 112, height: 112),
              let mirrored = raw(flipped)
        else { return PixelWarp.unit(straight) }
        return PixelWarp.unit(zip(straight, mirrored).map { $0 + $1 })
    }

    private func raw(_ crop: CVPixelBuffer) -> [Float]? {
        guard let input = try? MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: crop)]),
              let output = try? model.prediction(from: input),
              let array = output.featureValue(for: "embedding")?.multiArrayValue
        else { return nil }
        return (0..<array.count).map { array[$0].floatValue }
    }

    /// The aligned 112x112 crops of the faces in a frame, largest first, for inspecting the alignment.
    func debugCrops(in frame: CVPixelBuffer) -> [CVPixelBuffer] {
        let handler = VNImageRequestHandler(cvPixelBuffer: frame, orientation: .up)
        guard (try? handler.perform([landmarksRequest])) != nil, let found = landmarksRequest.results else { return [] }
        let size = CGSize(width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame))
        return found.sorted { $0.boundingBox.width > $1.boundingBox.width }.compactMap { face in
            guard let points = Self.referencePoints(of: face, imageSize: size),
                  let toTemplate = Self.similarity(from: points, to: Self.template)
            else { return nil }
            return PixelWarp.warp(frame, toSource: toTemplate.inverted(), width: 112, height: 112)
        }
    }

    // MARK: Geometry

    /// The five ArcFace reference points for a Vision face, in frame pixels with a top-left origin.
    static func referencePoints(of face: VNFaceObservation, imageSize: CGSize) -> [CGPoint]? {
        guard let marks = face.landmarks,
              let pupilA = marks.leftPupil?.pointsInImage(imageSize: imageSize).first,
              let pupilB = marks.rightPupil?.pointsInImage(imageSize: imageSize).first,
              let nose = marks.nose?.pointsInImage(imageSize: imageSize), !nose.isEmpty,
              let lips = marks.outerLips?.pointsInImage(imageSize: imageSize), lips.count >= 4
        else { return nil }
        func flip(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: imageSize.height - p.y) }

        // "Left" and "right" here mean left and right in the image, whichever eye that is.
        let eyes = [flip(pupilA), flip(pupilB)].sorted { $0.x < $1.x }
        let axis = CGVector(dx: eyes[1].x - eyes[0].x, dy: eyes[1].y - eyes[0].y)
        // Mouth corners are the lip points farthest apart along the line through the eyes, which
        // stays correct when the head is tilted.
        let lipPoints = lips.map(flip)
        func along(_ p: CGPoint) -> CGFloat { p.x * axis.dx + p.y * axis.dy }
        guard let mouthLeft = lipPoints.min(by: { along($0) < along($1) }),
              let mouthRight = lipPoints.max(by: { along($0) < along($1) })
        else { return nil }
        // Nose tip: Vision outlines the nose; the tip sits at the centre of that outline.
        let nosePoints = nose.map(flip)
        let tip = CGPoint(x: nosePoints.map(\.x).reduce(0, +) / CGFloat(nosePoints.count),
                          y: nosePoints.map(\.y).reduce(0, +) / CGFloat(nosePoints.count))
        return [eyes[0], eyes[1], tip, mouthLeft, mouthRight]
    }

    /// Least-squares rotation + uniform scale + translation taking `from` onto `to`.
    static func similarity(from: [CGPoint], to: [CGPoint]) -> CGAffineTransform? {
        guard from.count == to.count, from.count >= 2 else { return nil }
        let n = CGFloat(from.count)
        let mf = CGPoint(x: from.map(\.x).reduce(0, +) / n, y: from.map(\.y).reduce(0, +) / n)
        let mt = CGPoint(x: to.map(\.x).reduce(0, +) / n, y: to.map(\.y).reduce(0, +) / n)
        var dot: CGFloat = 0, cross: CGFloat = 0, norm: CGFloat = 0
        for (p, q) in zip(from, to) {
            let px = p.x - mf.x, py = p.y - mf.y, qx = q.x - mt.x, qy = q.y - mt.y
            dot += px * qx + py * qy
            cross += px * qy - py * qx
            norm += px * px + py * py
        }
        guard norm > 1e-6 else { return nil }
        let a = dot / norm, b = cross / norm
        // (x, y) -> (a x - b y + tx, b x + a y + ty)
        return CGAffineTransform(a: a, b: b, c: -b, d: a,
                                 tx: mt.x - (a * mf.x - b * mf.y), ty: mt.y - (b * mf.x + a * mf.y))
    }
}
