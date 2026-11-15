import CoreGraphics
import CoreVideo
import Foundation

/// Replays a search for a remembered person or thing over the turns saved from the phone
/// (`tools/pull_debug.sh`): on which frames would face memory or belonging memory have said
/// "found"? It runs the app's own code on every saved frame (the detector, `MemoryEngine.find`,
/// `MemoryStore.identify`) with a memory taught from frames named on the command line, since the
/// phone's own memory file is not copied to the Mac.
///
///   eyes-cli find <arcface.mlpackage> <dinov3_s.mlpackage> <yoloe26m.mlpackage> <yoloe_labels.json> <turns dir>
///       [--person "Dana=20261114-150839-349"] ... [--thing "water bottle=20261114-173109-719"] ... [--out results.tsv] [--verbose]
///
/// A person is taught from the face the phone named so in that turn (its box is in the turn's
/// JSON), a thing from the box the phone matched it at. The output has one line per frame and
/// target: what the phone itself recorded on that turn, and what this replay finds
/// ("sure", "unsure" or nothing, with the score). Frames are judged one at a time, so a face gets
/// no help from `FaceTracker`: an unsure face stays unsure here where the app would promote three
/// in a row.
func runFindMode(_ arguments: [String]) {
    var args = arguments
    guard args.count >= 5 else {
        print("usage: eyes-cli find <arcface.mlpackage> <dinov3_s.mlpackage> <yoloe26m.mlpackage> <yoloe_labels.json> <turns dir> [--person \"Name=turn id\"] [--thing \"name=turn id\"] [--out results.tsv]")
        return
    }
    let facePath = args.removeFirst(), thingPath = args.removeFirst(), detectorPath = args.removeFirst(), labelsPath = args.removeFirst()
    let turns = args.removeFirst()
    var people: [(name: String, turn: String)] = [], things: [(name: String, turn: String)] = []
    var outPath: String?
    // `--verbose` prints, for every frame, the detector's boxes and each region's scores.
    let verbose = args.contains("--verbose")
    args.removeAll { $0 == "--verbose" }
    while args.count >= 2 {
        let flag = args.removeFirst(), value = args.removeFirst()
        let parts = value.split(separator: "=", maxSplits: 1).map(String.init)
        switch flag {
        case "--person" where parts.count == 2: people.append((parts[0], parts[1]))
        case "--thing" where parts.count == 2: things.append((parts[0], parts[1]))
        case "--out": outPath = value
        default: print("could not read \(flag) \(value)"); return
        }
    }

    struct Saved: Decodable {
        struct Box: Decodable {
            var label: String
            var confidence: Float?
            var note: String?
            var x: Double, y: Double, width: Double, height: Double
            var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
        }
        var faces: [Box]
        var belongings: [Box]
    }
    func saved(_ turn: String) -> Saved? {
        (try? Data(contentsOf: URL(fileURLWithPath: "\(turns)/\(turn).json"))).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
    }
    func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let both = a.intersection(b)
        return both.isNull ? 0 : both.width * both.height / (a.width * a.height + b.width * b.height - both.width * both.height)
    }

    do {
        let faces = try FaceEmbedder(compiledModel: compileModel(facePath))
        let embedder = try ThingEmbedder(compiledModel: compileModel(thingPath))
        let detector = try ObjectDetector(compiledModel: compileModel(detectorPath), labels: URL(fileURLWithPath: labelsPath))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("eyes-find-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = MemoryStore(url: file)
        let engine = MemoryEngine(store: store, faceEmbedder: faces, thingEmbedder: embedder)

        // Teach memory from the named turns.
        for (name, turn) in people {
            guard let frame = loadPixelBuffer("\(turns)/\(turn).jpg"), let record = saved(turn),
                  let box = record.faces.first(where: { $0.label == name })?.rect,
                  let face = faces.faces(in: frame, limit: 8).max(by: { overlap($0.box, box) < overlap($1.box, box) }), overlap(face.box, box) > 0.3
            else { print("could not teach \(name) from \(turn): no face where the phone had one (its boxes are from a moment after the saved frame)"); return }
            _ = store.remember(person: name, samples: [face.embedding])
            print(String(format: "taught %@ from %@ (face %.0f px wide)", name, turn, Double(face.pixelWidth)))
        }
        for (name, turn) in things {
            guard let frame = loadPixelBuffer("\(turns)/\(turn).jpg"), let record = saved(turn),
                  let box = record.belongings.first(where: { $0.label == name })?.rect, let embedding = embedder.embed(frame, box: box)
            else { print("could not teach \(name) from \(turn)"); return }
            let label = detector.detect(in: frame).filter { overlap($0.box, box) > 0.5 }.max { $0.confidence < $1.confidence }?.label
            _ = store.remember(belonging: name, label: label, samples: [embedding])
            print("taught \(name) from \(turn) (the detector calls it \(label ?? "nothing"))")
        }

        let ids = ((try? FileManager.default.contentsOfDirectory(atPath: turns)) ?? [])
            .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
        var lines = ["turn\tkind\ttarget\tphone\tphone_score\treplay\treplay_score\tbox"]
        let taught = Set(people.map(\.turn) + things.map(\.turn))
        let done = DispatchSemaphore(value: 0)
        Task {
            for id in ids {
                guard let frame = loadPixelBuffer("\(turns)/\(id).jpg"), let record = saved(id) else { continue }
                let note = taught.contains(id) ? " (taught from)" : ""
                // People: every face in the frame against everyone taught, as the app's first look would.
                let seen = faces.faces(in: frame, limit: 8)
                for (name, _) in people {
                    let phone = record.faces.first { $0.label == name }
                    var best: (verdict: String, score: Float, box: CGRect)?
                    for face in seen {
                        let score = store.ranked(face: face.embedding).first { $0.name == name }?.score ?? -1
                        let match = store.identify(face: face.embedding)
                        let verdict = match?.name == name ? (match!.tentative ? "unsure" : "sure") : ""
                        let rank = ["sure": 2, "unsure": 1, "": 0]
                        if best == nil || rank[verdict]! > rank[best!.verdict]! || (verdict == best!.verdict && score > best!.score) {
                            best = (verdict, score, face.box)
                        }
                    }
                    lines.append("\(id)\(note)\tperson\t\(name)\t\(phone.map { $0.note == "tentative" ? "unsure" : "sure" } ?? "")\t\(phone?.confidence.map { String(format: "%.2f", $0) } ?? "")"
                        + "\t\(best?.verdict ?? "")\t\(best.map { String(format: "%.2f", $0.score) } ?? "")\t\(best.map { String(format: "%.3f,%.3f,%.3f,%.3f", $0.box.minX, $0.box.minY, $0.box.width, $0.box.height) } ?? "")")
                }
                // Things: the search's own look, `MemoryEngine.find`, on the detector's boxes for this frame.
                let shot = Snapshot(frame: frame, detections: detector.detect(in: frame), depth: nil)
                for (name, _) in things {
                    guard let thing = store.belonging(named: name) else { continue }
                    let phone = record.belongings.first { $0.label == name }
                    if verbose { print("\(id): " + shot.detections.map { String(format: "%@ %.2f", $0.label, $0.confidence) }.joined(separator: ", ")) }
                    let found = await engine.find(thing, in: [shot], logging: verbose)
                    lines.append("\(id)\(note)\tthing\t\(name)\t\(phone.map { $0.note == "tentative" ? "unsure" : "sure" } ?? "")\t\(phone?.confidence.map { String(format: "%.2f", $0) } ?? "")"
                        + "\t\(found.map { $0.tentative ? "unsure" : "sure" } ?? "")\t\(found.map { String(format: "%.2f", $0.score) } ?? "")\t\(found.map { String(format: "%.3f,%.3f,%.3f,%.3f", $0.box.minX, $0.box.minY, $0.box.width, $0.box.height) } ?? "")")
                }
            }
            done.signal()
        }
        done.wait()
        let text = lines.joined(separator: "\n") + "\n"
        if let outPath { try text.write(toFile: outPath, atomically: true, encoding: .utf8) } else { print(text) }

        // A summary per target: where the replay and the phone agree, and where they do not.
        for (kind, names) in [("person", people.map(\.name)), ("thing", things.map(\.name))] {
            for name in names {
                let rows = lines.dropFirst().map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
                    .filter { $0[1] == kind && $0[2] == name && !$0[0].hasSuffix("(taught from)") }
                func count(_ phone: (String) -> Bool, _ replay: (String) -> Bool) -> Int { rows.filter { phone($0[3]) && replay($0[5]) }.count }
                print("\(name): \(rows.count) frames. Phone matched it on \(count({ !$0.isEmpty }, { _ in true })); of those the replay is sure on \(count({ !$0.isEmpty }, { $0 == "sure" })), unsure on \(count({ !$0.isEmpty }, { $0 == "unsure" })), nothing on \(count({ !$0.isEmpty }, { $0.isEmpty })). "
                      + "Where the phone matched nothing, the replay is sure on \(count({ $0.isEmpty }, { $0 == "sure" })), unsure on \(count({ $0.isEmpty }, { $0 == "unsure" })).")
            }
        }
    } catch {
        print("find failed: \(error)")
    }
}
