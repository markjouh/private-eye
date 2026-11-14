import CoreGraphics
import Foundation

/// Runs LFM3-VL on image/question pairs with the same engine code as the app.
///
/// Pairs come from the command line, or from `--batch file`: one tab-separated line per pair,
/// `tag  image  question  [unused  [suffix]]`. Without a suffix (`--suffix`, or the batch column) the
/// reply is styled as in the app: `AnswerStyle` picks the instruction and filters the text. With one,
/// the reply is the model's own words, which is how to try prompts and to see what the filter changes.
/// `--out file` writes `tag  words  answer` per pair for comparing runs.
func runAskMode(_ arguments: [String]) {
    var args = arguments
    guard args.count >= 4 else {
        print("usage: eyes-cli ask <model.gguf> <mmproj.gguf> [--think] [--side N] [--system S] [--suffix S] [--max-tokens N] [--batch pairs.tsv] [--out results.tsv] <image> <question> ...")
        return
    }
    let modelPath = args.removeFirst()
    let mmprojPath = args.removeFirst()
    var think = false
    var side = 768
    var system: String?
    var suffix: String?
    var maxTokens: Int?
    var batchPath: String?
    var outPath: String?
    while let first = args.first, first.hasPrefix("--") {
        args.removeFirst()
        switch first {
        case "--think": think = true
        case "--side": side = Int(args.removeFirst()) ?? side
        case "--system": system = args.removeFirst()
        case "--suffix": suffix = args.removeFirst()
        case "--max-tokens": maxTokens = Int(args.removeFirst())
        case "--batch": batchPath = args.removeFirst()
        case "--out": outPath = args.removeFirst()
        default: print("unknown flag \(first)"); return
        }
    }

    struct Pair {
        var tag = ""
        var image: String
        var question: String
        var suffix: String?
    }
    var pairs: [Pair] = []
    if let batchPath {
        guard let text = try? String(contentsOfFile: batchPath, encoding: .utf8) else {
            print("could not read \(batchPath)")
            return
        }
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3 else { continue }
            // "\n" in a suffix column stands for a line break, so few-shot suffixes fit on one line.
            // The fourth column is ignored: it held context lines when the model was still given them.
            pairs.append(Pair(tag: fields[0], image: fields[1], question: fields[2],
                              suffix: fields.count > 4 ? fields[4].replacingOccurrences(of: "\\n", with: "\n") : suffix))
        }
    }
    while args.count >= 2 {
        pairs.append(Pair(image: args.removeFirst(), question: args.removeFirst(), suffix: suffix))
    }

    let loadStart = Date()
    let engine: LLMEngine
    do {
        engine = try LLMEngine(modelPath: modelPath, mmprojPath: mmprojPath)
    } catch {
        print("load failed: \(error)")
        return
    }
    engine.thinking = think
    if let system { engine.systemPrompt = system }
    print(String(format: "loaded in %.2f s", Date().timeIntervalSince(loadStart)))

    var wordCounts: [Int] = []
    var results = ""
    for pair in pairs {
        guard let cg = loadCGImage(pair.image), let image = RGBImage(cgImage: cg, maxSide: side) else {
            print("could not read \(pair.image)")
            continue
        }
        do {
            engine.questionSuffix = pair.suffix
            try engine.ingest(image: image)
            let style = pair.suffix == nil ? "\(AnswerStyle.kind(of: pair.question))" : "own suffix"
            print("\n[\(pair.tag.isEmpty ? "" : pair.tag + " ")\((pair.image as NSString).lastPathComponent) \(image.width)x\(image.height), \(style)] Q: \(pair.question)")
            print("A: ", terminator: "")
            let onText: (String) -> Bool = { text in
                print(text, terminator: "")
                fflush(stdout)
                return true
            }
            let reply = try engine.answer(question: pair.question, maxTokens: maxTokens, onText: onText)
            let words = reply.split(whereSeparator: \.isWhitespace).count
            wordCounts.append(words)
            results += "\(pair.tag)\t\(words)\t\(reply.replacingOccurrences(of: "\n", with: " "))\n"
            let s = engine.stats
            print(String(format: "\n   %d words | image %d tok in %.0f ms | question %d tok, ttft %.0f ms | %d tok at %.1f tok/s",
                         words, s.imageTokens, s.imageMs, s.questionTokens, s.ttftMs, s.generatedTokens, s.tokensPerSecond))
        } catch {
            print("error: \(error)")
        }
    }
    if wordCounts.count > 1 {
        print(String(format: "\n%d answers: mean %.1f words, max %d", wordCounts.count,
                     Double(wordCounts.reduce(0, +)) / Double(wordCounts.count), wordCounts.max() ?? 0))
    }
    if let outPath {
        do { try results.write(toFile: outPath, atomically: true, encoding: .utf8) } catch { print("could not write \(outPath): \(error)") }
    }
}
