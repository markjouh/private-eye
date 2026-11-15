import AVFoundation
import CoreGraphics
import Foundation

/// Runs LFM3-VL on questions about short clips, through the engine code the app uses for several
/// frames at once (`LLMEngine.ingest(frames:)`).
///
/// A clip is a video file. The model is shown `--frames` frames spread evenly over the `--window`
/// seconds before the moment the question is asked (the end of the clip unless the batch says
/// otherwise), the last of them at that moment, each scaled so its longer side is `--side`.
/// `--frames` and `--side` take lists ("8,16"): every combination is run and compared at the end,
/// which is how to find the fewest tokens that still answer correctly.
///
/// Questions come from the command line, or from `--batch file`: one tab-separated line each,
/// `clip  question  [expected  [at]]`. `expected` is "yes" or "no" (the reply's first word must
/// match) or words the reply must contain; left empty, the reply is not marked. `at` is the moment
/// of the question, in seconds into the clip. Clip paths are relative to the batch file.
/// `--layout` prints what was put in front of the first question, to check against llama.cpp's own
/// (`llama-mtmd-cli --video … -v`).
///
/// `--keyframes` shows the model what the app would: the clip is watched at ten frames a second up
/// to the moment of the question, `KeyframeBuffer` keeps the frames it would have kept, and the
/// frame at that moment goes last. `--frames` is then ignored.
///
/// The question is put to the model as the app puts it (`Recall.forTheModel`); `--prefix "…"` replaces
/// the words in front of it ("" for the question alone). The style of the answer follows the
/// question alone either way.
///
/// `--read` answers nothing with the model: it prints the text the recogniser finds in the frame at
/// the moment of the question and in the larger copies of the kept frames, newest first, which is
/// how "what did that sign say?" is answered once the sign is out of view.
func runVideoMode(_ arguments: [String]) {
    var args = arguments
    guard args.count >= 4 else {
        print("usage: eyes-cli video <model.gguf> <mmproj.gguf> [--frames 8,16] [--side 256,384] [--window 30] [--system S] [--suffix S] [--max-tokens N] [--prefix P] [--layout] [--keyframes] [--batch clips.tsv] <clip> <question> ...")
        return
    }
    let modelPath = args.removeFirst()
    let mmprojPath = args.removeFirst()
    var frameCounts = [8]
    var sides = [KeyframeBuffer.side]
    var window = 30.0
    var system: String?
    var suffix: String?
    var maxTokens: Int?
    var showLayout = false
    var useKeyframes = false
    var readText = false
    var prefix: String?
    var batchPath: String?
    func numbers(_ list: String) -> [Int] { list.split(separator: ",").compactMap { Int($0) }.filter { $0 > 0 } }
    while let first = args.first, first.hasPrefix("--") {
        args.removeFirst()
        if first == "--layout" {
            showLayout = true
            continue
        }
        if first == "--keyframes" {
            useKeyframes = true
            continue
        }
        if first == "--read" {
            readText = true
            continue
        }
        guard !args.isEmpty else { print("\(first) needs a value"); return }
        let value = args.removeFirst()
        switch first {
        case "--frames": frameCounts = numbers(value)
        case "--side": sides = numbers(value)
        case "--window": window = Double(value) ?? window
        case "--system": system = value
        case "--suffix": suffix = value
        case "--max-tokens": maxTokens = Int(value)
        case "--prefix": prefix = value
        case "--batch": batchPath = value
        default: print("unknown flag \(first)"); return
        }
    }
    guard !frameCounts.isEmpty, !sides.isEmpty else { print("--frames and --side need numbers"); return }

    struct Item {
        var clip: String
        var question: String
        var expected = ""
        var at: Double?
    }
    var items: [Item] = []
    if let batchPath {
        guard let text = try? String(contentsOfFile: batchPath, encoding: .utf8) else {
            print("could not read \(batchPath)")
            return
        }
        let folder = URL(fileURLWithPath: batchPath).deletingLastPathComponent()
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 2 else { continue }
            items.append(Item(clip: URL(fileURLWithPath: fields[0], relativeTo: folder).path, question: fields[1],
                              expected: fields.count > 2 ? fields[2] : "", at: fields.count > 3 ? Double(fields[3]) : nil))
        }
    }
    while args.count >= 2 {
        items.append(Item(clip: args.removeFirst(), question: args.removeFirst()))
    }
    guard !items.isEmpty else { print("nothing to ask") ; return }

    var clips: [String: VideoClip] = [:]
    for path in Set(items.map(\.clip)) {
        guard let clip = VideoClip(path: path) else {
            print("could not open \(path)")
            return
        }
        clips[path] = clip
    }

    if readText {
        for item in items {
            guard let clip = clips[item.clip] else { continue }
            let at = min(item.at ?? clip.duration, clip.duration)
            let buffer = KeyframeBuffer()
            _ = keptFrames(of: clip, at: at, side: KeyframeBuffer.side, buffer: buffer)
            var frames = clip.frame(at: at).flatMap(PixelWarp.pixelBuffer(from:)).map { [("now", $0)] } ?? []
            frames += buffer.readableFrames().enumerated().compactMap { index, image in image.pixelBuffer().map { ("kept frame \(index + 1), newest first", $0) } }
            print("\n[\((item.clip as NSString).lastPathComponent) at \(String(format: "%.1f", at)) s] \(item.question)")
            var found = false
            for (name, frame) in frames {
                guard let text = TextReader.spoken(TextReader.lines(in: frame)) else { continue }
                print("   read from \(name): \(text)")
                found = true
                break
            }
            if !found { print("   no text in the view now or in \(frames.count - 1) kept frames") }
        }
        return
    }

    let loadStart = Date()
    let engine: LLMEngine
    do {
        engine = try LLMEngine(modelPath: modelPath, mmprojPath: mmprojPath)
    } catch {
        print("load failed: \(error)")
        return
    }
    if let system { engine.systemPrompt = system }
    engine.questionSuffix = suffix
    print(String(format: "loaded in %.2f s", Date().timeIntervalSince(loadStart)))

    struct Tally {
        var asked = 0, marked = 0, correct = 0, failed = 0
        var tokens = 0.0, encodeMs = 0.0, prefillMs = 0.0, ttftMs = 0.0
    }
    var summary: [(label: String, tally: Tally)] = []
    for count in useKeyframes ? [0] : frameCounts {
        for side in sides {
            var tally = Tally()
            print("\n== \(useKeyframes ? "kept" : "\(count)") frames, longer side \(side) ==")
            for item in items {
                guard let clip = clips[item.clip] else { continue }
                let at = min(item.at ?? clip.duration, clip.duration)
                var from = max(0, at - window)
                var frames: [VideoFrame] = []
                if useKeyframes {
                    frames = keptFrames(of: clip, at: at, side: side)
                    from = at - (frames.last?.seconds ?? 0)
                } else {
                    // Evenly spread, the last one at the moment of the question.
                    let times = count == 1 ? [at] : (0..<count).map { from + (at - from) * Double($0) / Double(count - 1) }
                    for time in times {
                        guard let cg = clip.frame(at: time), let image = RGBImage(cgImage: cg, maxSide: side) else { break }
                        frames.append(VideoFrame(image: image, seconds: time - from))
                    }
                    if frames.count != times.count { frames = [] }
                }
                let name = (item.clip as NSString).lastPathComponent
                guard let size = frames.first?.image else {
                    print("\n[\(name)] could not read its frames")
                    tally.failed += 1
                    continue
                }
                do {
                    try engine.ingest(frames: frames)
                    if showLayout {
                        showLayout = false
                        print("layout: \(engine.videoLayout.replacingOccurrences(of: "\n", with: "\\n"))")
                    }
                    let style = suffix == nil ? "\(AnswerStyle.kind(of: item.question))" : "own suffix"
                    print(String(format: "\n[%@ %.1f to %.1f s, %d frames %dx%d, %@] Q: %@", name, from, at, frames.count, size.width, size.height, style, item.question))
                    let asked = prefix.map { $0 + item.question } ?? Recall.forTheModel(item.question)
                    let reply = try engine.answer(question: asked, as: suffix == nil ? AnswerStyle.kind(of: item.question) : nil, maxTokens: maxTokens)
                    var mark = ""
                    if !item.expected.isEmpty {
                        let right = matches(reply, item.expected)
                        tally.marked += 1
                        if right { tally.correct += 1 }
                        mark = right ? "   [right]" : "   [WRONG, expected: \(item.expected)]"
                    }
                    print("A: \(reply)\(mark)")
                    let s = engine.stats
                    print(String(format: "   %d tok: encode %.0f ms, prefill %.0f ms | question %d tok, first token %.0f ms | %d tok at %.1f tok/s",
                                 s.imageTokens, s.encodeMs, s.prefillMs, s.questionTokens, s.ttftMs, s.generatedTokens, s.tokensPerSecond))
                    tally.asked += 1
                    tally.tokens += Double(s.imageTokens)
                    tally.encodeMs += s.encodeMs
                    tally.prefillMs += s.prefillMs
                    tally.ttftMs += s.ttftMs
                } catch {
                    print("\n[\(name)] Q: \(item.question)\nerror: \(error)")
                    tally.failed += 1
                }
            }
            summary.append(("\(useKeyframes ? "kept" : "\(count)") x \(side)", tally))
        }
    }

    print("\nframes x side   right     tokens   encode ms   prefill ms   first token ms")
    for (label, t) in summary {
        let n = Double(max(t.asked, 1))
        let right = t.marked > 0 ? "\(t.correct)/\(t.marked)" : "-"
        print(label.padding(toLength: 16, withPad: " ", startingAt: 0) + right.padding(toLength: 10, withPad: " ", startingAt: 0)
              + String(format: "%6.0f   %9.0f   %10.0f   %14.0f", t.tokens / n, t.encodeMs / n, t.prefillMs / n, t.ttftMs / n)
              + (t.failed > 0 ? "   (\(t.failed) failed)" : ""))
    }
}

/// The clip the app would show the model for a question asked `at` seconds into `clip`: what
/// `KeyframeBuffer` kept while watching it at ten frames a second, then the frame at that moment.
func keptFrames(of clip: VideoClip, at: Double, side: Int, buffer: KeyframeBuffer = KeyframeBuffer()) -> [VideoFrame] {
    var time = max(0, at - 2 * KeyframeBuffer.seconds)
    while time < at - 0.05 {
        if let cg = clip.frame(at: time), let frame = PixelWarp.pixelBuffer(from: cg), let signature = SceneSignature(frame) {
            buffer.offer(at: time, signature: signature) {
                RGBImage(cgImage: cg, maxSide: side)
            } readable: {
                RGBImage(cgImage: cg, maxSide: KeyframeBuffer.readingSide)
            }
        }
        time += 0.1
    }
    guard let cg = clip.frame(at: at), let current = RGBImage(cgImage: cg, maxSide: side) else { return [] }
    return buffer.clip(at: at, current: current)
}

/// Whether `reply` is what was expected: for "yes" and "no" its first word, otherwise the words anywhere in it.
private func matches(_ reply: String, _ expected: String) -> Bool {
    let want = expected.lowercased()
    let got = reply.lowercased()
    if want == "yes" || want == "no" {
        return got.split(whereSeparator: { !$0.isLetter }).first.map(String.init) == want
    }
    return got.contains(want)
}

/// A video file that frames can be taken from at any moment, upright as it would be played.
final class VideoClip {
    let duration: Double
    private let generator: AVAssetImageGenerator

    init?(path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let seconds = try? wait({ try await asset.load(.duration).seconds }), seconds.isFinite, seconds > 0 else { return nil }
        duration = seconds
        generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        // The model is shown far less than this; it only spares decoding 4K frames in full.
        generator.maximumSize = CGSize(width: 1024, height: 1024)
    }

    func frame(at seconds: Double) -> CGImage? {
        // The very end of a clip has no frame to show; step back to the last one.
        for back in [0, 0.05, 0.2] {
            let time = CMTime(seconds: max(0, seconds - back), preferredTimescale: 600)
            if let image = try? wait({ try await self.generator.image(at: time).image }) { return image }
        }
        return nil
    }
}

/// Runs async work to completion from the tool's synchronous code.
func wait<T>(_ work: @escaping () async throws -> T) throws -> T {
    let box = ResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        do { box.result = .success(try await work()) } catch { box.result = .failure(error) }
        done.signal()
    }
    done.wait()
    return try box.result!.get()
}

private final class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}
