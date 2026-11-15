import CoreGraphics
import Foundation

/// Runs the video features the way the app does, for minutes on end, to see that memory holds
/// level: every frame of a clip (looped) goes through the scene signature, the keyframe buffer and
/// a watch; the model is asked whenever the watch wants a check; and every twenty seconds a
/// question about the recent past is answered from the kept frames. A watch that fires is started
/// again. The clock is the clip's, so ten minutes take as long as the Mac needs.
///
///   eyes-cli soak <model.gguf> <mmproj.gguf> [--minutes 10] <clip> <condition> <question>
func runSoakMode(_ arguments: [String]) {
    var args = arguments
    guard args.count >= 5 else {
        print("usage: eyes-cli soak <model.gguf> <mmproj.gguf> [--minutes 10] <clip> <condition> <question>")
        return
    }
    let modelPath = args.removeFirst()
    let mmprojPath = args.removeFirst()
    var minutes = 10.0
    if args.first == "--minutes", args.count >= 2 {
        minutes = Double(args[1]) ?? minutes
        args.removeFirst(2)
    }
    guard args.count >= 3, let clip = VideoClip(path: args[0]), let condition = WatchCondition(args[1]) else {
        print("could not open the clip, or no condition")
        return
    }
    let question = args[2]
    let engine: LLMEngine
    do { engine = try LLMEngine(modelPath: modelPath, mmprojPath: mmprojPath) } catch { print("load failed: \(error)"); return }

    let buffer = KeyframeBuffer()
    let policy = WatchMonitor.Policy.calibrated(forModel: engine.modelFile)
    var monitor = WatchMonitor(condition)
    monitor.policy = policy
    var checks = 0, alerts = 0, questions = 0, kept = 0
    var nextQuestion = 20.0, nextReport = 60.0
    var readings: [Double] = []
    print("minute   memory MB   checks   frames kept   questions   alerts")
    // Ten frames a second, counted in whole frames so that the last minute is reported too.
    for step in 0...Int((minutes * 600).rounded()) {
        let time = Double(step) / 10
        autoreleasepool {
            guard let cg = clip.frame(at: time.truncatingRemainder(dividingBy: clip.duration)),
                  let frame = PixelWarp.pixelBuffer(from: cg), let signature = SceneSignature(frame)
            else { return }
            let added = buffer.offer(at: time, signature: signature) {
                RGBImage(pixelBuffer: frame, maxSide: KeyframeBuffer.side)
            } readable: {
                RGBImage(pixelBuffer: frame, maxSide: KeyframeBuffer.readingSide)
            }
            if added { kept += 1 }
            if monitor.wantsCheck(at: time, signature: signature, heat: .normal), let image = RGBImage(cgImage: cg, maxSide: VLMService.imageMaxSide) {
                monitor.began(at: time, signature: signature)
                checks += 1
                if (try? engine.ingest(image: image)) != nil, let sure = try? engine.yesProbability(question: condition.question()) {
                    if monitor.answered(sure) != .nothing {
                        alerts += 1
                        monitor = WatchMonitor(condition)
                        monitor.policy = policy
                    }
                } else {
                    monitor.abandoned()
                }
            }
            if time >= nextQuestion, let current = RGBImage(pixelBuffer: frame, maxSide: KeyframeBuffer.side) {
                nextQuestion += 20
                if (try? engine.ingest(frames: buffer.clip(at: time, current: current))) != nil, (try? engine.answer(question: Recall.forTheModel(question), as: AnswerStyle.kind(of: question))) != nil {
                    questions += 1
                }
            }
        }
        if time >= nextReport {
            nextReport += 60
            readings.append(memoryFootprintMB())
            print(String(format: "%6.0f   %9.0f   %6d   %11d   %9d   %6d", time / 60, readings.last!, checks, kept, questions, alerts))
        }
    }
    if let first = readings.first, let last = readings.last, readings.count > 1 {
        print(String(format: "memory after the first minute %.0f MB, after the last %.0f MB: %+.0f MB over %d minutes", first, last, last - first, readings.count - 1))
    }
}
