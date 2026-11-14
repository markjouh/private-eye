import CoreGraphics
import CoreML
import CoreVideo
import Foundation

/// Tests for belonging (object instance) matching, on a folder of photos named
/// `{category}_{instance}_{view}.jpg`: several views of each of a number of objects.
///
///   eyes-cli things eval <dinov3_s.mlpackage> <yoloe26m.mlpackage> <yoloe_labels.json> <photo dir> [--same a,b]...
///       targeting, similarity distributions, retrieval, accept thresholds, margin rule, timing
///   eyes-cli things policies <same four> [--same a,b]...
///       the same separation measures for each way of cropping, with and without a change of background
///   eyes-cli things crops <same four> <out dir>
///       one contact sheet per category of what the model is shown (columns: objects, rows: views)
///   eyes-cli things targeting
///       BelongingTargeting against made-up scenes with a known right answer
///
/// `--same book_0,book_2` says two sets of photos show the same thing (or two copies of one product,
/// which no camera can tell apart), filmed separately. They then count as one object, and their pairs
/// are the honest test of recognising a thing against a new background.
///
/// Every box comes from the detector and BelongingTargeting, as in the app; the photos have no annotations.
func runThingsMode(_ args: [String]) {
    if args.first == "targeting" { checkTargeting(); return }
    var paths: [String] = []
    var same: [[String]] = []
    var rest = args.dropFirst()
    while let arg = rest.popFirst() {
        if arg == "--same", let group = rest.popFirst() { same.append(group.components(separatedBy: ",")) } else { paths.append(arg) }
    }
    guard paths.count >= 4, let mode = args.first, ["eval", "policies", "crops"].contains(mode) else {
        print("usage: eyes-cli things <eval|policies|crops> <dinov3_s.mlpackage> <yoloe26m.mlpackage> <yoloe_labels.json> <photo dir> [out dir] [--same a,b]...")
        print("       eyes-cli things targeting")
        return
    }
    do {
        let embedder = try ThingEmbedder(compiledModel: compileModel(paths[0]))
        let detector = try ObjectDetector(compiledModel: compileModel(paths[1]), labels: URL(fileURLWithPath: paths[2]))
        let bench = ThingsBench(embedder: embedder, photos: loadPhotos(in: paths[3], detector: detector, same: same))
        guard !bench.photos.isEmpty else { print("no photos named {category}_{instance}_{view}.jpg in \(paths[3])"); return }
        print("\(bench.photos.count) photos, \(Set(bench.photos.map(\.scene)).count) filmed scenes, \(bench.objectCount) distinct objects; model on \(describe(embedder.computeUnits))")
        switch mode {
        case "eval": bench.evaluate()
        case "policies": bench.comparePolicies()
        default:
            guard paths.count >= 5 else { print("crops needs an output folder"); return }
            bench.writeContactSheets(to: paths[4])
        }
    } catch {
        print("things failed: \(error)")
    }
}

/// Scenes described by hand: what is detected where, what the user says, and what should be picked.
private func checkTargeting() {
    func seen(_ label: String, _ confidence: Float, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> Detection {
        Detection(label: label, confidence: confidence, box: CGRect(x: x, y: y, width: width, height: height))
    }
    let desk = seen("desk", 0.9, 0.05, 0.3, 0.9, 0.6), person = seen("person", 0.9, 0.2, 0.0, 0.6, 1.0)
    let bottle = seen("bottle", 0.8, 0.42, 0.35, 0.16, 0.3), cup = seen("cup", 0.7, 0.45, 0.42, 0.12, 0.14)
    let farBottle = seen("bottle", 0.9, 0.86, 0.1, 0.1, 0.25), sideBottle = seen("bottle", 0.9, 0.7, 0.35, 0.12, 0.3)
    let faintBottle = seen("bottle", 0.5, 0.44, 0.38, 0.14, 0.28)
    let keys = seen("keys", 0.5, 0.46, 0.47, 0.1, 0.08), speck = seen("pen", 0.6, 0.49, 0.49, 0.02, 0.02)
    let nearCup = seen("cup", 0.7, 0.58, 0.45, 0.12, 0.14), awayCup = seen("cup", 0.7, 0.75, 0.45, 0.12, 0.14)
    let chair = seen("chair", 0.8, 0.3, 0.3, 0.4, 0.5), sameAsCup = seen("mug", 0.4, 0.45, 0.42, 0.12, 0.15)

    var failed = 0
    func expect(_ what: String, _ got: [String], _ wanted: [String]) {
        if got != wanted { failed += 1 }
        print((got == wanted ? "ok    " : "FAIL  ") + what + (got == wanted ? "" : "  got \(got), wanted \(wanted)"))
    }
    func target(_ what: String, _ detections: [Detection], say name: String, picks wanted: Detection?) {
        let got = BelongingTargeting.enrolmentTarget(in: detections, named: name)
        let right = wanted.map { got.box == $0.box && got.label == $0.label } ?? (got.label == nil)
        expect("enrol \"\(name)\": " + what, [right ? "right" : "\(got.label ?? "middle of view") at \(got.box)"], ["right"])
    }
    target("the bottle on the desk", [desk, bottle], say: "water bottle", picks: bottle)
    target("a name the detector does not know", [desk, bottle], say: "thermos", picks: bottle)
    target("plural and case", [desk, keys], say: "Key", picks: keys)
    target("held in front of a person", [person, keys], say: "lucky charm", picks: keys)
    target("the surroundings when named", [desk, bottle], say: "desk", picks: desk)
    target("a doubtful bottle in the middle over a sure one to the side", [faintBottle, sideBottle], say: "bottle", picks: faintBottle)
    target("a sure bottle slightly to the side", [desk, sideBottle], say: "bottle", picks: sideBottle)
    target("a bottle at the edge is not what a cup in the middle is called", [farBottle, cup], say: "bottle", picks: cup)
    target("the smaller of two things over the middle", [bottle, cup], say: "thing", picks: cup)
    target("just beside the middle", [desk, nearCup], say: "thing", picks: nearCup)
    target("too far to the side without a name", [desk, awayCup], say: "thing", picks: nil)
    target("only surroundings", [desk, person], say: "thing", picks: nil)
    target("too small to embed", [speck], say: "thing", picks: nil)
    target("nothing detected", [], say: "water bottle", picks: nil)

    func search(_ what: String, _ detections: [Detection], label: String?, limit: Int = 4, finds wanted: [String]) {
        let got = BelongingTargeting.searchCandidates(in: detections, label: label, limit: limit).map { $0.label ?? "middle" }
        expect("search for \(label ?? "an unlabelled thing"): " + what, got, wanted)
    }
    search("its own label first, surroundings skipped", [desk, person, cup, bottle], label: "bottle", finds: ["bottle", "cup"])
    search("one region for two labels on one box", [cup, sameAsCup, bottle], label: "bottle", finds: ["bottle", "cup"])
    search("the cap", [cup, bottle, keys, sideBottle, farBottle], label: "keys", limit: 3, finds: ["keys", "bottle", "bottle"])
    search("surroundings when the belonging is one", [desk, chair, cup], label: "chair", finds: ["chair", "cup"])
    search("the middle of the view for what the detector cannot name", [desk, cup], label: nil, finds: ["middle", "cup"])
    search("specks skipped", [speck, cup], label: "cup", finds: ["cup"])
    search("the middle of the view when no detection is there", [sideBottle, farBottle], label: "bottle", finds: ["bottle", "bottle", "middle"])
    search("nothing detected", [], label: "bottle", finds: ["middle"])
    print(failed == 0 ? "all targeting checks passed" : "\(failed) targeting checks FAILED")
}

private func describe(_ units: MLComputeUnits) -> String {
    switch units {
    case .all: return "all compute units (Neural Engine allowed)"
    case .cpuAndGPU: return "CPU and GPU"
    case .cpuOnly: return "CPU only"
    default: return "compute units \(units.rawValue)"
    }
}

private struct Photo {
    let file: String
    let category: String
    /// The `{category}_{instance}` the photo was filmed as.
    let scene: Int
    let sceneName: String
    /// The physical object; scenes joined by `--same` share one.
    let object: Int
    let view: Int
    let frame: CVPixelBuffer
    let detections: [Detection]
}

private func loadPhotos(in dir: String, detector: ObjectDetector, same: [[String]]) -> [Photo] {
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".jpg") }.sorted()
    var scenes: [String: Int] = [:], objects: [String: Int] = [:]
    var photos: [Photo] = []
    for file in files {
        let parts = (file as NSString).deletingPathExtension.components(separatedBy: "_")
        guard parts.count == 3, let view = Int(parts[2]), let frame = loadPixelBuffer(dir + "/" + file) else { continue }
        let name = parts[0] + "_" + parts[1]
        let scene = scenes[name] ?? scenes.count
        scenes[name] = scene
        // Every scene in a `--same` group is filed under the group's first name.
        let objectName = same.first { $0.contains(name) }?.first ?? name
        let object = objects[objectName] ?? objects.count
        objects[objectName] = object
        photos.append(Photo(file: file, category: parts[0], scene: scene, sceneName: name, object: object, view: view,
                            frame: frame, detections: detector.detect(in: frame)))
    }
    return photos
}

private final class ThingsBench {
    let embedder: ThingEmbedder
    let photos: [Photo]
    let objectCount: Int
    /// What enrolling from each photo would pick, the user having named the object by its category.
    let targets: [BelongingTargeting.Region]
    private var cache: [String: [Float]] = [:]

    init(embedder: ThingEmbedder, photos: [Photo]) {
        self.embedder = embedder
        self.photos = photos
        objectCount = Set(photos.map(\.object)).count
        targets = photos.map { BelongingTargeting.enrolmentTarget(in: $0.detections, named: $0.category) }
    }

    func embedding(_ photo: Int, _ box: CGRect, _ crop: ThingEmbedder.Crop = .standard) -> [Float] {
        let key = "\(photo) \(box) \(crop.shape) \(crop.margin)"
        if let known = cache[key] { return known }
        let made = embedder.embed(photos[photo].frame, box: box, crop: crop) ?? []
        cache[key] = made
        return made
    }

    /// How two photos relate, which is what every score is judged against.
    private enum Relation { case sameScene, sameObjectNewScene, lookalike, otherCategory }

    private func relation(_ a: Int, _ b: Int) -> Relation {
        if photos[a].scene == photos[b].scene { return .sameScene }
        if photos[a].object == photos[b].object { return .sameObjectNewScene }
        return photos[a].category == photos[b].category ? .lookalike : .otherCategory
    }

    // MARK: eval

    func evaluate() {
        reportTargeting()

        let enrolled = photos.indices.map { embedding($0, targets[$0].box) }
        // pointing[q][e]: the user points at the object in photo q; compared with the object enrolled from photo e.
        let pointing = enrolled.map { q in enrolled.map { PixelWarp.cosine(q, $0) } }
        print("\n== Cosine between crops (object picked by the enrolment rule in both photos) ==")
        reportDistributions(pointing)
        reportClosestScenes(pointing)

        print("\n== Top-1 retrieval among all objects ==")
        print("  query crop picked by the enrolment rule (the user points at the thing):")
        reportRetrieval(pointing)

        for limit in [2, 4, 6] {
            let searching = searchScores(enrolled: enrolled, limit: limit)
            print("\n== Search: best of up to \(limit) candidate regions per photo ==")
            reportCandidateRecall(limit: limit)
            print("  top-1 retrieval:")
            reportRetrieval(searching)
            reportThresholds(searching)
            if limit == 4 { reportMargin(enrolled: enrolled, limit: limit) }
        }
        reportTiming()
    }

    /// search[q][e]: asked for the belonging enrolled from photo e, the best-scoring candidate region of photo q.
    private func searchScores(enrolled: [[Float]], limit: Int) -> [[Float]] {
        photos.indices.map { q in
            photos.indices.map { e in
                BelongingTargeting.searchCandidates(in: photos[q].detections, label: targets[e].label, limit: limit)
                    .map { PixelWarp.cosine(embedding(q, $0.box), enrolled[e]) }.max() ?? -1
            }
        }
    }

    private func reportTargeting() {
        print("\n== Enrolment target (named by category) ==")
        var byRule: [String: [String: Int]] = [:]
        var agree = 0
        for (i, photo) in photos.enumerated() {
            let target = targets[i]
            let rule = target.label == nil ? "middle of view" : (target.label!.contains(photo.category) ? "named" : "other label")
            byRule[photo.category, default: [:]][rule, default: 0] += 1
            if rule != "named", photo.detections.contains(where: { $0.label.contains(photo.category) }) {
                let seen = photo.detections.filter { $0.label.contains(photo.category) }
                    .map { String(format: "%.2f at x %.2f-%.2f y %.2f-%.2f", $0.confidence, $0.box.minX, $0.box.maxX, $0.box.minY, $0.box.maxY) }
                print("  \(photo.file): \(rule)\(target.label.map { " (\($0))" } ?? ""), though it saw \(photo.category) \(seen.joined(separator: "; "))")
            }
            // With a name the detector does not know, only the geometry is left to find the same thing.
            let unnamed = BelongingTargeting.enrolmentTarget(in: photo.detections, named: "thing")
            if iou(unnamed.box, target.box) >= 0.5 { agree += 1 }
        }
        for category in byRule.keys.sorted() {
            print("  \(category): " + byRule[category]!.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", "))
        }
        print("  same box when the name gives no hint (\"thing\"): \(agree) of \(photos.count)")
    }

    private func scores(_ score: [[Float]], _ wanted: Relation, where include: (Photo, Photo) -> Bool = { _, _ in true }) -> [Float] {
        var values: [Float] = []
        for q in photos.indices {
            for e in photos.indices where e > q && relation(q, e) == wanted && include(photos[q], photos[e]) { values.append(score[q][e]) }
        }
        return values.sorted()
    }

    private func reportDistributions(_ score: [[Float]]) {
        func line(_ name: String, _ s: [Float]) {
            guard !s.isEmpty else { return }
            print(pad(name, 40) + String(format: "p5 %.2f  p50 %.2f  p95 %.2f   (min %.2f, max %.2f, %d pairs)",
                                         percentile(s, 0.05), percentile(s, 0.5), percentile(s, 0.95), s[0], s[s.count - 1], s.count))
        }
        line("  same object, same scene, other view", scores(score, .sameScene))
        line("  same object, filmed elsewhere", scores(score, .sameObjectNewScene))
        line("  same category, different object", scores(score, .lookalike))
        line("  different category", scores(score, .otherCategory))
        for category in Set(photos.map(\.category)).sorted() {
            let own = scores(score, .sameScene) { a, _ in a.category == category }
            let rival = scores(score, .lookalike) { a, _ in a.category == category }
            guard !rival.isEmpty else { continue }
            print(pad("    " + category, 12) + String(format: "same scene p5 %.2f p50 %.2f | different object p50 %.2f p95 %.2f max %.2f",
                                                      percentile(own, 0.05), percentile(own, 0.5), percentile(rival, 0.5), percentile(rival, 0.95), rival[rival.count - 1]))
        }
    }

    /// The pairs of scenes that look most alike: where to look for one object filmed twice.
    private func reportClosestScenes(_ score: [[Float]]) {
        var between: [String: [Float]] = [:]
        for q in photos.indices {
            for e in photos.indices where e > q && photos[q].scene != photos[e].scene && photos[q].category == photos[e].category {
                let mark = photos[q].object == photos[e].object ? " (same object)" : ""
                between[photos[q].sceneName + " / " + photos[e].sceneName + mark, default: []].append(score[q][e])
            }
        }
        let ranked = between.mapValues { percentile($0.sorted(), 0.5) }.sorted { $0.value > $1.value }.prefix(10)
        print("  most alike scenes (median cosine): " + ranked.map { String(format: "%@ %.2f", $0.key, $0.value) }.joined(separator: ", "))
    }

    /// Each object enrolled from the same one view (then the same two views); every other view is a query.
    /// Objects filmed twice are also queried with only their other scene enrolled.
    private func reportRetrieval(_ score: [[Float]]) {
        let views = Array(Set(photos.map(\.view))).sorted()
        var enrolments: [[Int]] = views.map { [$0] }
        for (i, a) in views.enumerated() { for b in views[(i + 1)...] { enrolments.append([a, b]) } }
        for count in [1, 2] {
            var right = 0, total = 0, rightElsewhere = 0, totalElsewhere = 0
            var wrongByCategory: [String: Int] = [:]
            for stored in enrolments where stored.count == count {
                let gallery = photos.indices.filter { stored.contains(photos[$0].view) }
                for q in photos.indices where !stored.contains(photos[q].view) {
                    if let best = gallery.max(by: { score[q][$0] < score[q][$1] }) {
                        total += 1
                        if photos[best].object == photos[q].object { right += 1 } else { wrongByCategory[photos[q].category, default: 0] += 1 }
                    }
                    let elsewhere = gallery.filter { photos[$0].scene != photos[q].scene }
                    guard elsewhere.contains(where: { photos[$0].object == photos[q].object }),
                          let best = elsewhere.max(by: { score[q][$0] < score[q][$1] }) else { continue }
                    totalElsewhere += 1
                    if photos[best].object == photos[q].object { rightElsewhere += 1 }
                }
            }
            let misses = wrongByCategory.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            var line = String(format: "    enrolled from %d view%@: %.1f%% (%d of %d)", count, count == 1 ? "" : "s",
                              100 * Double(right) / Double(max(total, 1)), right, total)
            if !misses.isEmpty { line += "  misses: " + misses }
            if totalElsewhere > 0 {
                line += String(format: "\n      only its other scene enrolled: %.1f%% (%d of %d)",
                               100 * Double(rightElsewhere) / Double(totalElsewhere), rightElsewhere, totalElsewhere)
            }
            print(line)
        }
    }

    /// How often the object the enrolment rule would pick is among the search candidates.
    private func reportCandidateRecall(limit: Int) {
        var found = 0, regions = 0
        for (i, photo) in photos.enumerated() {
            let candidates = BelongingTargeting.searchCandidates(in: photo.detections, label: targets[i].label, limit: limit)
            regions += candidates.count
            if candidates.contains(where: { iou($0.box, targets[i].box) >= 0.5 }) { found += 1 }
        }
        print(String(format: "  the object is among the candidates in %d of %d photos; %.1f regions embedded per photo",
                     found, photos.count, Double(regions) / Double(photos.count)))
    }

    /// The open-set trade-off: how often the right object is accepted against how often something else is.
    private func reportThresholds(_ score: [[Float]]) {
        // Trials by relation, for a belonging enrolled from one view and from two (best of the two).
        var one: [Relation: [Float]] = [:], two: [Relation: [Float]] = [:]
        for q in photos.indices {
            var byScene: [Int: [Int]] = [:]
            for e in photos.indices where e != q { byScene[photos[e].scene, default: []].append(e) }
            for stored in byScene.values {
                let kind = relation(q, stored[0])
                for (i, a) in stored.enumerated() {
                    one[kind, default: []].append(score[q][a])
                    for b in stored[(i + 1)...] where kind != .otherCategory { two[kind, default: []].append(max(score[q][a], score[q][b])) }
                }
            }
        }
        func rate(_ values: [Float]?, _ threshold: Float) -> String {
            guard let values, !values.isEmpty else { return "    -" }
            return String(format: "%5.1f", 100 * Double(values.filter { $0 >= threshold }.count) / Double(values.count))
        }
        print("  accepted at each threshold (% of trials); enrolled from 1 view | 2 views")
        print("    thr   right, same scene   right, filmed elsewhere   look-alike, same category   other category")
        for step in 0...12 {
            let t = 0.30 + Float(step) * 0.05
            print(String(format: "    %.2f  ", t) + rate(one[.sameScene], t) + " | " + rate(two[.sameScene], t) + "       "
                  + rate(one[.sameObjectNewScene], t) + " | " + rate(two[.sameObjectNewScene], t) + "             "
                  + rate(one[.lookalike], t) + " | " + rate(two[.lookalike], t) + "               " + rate(one[.otherCategory], t))
        }
        func count(_ kind: Relation) -> String { "\(one[kind]?.count ?? 0) | \(two[kind]?.count ?? 0)" }
        print("    trials: same scene \(count(.sameScene)), elsewhere \(count(.sameObjectNewScene)), look-alike \(count(.lookalike)), other \(one[.otherCategory]?.count ?? 0)")
    }

    /// Would requiring a lead over the user's other belongings help? Every scene is enrolled from one
    /// view; the best candidate region for the belonging asked about is also compared with all the others.
    private func reportMargin(enrolled: [[Float]], limit: Int) {
        print("  margin rule (everything enrolled from 1 view; lead = score minus the best other belonging on the same region):")
        struct Trial { let score: Float; let lead: Float; let leadWithoutShown: Float }
        var right: [Trial] = [], lookalike: [Trial] = []
        for view in Set(photos.map(\.view)).sorted() {
            let stored = photos.indices.filter { photos[$0].view == view }
            for q in photos.indices where photos[q].view != view {
                for e in stored where photos[e].category == photos[q].category {
                    let kind = relation(q, e)
                    // An object enrolled twice would be its own rival, so the cross-scene trials are left out here.
                    guard kind == .sameScene || kind == .lookalike else { continue }
                    let regions = BelongingTargeting.searchCandidates(in: photos[q].detections, label: targets[e].label, limit: limit)
                    guard let best = regions.map({ embedding(q, $0.box) }).max(by: { PixelWarp.cosine($0, enrolled[e]) < PixelWarp.cosine($1, enrolled[e]) }) else { continue }
                    let score = PixelWarp.cosine(best, enrolled[e])
                    let rivals = stored.filter { photos[$0].object != photos[e].object }
                    let lead = score - (rivals.map { PixelWarp.cosine(best, enrolled[$0]) }.max() ?? -1)
                    // A stranger's look-alike is not enrolled, so it cannot be the rival.
                    let strangers = rivals.filter { photos[$0].object != photos[q].object }
                    let leadWithoutShown = score - (strangers.map { PixelWarp.cosine(best, enrolled[$0]) }.max() ?? -1)
                    let trial = Trial(score: score, lead: lead, leadWithoutShown: leadWithoutShown)
                    if kind == .sameScene { right.append(trial) } else { lookalike.append(trial) }
                }
            }
        }
        print("    thr   lead   right object   look-alike also enrolled   look-alike not enrolled")
        for threshold in [Float(0.50), 0.55, 0.60, 0.65, 0.70] {
            for lead in [Float(-1), 0.0, 0.03, 0.05, 0.10] {
                func rate(_ trials: [Trial], _ value: (Trial) -> Float) -> Double {
                    100 * Double(trials.filter { $0.score >= threshold && value($0) >= lead }.count) / Double(max(trials.count, 1))
                }
                print(String(format: "    %.2f  %@   %5.1f          %5.1f                      %5.1f", threshold,
                             lead < 0 ? "none" : String(format: "%.2f", lead),
                             rate(right, \.lead), rate(lookalike, \.lead), rate(lookalike, \.leadWithoutShown)))
            }
        }
    }

    private func reportTiming() {
        var cropMs = 0.0, modelMs = 0.0
        let sample = Array(photos.indices.prefix(60))
        for i in sample {
            let start = Date()
            guard let input = ThingEmbedder.crop(photos[i].frame, box: targets[i].box) else { continue }
            cropMs += Date().timeIntervalSince(start) * 1000
            _ = embedder.embed(cropped: input)
            modelMs += embedder.lastInferenceMs
        }
        print(String(format: "\n== Time per region on this Mac ==\n  crop %.2f ms + model %.2f ms", cropMs / Double(sample.count), modelMs / Double(sample.count)))
    }

    // MARK: policies

    func comparePolicies() {
        let policies: [(String, ThingEmbedder.Crop)] = [
            ("stretch, tight", .init(shape: .stretch, margin: 0)),
            ("stretch, +10%", .init(shape: .stretch, margin: 0.1)),
            ("stretch, +25%", .init(shape: .stretch, margin: 0.25)),
            ("square, tight", .init(shape: .square, margin: 0)),
            ("square, +10%", .init(shape: .square, margin: 0.1)),
            ("square, +25%", .init(shape: .square, margin: 0.25)),
            ("square, +50%", .init(shape: .square, margin: 0.5)),
            ("padded, tight", .init(shape: .padded, margin: 0)),
            ("padded, +10%", .init(shape: .padded, margin: 0.1)),
        ]
        // The views filmed in one scene share its background, which flatters crops that show more of it.
        // So each query is also tried with the object's box moved into a photo of something else: the same
        // thing against new surroundings, which is what finding a belonging later is like.
        let moved = photos.indices.map { transplant($0) }
        print("\neach cell: same-object cosine p5/p50 | look-alike p50/p95 | right object accepted at the threshold that")
        print("accepts 5% / 1% of look-alikes | top-1 from 1 enrolled view")
        print(pad("crop", 16) + pad("same scene", 46) + pad("box moved to another photo", 46) + "same object filmed elsewhere")
        for (name, crop) in policies {
            let stored = photos.indices.map { embedding($0, targets[$0].box, crop) }
            let inPlace = stored.map { q in stored.map { PixelWarp.cosine(q, $0) } }
            let movedQueries = photos.indices.map { embedder.embed(moved[$0], box: targets[$0].box, crop: crop) ?? [] }
            let afterMove = movedQueries.map { q in stored.map { PixelWarp.cosine(q, $0) } }
            print(pad(name, 16) + pad(separation(inPlace, .sameScene), 46) + pad(separation(afterMove, .sameScene), 46)
                  + separation(inPlace, .sameObjectNewScene))
        }
        // The detector knows only its vocabulary; anything else is enrolled and found as the middle of the view.
        let middle = photos.indices.map { embedding($0, BelongingTargeting.centre.box) }
        let middleScores = middle.map { q in middle.map { PixelWarp.cosine(q, $0) } }
        print(pad("middle of view", 16) + pad(separation(middleScores, .sameScene), 92) + separation(middleScores, .sameObjectNewScene))
    }

    /// score[q][e] with q a query photo and e an enrolled one (not symmetric when the queries are altered).
    /// `genuine` picks which same-object pairs are judged: filmed together, or filmed apart.
    private func separation(_ score: [[Float]], _ genuine: Relation) -> String {
        var same: [Float] = [], lookalike: [Float] = []
        for q in photos.indices {
            for e in photos.indices where e != q {
                let kind = relation(q, e)
                if kind == genuine { same.append(score[q][e]) } else if kind == .lookalike { lookalike.append(score[q][e]) }
            }
        }
        guard !same.isEmpty else { return "-" }
        same.sort()
        lookalike.sort()
        func accepted(allowing rate: Float) -> Double {
            let threshold = percentile(lookalike, 1 - rate)
            return 100 * Double(same.filter { $0 > threshold }.count) / Double(same.count)
        }
        // Top-1: everything enrolled from one view, except that the query's own scene is withheld when
        // the question is whether it is recognised from the other one.
        var right = 0, total = 0
        for view in Set(photos.map(\.view)) {
            for q in photos.indices where photos[q].view != view {
                let gallery = photos.indices.filter { photos[$0].view == view && (genuine == .sameScene || photos[$0].scene != photos[q].scene) }
                guard gallery.contains(where: { photos[$0].object == photos[q].object }),
                      let best = gallery.max(by: { score[q][$0] < score[q][$1] }) else { continue }
                total += 1
                if photos[best].object == photos[q].object { right += 1 }
            }
        }
        return String(format: "%.2f/%.2f | %.2f/%.2f | %3.0f%% / %3.0f%% | %5.1f%%", percentile(same, 0.05), percentile(same, 0.5),
                      percentile(lookalike, 0.5), percentile(lookalike, 0.95), accepted(allowing: 0.05), accepted(allowing: 0.01),
                      100 * Double(right) / Double(max(total, 1)))
    }

    /// Photo `index`'s object box pasted, in place, into a photo of an object of another category.
    private func transplant(_ index: Int) -> CVPixelBuffer {
        let source = photos[index]
        var donor = (index + photos.count / 2) % photos.count
        while photos[donor].category == source.category { donor = (donor + 1) % photos.count }
        let width = CVPixelBufferGetWidth(source.frame), height = CVPixelBufferGetHeight(source.frame)
        // Resampling the donor to the source's size also gives a fresh buffer to paste into.
        let scale = CGAffineTransform(scaleX: CGFloat(CVPixelBufferGetWidth(photos[donor].frame)) / CGFloat(width),
                                      y: CGFloat(CVPixelBufferGetHeight(photos[donor].frame)) / CGFloat(height))
        let out = PixelWarp.warp(photos[donor].frame, toSource: scale, width: width, height: height)!
        let box = targets[index].box
        let x0 = max(Int(box.minX * CGFloat(width)), 0), x1 = min(Int(box.maxX * CGFloat(width)), width)
        let y0 = max(Int(box.minY * CGFloat(height)), 0), y1 = min(Int(box.maxY * CGFloat(height)), height)
        CVPixelBufferLockBaseAddress(source.frame, .readOnly)
        CVPixelBufferLockBaseAddress(out, [])
        defer {
            CVPixelBufferUnlockBaseAddress(out, [])
            CVPixelBufferUnlockBaseAddress(source.frame, .readOnly)
        }
        let from = CVPixelBufferGetBaseAddress(source.frame)!, to = CVPixelBufferGetBaseAddress(out)!
        let fromRow = CVPixelBufferGetBytesPerRow(source.frame), toRow = CVPixelBufferGetBytesPerRow(out)
        for y in y0..<y1 where x1 > x0 {
            (to + y * toRow + x0 * 4).copyMemory(from: from + y * fromRow + x0 * 4, byteCount: (x1 - x0) * 4)
        }
        return out
    }

    // MARK: crops

    func writeContactSheets(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let side = ThingEmbedder.inputSide
        func sheet(columns: Int, rows: Int, draw: (CGContext) -> Void) -> CGImage? {
            guard let context = CGContext(data: nil, width: columns * side, height: rows * side, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            draw(context)
            return context.makeImage()
        }
        for category in Set(photos.map(\.category)).sorted() {
            let members = photos.indices.filter { photos[$0].category == category }
            let scenes = Array(Set(members.map { photos[$0].scene })).sorted()
            let views = Array(Set(members.map { photos[$0].view })).sorted()
            let image = sheet(columns: scenes.count, rows: views.count) { context in
                for i in members {
                    guard let crop = ThingEmbedder.crop(photos[i].frame, box: targets[i].box), let image = cgImage(crop) else { continue }
                    let column = scenes.firstIndex(of: photos[i].scene)!, row = views.firstIndex(of: photos[i].view)!
                    // CGContext's origin is bottom-left; row 0 goes at the top.
                    context.draw(image, in: CGRect(x: column * side, y: (views.count - 1 - row) * side, width: side, height: side))
                }
            }
            if let image { writePNG(image, to: dir + "/\(category).png") }
        }
        // And what a moved query looks like with a wide crop, for checking the background-swap test.
        let sample = Array(stride(from: 0, to: photos.count, by: max(photos.count / 8, 1)).prefix(8))
        let image = sheet(columns: sample.count, rows: 1) { context in
            for (column, i) in sample.enumerated() {
                let wide = ThingEmbedder.Crop(shape: .square, margin: 0.5)
                guard let crop = ThingEmbedder.crop(transplant(i), box: targets[i].box, crop: wide), let image = cgImage(crop) else { continue }
                context.draw(image, in: CGRect(x: column * side, y: 0, width: side, height: side))
            }
        }
        if let image { writePNG(image, to: dir + "/moved.png") }
        // The individual model inputs, for trying other models on exactly these pixels.
        try? FileManager.default.createDirectory(atPath: dir + "/inputs", withIntermediateDirectories: true)
        for i in photos.indices {
            guard let crop = ThingEmbedder.crop(photos[i].frame, box: targets[i].box), let image = cgImage(crop) else { continue }
            writePNG(image, to: dir + "/inputs/" + (photos[i].file as NSString).deletingPathExtension + ".png")
        }
        print("wrote contact sheets and model inputs to \(dir)")
    }
}

private func cgImage(_ buffer: CVPixelBuffer) -> CGImage? {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    return CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: CVPixelBufferGetWidth(buffer),
                     height: CVPixelBufferGetHeight(buffer), bitsPerComponent: 8,
                     bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                     bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)?.makeImage()
}

private func pad(_ text: String, _ width: Int) -> String {
    text.padding(toLength: max(width, text.count + 1), withPad: " ", startingAt: 0)
}

/// `sorted` ascending; `p` in 0...1.
private func percentile(_ sorted: [Float], _ p: Float) -> Float {
    guard !sorted.isEmpty else { return 0 }
    return sorted[min(sorted.count - 1, max(0, Int((Float(sorted.count - 1) * p).rounded())))]
}

private func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
    let both = a.intersection(b)
    guard !both.isNull else { return 0 }
    let shared = both.width * both.height
    return shared / (a.width * a.height + b.width * b.height - shared)
}
