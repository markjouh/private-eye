import CoreGraphics
import Foundation

/// Replays a model-judged search on clips: the app's own decisions (`WatchMonitor`, `SceneSignature`) and the
/// real model, with the clock simulated so a two-minute clip does not take two minutes.
///
/// The clip is watched at ten frames a second, as the detector does. When the monitor wants a
/// check the model is asked about that frame, and its answer is delivered `--check-seconds` of clip
/// time later: how long a check takes on the phone, where reading a frame of this size took 0.74 s
/// on average over 82 turns (the Mac is several times faster).
///
/// Watches come from the command line or from `--batch file`, one tab-separated line each:
/// `clip  condition  expected`. `expected` is "none" (no alert may come) or the second of the clip
/// at which the thing happens: the alert must then come within `--within` seconds of it and not
/// before. The bar is the one measured for the model file given (`WatchMonitor.Policy.calibrated`);
/// `--bar`, `--change` and `--gap` override the monitor's policy; `--heat hot` replays it as
/// on a hot phone; `--quiet` prints only the summaries. `--search` replays it the way the app
/// runs a search (`WatchMonitor.Policy.searching`: every view looked at, back to back) and gives
/// up after `--limit` seconds (30, as the app does).
func runWatchMode(_ arguments: [String]) {
    var args = arguments
    guard args.count >= 3 else {
        print("usage: eyes-cli watch <model.gguf> <mmproj.gguf> [--search] [--limit 30] [--side 768] [--check-seconds 0.8] [--within 3] [--bar 0.9] [--change 0.8] [--gap 1.5] [--heat hot] [--template \"… {} …\"] [--quiet] --batch watches.tsv | <clip> <condition> [expected] ...")
        return
    }
    let modelPath = args.removeFirst()
    let mmprojPath = args.removeFirst()
    var side = VLMService.imageMaxSide
    var checkSeconds = 0.8
    var within = 3.0
    var policy = WatchMonitor.Policy.calibrated(forModel: URL(fileURLWithPath: modelPath).deletingPathExtension().lastPathComponent)
    var heat = Heat.normal
    var template = WatchCondition.template
    var quiet = false
    var batchPath: String?
    var limit = Double.infinity
    while let first = args.first, first.hasPrefix("--") {
        args.removeFirst()
        if first == "--quiet" {
            quiet = true
            continue
        }
        if first == "--search" {
            policy = .searching(forModel: URL(fileURLWithPath: modelPath).deletingPathExtension().lastPathComponent)
            limit = 30
            continue
        }
        guard !args.isEmpty else { print("\(first) needs a value"); return }
        let value = args.removeFirst()
        switch first {
        case "--side": side = Int(value) ?? side
        case "--check-seconds": checkSeconds = Double(value) ?? checkSeconds
        case "--within": within = Double(value) ?? within
        case "--bar": policy.bar = Float(value) ?? policy.bar
        case "--change": policy.changeNeeded = Float(value) ?? policy.changeNeeded
        case "--gap": policy.gap = Double(value) ?? policy.gap
        case "--heat": heat = value == "hot" ? .hot : (value == "toohot" ? .tooHot : .normal)
        case "--template": template = value
        case "--batch": batchPath = value
        case "--limit": limit = Double(value) ?? limit
        default: print("unknown flag \(first)"); return
        }
    }
    struct Item {
        var clip: String
        var condition: String
        /// nil: not marked. `.infinity`: no alert may come. Otherwise the second it happens.
        var expected: Double?
    }
    func expectation(_ text: String) -> Double? { text.lowercased() == "none" ? .infinity : Double(text) }
    var items: [Item] = []
    if let batchPath {
        guard let text = try? String(contentsOfFile: batchPath, encoding: .utf8) else { print("could not read \(batchPath)"); return }
        let folder = URL(fileURLWithPath: batchPath).deletingLastPathComponent()
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 2 else { continue }
            items.append(Item(clip: URL(fileURLWithPath: fields[0], relativeTo: folder).path, condition: fields[1],
                              expected: fields.count > 2 ? expectation(fields[2]) : nil))
        }
    }
    while args.count >= 2 {
        var item = Item(clip: args.removeFirst(), condition: args.removeFirst())
        if let next = args.first, let expected = expectation(next) {
            item.expected = expected
            args.removeFirst()
        }
        items.append(item)
    }
    guard !items.isEmpty else { print("nothing to watch"); return }

    let engine: LLMEngine
    do { engine = try LLMEngine(modelPath: modelPath, mmprojPath: mmprojPath) } catch { print("load failed: \(error)"); return }

    var passed = 0, marked = 0, falseAlerts = 0, minutes = 0.0, allChecks = 0
    var delays: [Double] = []
    for item in items {
        let name = (item.clip as NSString).lastPathComponent
        guard let clip = VideoClip(path: item.clip), let condition = WatchCondition(item.condition) else {
            print("\n[\(name)] could not open it, or no condition")
            continue
        }
        var monitor = WatchMonitor(condition)
        monitor.policy = policy
        let question = condition.question(template: template)
        print(String(format: "\n[%@, %.0f s] watching for: %@\n   asked as: %@", name, clip.duration, condition.words, question))
        var pending: (probability: Float, done: Double)?
        var alert: Double?
        var alreadySo = false
        var time = 0.0
        while time <= min(clip.duration, limit), alert == nil {
            defer { time += 0.1 }
            if let answer = pending, time >= answer.done {
                pending = nil
                switch monitor.answered(answer.probability) {
                case .nothing: break
                case .alert: alert = answer.done
                case .alreadySo:
                    alert = answer.done
                    alreadySo = true
                }
                continue
            }
            guard pending == nil, let cg = clip.frame(at: time), let frame = PixelWarp.pixelBuffer(from: cg),
                  let signature = SceneSignature(frame), monitor.wantsCheck(at: time, signature: signature, heat: heat)
            else { continue }
            guard let image = RGBImage(cgImage: cg, maxSide: side) else { continue }
            do {
                try engine.ingest(image: image)
                let probability = try engine.yesProbability(question: question)
                monitor.began(at: time, signature: signature)
                pending = (probability, time + checkSeconds)
                if !quiet { print(String(format: "   %6.1f s  asked: %.3f%@", time, probability, probability >= policy.bar ? "  yes" : "")) }
            } catch {
                print("   error: \(error)")
                break
            }
        }
        let watched = alert ?? min(clip.duration, limit)
        minutes += watched / 60
        allChecks += monitor.checks
        var verdict = ""
        if let expected = item.expected {
            marked += 1
            let ok: Bool
            if expected == .infinity {
                ok = alert == nil
                if !ok { falseAlerts += 1 }
                verdict = ok ? "right: no alert" : "FALSE ALERT"
            } else if let alert {
                ok = alert >= expected && alert - expected <= within
                if alert < expected { falseAlerts += 1 } else { delays.append(alert - expected) }
                verdict = alert < expected ? "FALSE ALERT, before it happened at \(expected) s"
                    : String(format: "%@: %.1f s after it happened", ok ? "right" : "LATE", alert - expected)
            } else {
                ok = false
                verdict = "MISSED: it happened at \(expected) s"
            }
            if ok { passed += 1 }
        }
        print(String(format: "   %@; %d checks in %.0f s (model busy %.0f%% of the time). %@",
                     alert.map { String(format: "%@ at %.1f s", alreadySo ? "\"already so\"" : "alert", $0) } ?? "no alert", monitor.checks, watched,
                     100 * Double(monitor.checks) * checkSeconds / max(watched, 0.1), verdict))
    }
    if marked > 0 {
        let delay = delays.isEmpty ? "" : String(format: "; alerts %.1f s after the event on average, %.1f s at worst", delays.reduce(0, +) / Double(delays.count), delays.max() ?? 0)
        print(String(format: "\n%d of %d watches right, %d false alerts in %.1f minutes watched, %.1f checks a minute%@",
                     passed, marked, falseAlerts, minutes, Double(allChecks) / max(minutes, 0.01), delay))
    }
}
