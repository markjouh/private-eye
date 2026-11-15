import CoreGraphics
import Foundation

/// Measures the yes/no check a model-judged search rests on: one frame, one condition, how sure the model
/// is that it holds (`LLMEngine.yesProbability`).
///
/// `--batch file` has one tab-separated line per check, `image  condition  [truth]`, with truth
/// "yes" or "no" (blank: not marked). Each is asked at every `--side`, with the app's question
/// wording or `--template "… {} …"`. The summary gives, for a range of bars, how often a frame where
/// the condition does not hold would pass (a false alert in the making) and how often one where it
/// does would fail (a late alert). `--out file` writes `image  condition  truth  probability` for
/// the last side run. `--template` may be given more than once: the first is the one marked, and
/// each of the others adds a probability column to `--out`, for comparing wordings on the same frames.
/// `--suffix` replaces the instruction after the question ("" for none).
func runCheckMode(_ arguments: [String]) {
    var args = arguments
    guard args.count >= 3 else {
        print("usage: eyes-cli check <model.gguf> <mmproj.gguf> [--side 384,512,768] [--template \"Is this true right now: {}?\"] [--out results.tsv] --batch checks.tsv | <image> <condition> ...")
        return
    }
    let modelPath = args.removeFirst()
    let mmprojPath = args.removeFirst()
    var sides = [VLMService.imageMaxSide]
    var templates: [String] = []
    var batchPath: String?
    var outPath: String?
    var suffix = AnswerStyle.closeUpSuffix
    while let first = args.first, first.hasPrefix("--"), args.count >= 2 {
        args.removeFirst()
        let value = args.removeFirst()
        switch first {
        case "--side": sides = value.split(separator: ",").compactMap { Int($0) }
        case "--template": templates.append(value)
        case "--suffix": suffix = value
        case "--batch": batchPath = value
        case "--out": outPath = value
        default: print("unknown flag \(first)"); return
        }
    }
    struct Item {
        var image: String
        var condition: String
        var truth: Bool?
    }
    var items: [Item] = []
    if let batchPath {
        guard let text = try? String(contentsOfFile: batchPath, encoding: .utf8) else { print("could not read \(batchPath)"); return }
        let folder = URL(fileURLWithPath: batchPath).deletingLastPathComponent()
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 2 else { continue }
            let truth = fields.count > 2 ? ["yes": true, "no": false][fields[2].lowercased()] : nil
            items.append(Item(image: URL(fileURLWithPath: fields[0], relativeTo: folder).path, condition: fields[1], truth: truth))
        }
    }
    while args.count >= 2 { items.append(Item(image: args.removeFirst(), condition: args.removeFirst())) }
    guard !items.isEmpty, !sides.isEmpty else { print("nothing to check"); return }
    let template = templates.first ?? WatchCondition.template

    let engine: LLMEngine
    do { engine = try LLMEngine(modelPath: modelPath, mmprojPath: mmprojPath) } catch { print("load failed: \(error)"); return }

    var results = ""
    for side in sides {
        var scored: [(truth: Bool, p: Float)] = []
        var tokens = 0.0, ms = 0.0, asked = 0
        results = ""
        print("\n== longer side \(side), \"\(template)\" ==")
        for item in items {
            guard let condition = WatchCondition(item.condition), let cg = loadCGImage(item.image),
                  let image = RGBImage(cgImage: cg, maxSide: side)
            else { print("could not read \(item.image)"); continue }
            do {
                let began = Date()
                try engine.ingest(image: image)
                let p = try engine.yesProbability(question: condition.question(template: template), suffix: suffix)
                ms += Date().timeIntervalSince(began) * 1000
                tokens += Double(engine.stats.imageTokens + engine.stats.questionTokens)
                asked += 1
                if let truth = item.truth { scored.append((truth, p)) }
                let name = (item.image as NSString).lastPathComponent
                let mark = item.truth.map { ($0 == (p >= 0.5)) ? "" : "   <-- wrong side of 0.5, truth \($0 ? "yes" : "no")" } ?? ""
                if items.count <= 40 || !mark.isEmpty { print(String(format: "%.3f  %@  %@%@", p, name, item.condition, mark)) }
                // After the probability: the same counted against "no" alone, and how much of the next word was yes or no.
                var row = "\(item.image)\t\(item.condition)\t\(item.truth.map { $0 ? "yes" : "no" } ?? "")\t\(String(format: "%.4f\t%.4f\t%.4f", p, engine.yesAgainstNo, engine.yesOrNo))"
                for other in templates.dropFirst() {
                    try engine.ingest(image: image)
                    row += String(format: "\t%.4f", try engine.yesProbability(question: condition.question(template: other), suffix: suffix))
                }
                results += row + "\n"
            } catch {
                print("error on \(item.image): \(error)")
            }
        }
        guard asked > 0 else { continue }
        print(String(format: "%d checks, mean %.0f tokens, %.0f ms each", asked, tokens / Double(asked), ms / Double(asked)))
        let positives = scored.filter(\.truth), negatives = scored.filter { !$0.truth }
        guard !positives.isEmpty || !negatives.isEmpty else { continue }
        print("bar     passes when false     fails when true")
        for bar: Float in [0.5, 0.7, 0.8, 0.9, 0.95, 0.99] {
            let falseYes = negatives.filter { $0.p >= bar }.count, missed = positives.filter { $0.p < bar }.count
            print(String(format: "%.2f    %3d of %-3d (%4.1f%%)     %3d of %-3d (%4.1f%%)", bar,
                         falseYes, negatives.count, 100 * Double(falseYes) / Double(max(negatives.count, 1)),
                         missed, positives.count, 100 * Double(missed) / Double(max(positives.count, 1))))
        }
    }
    if let outPath {
        do { try results.write(toFile: outPath, atomically: true, encoding: .utf8) } catch { print("could not write \(outPath): \(error)") }
    }
}
