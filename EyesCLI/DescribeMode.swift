import CoreGraphics
import Foundation

/// The tap description, end to end on photos, exactly as the app asks for it: the model says whether
/// the frame is a close-up of one thing; if so it names it and reads its label, and if not, the app
/// says who is there (from the detector) and the model describes the scene.
///   eyes-cli describe <yoloe26m.mlpackage> <yoloe_labels.json> <model.gguf> <mmproj.gguf> [--suffix S] <image> ...
/// `--suffix` tries another instruction in place of `AnswerStyle`'s (the reply is then unfiltered).
func runDescribeMode(_ args: [String]) {
    guard args.count >= 5 else {
        print("usage: eyes-cli describe <yoloe26m.mlpackage> <yoloe_labels.json> <model.gguf> <mmproj.gguf> [--suffix S] <image> ...")
        return
    }
    do {
        let detector = try ObjectDetector(compiledModel: compileModel(args[0]), labels: URL(fileURLWithPath: args[1]))
        let engine = try LLMEngine(modelPath: args[2], mmprojPath: args[3])
        var images = Array(args.dropFirst(4))
        if images.first == "--suffix", images.count >= 2 {
            engine.questionSuffix = images[1]
            images.removeFirst(2)
        }
        var words: [Int] = []
        var checkMs: [Double] = []
        for path in images {
            guard let cg = loadCGImage(path), let buffer = PixelWarp.pixelBuffer(from: cg),
                  let image = RGBImage(cgImage: cg, maxSide: 768) else { continue }
            let known = SceneDescription.known(detections: detector.detect(in: buffer), faces: [])
            try engine.ingest(image: image)
            // As in the app: one thing held up is named and read; anything else is a scene.
            let spoken: String
            let asked = Date()
            let closeUp = try engine.isCloseUp()
            checkMs.append(Date().timeIntervalSince(asked) * 1000)
            if closeUp {
                spoken = try engine.answer(question: AnswerStyle.objectQuestion)
            } else {
                let described = try engine.answer(question: "What is in front of me?", as: known.isEmpty ? nil : .describeThings)
                spoken = known.isEmpty ? described : "\(known) \(described)"
            }
            words.append(spoken.split(separator: " ").count)
            print("[\((path as NSString).lastPathComponent)] \(closeUp ? "ONE THING" : "scene    ") \(spoken)")
        }
        if !words.isEmpty {
            print(String(format: "%d descriptions: mean %.1f words, max %d; the close-up check took a median %.0f ms and copied %.0f MB of state", words.count,
                         Double(words.reduce(0, +)) / Double(words.count), words.max() ?? 0, checkMs.sorted()[checkMs.count / 2],
                         Double(engine.stateBytes) / 1_000_000))
        }
    } catch {
        print("describe failed: \(error)")
    }
}
