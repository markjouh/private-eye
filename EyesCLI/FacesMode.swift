import CoreGraphics
import CoreVideo
import Foundation

/// Face-recognition tests that run the app's own pipeline (Vision landmarks, alignment, ArcFace,
/// MemoryStore matching) on LFW photos.
///
///   eyes-cli faces pairs <arcface.mlpackage> <pairs dir> <targets.txt> [--aligned <dir>] [--dump <dir>] [--limit N]
///       Verification: pairs dir holds NNNN_0.jpg / NNNN_1.jpg, targets.txt one 0/1 per pair (1 = same
///       person). With --aligned (reference crops NNNN_k.png made by a different detector) it also
///       reports how close our alignment gets to the reference.
///   eyes-cli faces identify <arcface.mlpackage> <people dir> [--people N] [--shots K] [--probe-scale S]
///       Identification as the app does it: half the people are enrolled with K photos each, the other
///       half are strangers; reports correct names, misses, wrong names and strangers given a name.
func runFacesMode(_ arguments: [String]) {
    var args = arguments
    if args.first == "tracker" {
        faceTrackerChecks()
        return
    }
    guard args.count >= 3, let mode = args.first else {
        print("usage: eyes-cli faces <pairs|identify> <arcface.mlpackage> ... (see EyesCLI/FacesMode.swift)")
        return
    }
    args.removeFirst()
    var options: [String: String] = [:]
    var positional: [String] = []
    while !args.isEmpty {
        let a = args.removeFirst()
        if a.hasPrefix("--"), !args.isEmpty { options[a] = args.removeFirst() } else { positional.append(a) }
    }
    do {
        let embedder = try FaceEmbedder(compiledModel: compileModel(positional[0]))
        // Experiment switches: --mirror no turns off mirror-image embedding; --min-width N.
        if options["--mirror"] == "no" { embedder.mirrorAugment = false }
        if let width = options["--min-width"].flatMap(Double.init) { embedder.minFaceWidth = width }
        switch mode {
        case "pairs": try facePairs(embedder, positional, options)
        case "identify": faceIdentify(embedder, positional, options)
        case "engine": faceEngineChecks(embedder, positional)
        case "quality": faceQuality(embedder, positional, options)
        default: print("unknown faces mode \(mode)")
        }
    } catch {
        print("faces failed: \(error)")
    }
}

/// The face nearest the middle of the photo (LFW centres its subject; other people may be in shot).
private func centralFace(_ embedder: FaceEmbedder, _ buffer: CVPixelBuffer) -> FaceObservation? {
    embedder.faces(in: buffer, limit: 6).min { a, b in
        hypot(a.box.midX - 0.5, a.box.midY - 0.5) < hypot(b.box.midX - 0.5, b.box.midY - 0.5)
    }
}

private func percentile(_ sorted: [Float], _ p: Double) -> Float {
    sorted.isEmpty ? .nan : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
}

private func facePairs(_ embedder: FaceEmbedder, _ positional: [String], _ options: [String: String]) throws {
    guard positional.count >= 3 else { print("need <pairs dir> <targets.txt>"); return }
    let dir = positional[1]
    let targets = try String(contentsOfFile: positional[2], encoding: .utf8).split(separator: "\n").map { $0 == "1" }
    let limit = min(targets.count, Int(options["--limit"] ?? "") ?? targets.count)
    let alignedDir = options["--aligned"]
    let dumpDir = options["--dump"]
    if let dumpDir { try? FileManager.default.createDirectory(atPath: dumpDir, withIntermediateDirectories: true) }

    var same: [Float] = [], different: [Float] = []
    var refSame: [Float] = [], refDifferent: [Float] = []
    var agreement: [Float] = []
    var missed = 0
    let start = Date()
    var embedded = 0
    for i in 0..<limit {
        var ours: [[Float]] = [], reference: [[Float]] = []
        for k in 0..<2 {
            let name = String(format: "%04d_%d", i, k)
            guard let buffer = loadPixelBuffer("\(dir)/\(name).jpg") else { continue }
            if let face = centralFace(embedder, buffer) {
                ours.append(face.embedding)
                embedded += 1
            }
            if let alignedDir, let crop = loadPixelBuffer("\(alignedDir)/\(name).png"),
               let e = embedder.embed(aligned: crop) {
                reference.append(e)
                if let mine = ours.last, ours.count == reference.count { agreement.append(PixelWarp.cosine(mine, e)) }
            }
            if let dumpDir, i < 8, let faces = Optional(embedder.debugCrops(in: buffer)), let crop = faces.first,
               let image = cgImage(from: crop) {
                writePNG(image, to: "\(dumpDir)/\(name).png")
            }
        }
        if ours.count == 2 {
            let c = PixelWarp.cosine(ours[0], ours[1])
            if targets[i] { same.append(c) } else { different.append(c) }
        } else {
            missed += 1
        }
        if reference.count == 2 {
            let c = PixelWarp.cosine(reference[0], reference[1])
            if targets[i] { refSame.append(c) } else { refDifferent.append(c) }
        }
    }
    let seconds = Date().timeIntervalSince(start)
    print(String(format: "%d pairs, %d without a usable face in one photo, %.1f ms per photo",
                 limit, missed, seconds * 1000 / Double(max(1, limit * 2))))
    report("our alignment (Vision landmarks)", same, different)
    if alignedDir != nil {
        report("reference alignment", refSame, refDifferent)
        let sorted = agreement.sorted()
        print(String(format: "same photo, ours vs reference crop: cosine p5 %.3f  p50 %.3f  p95 %.3f",
                     percentile(sorted, 0.05), percentile(sorted, 0.5), percentile(sorted, 0.95)))
    }
}

private func report(_ title: String, _ same: [Float], _ different: [Float]) {
    let s = same.sorted(), d = different.sorted()
    print("\n\(title): \(s.count) same-person pairs, \(d.count) different-person pairs")
    print(String(format: "  same      cosine p5 %.3f  p50 %.3f  p95 %.3f", percentile(s, 0.05), percentile(s, 0.5), percentile(s, 0.95)))
    print(String(format: "  different cosine p5 %.3f  p50 %.3f  p95 %.3f  max %.3f", percentile(d, 0.05), percentile(d, 0.5), percentile(d, 0.95), d.last ?? .nan))
    for threshold in stride(from: Float(0.20), through: 0.501, by: 0.05) {
        let accepted = s.filter { $0 >= threshold }.count
        let falseAccepts = d.filter { $0 >= threshold }.count
        let accuracy = Double(accepted + d.count - falseAccepts) / Double(max(1, s.count + d.count))
        print(String(format: "  threshold %.2f: same accepted %5.1f%%  different accepted %5.2f%%  accuracy %.2f%%",
                     threshold, 100 * Double(accepted) / Double(max(1, s.count)),
                     100 * Double(falseAccepts) / Double(max(1, d.count)), 100 * accuracy))
    }
}

private func faceIdentify(_ embedder: FaceEmbedder, _ positional: [String], _ options: [String: String]) {
    guard positional.count >= 2 else { print("need <people dir>"); return }
    let root = positional[1]
    let shots = Int(options["--shots"] ?? "") ?? 1
    let wanted = Int(options["--people"] ?? "") ?? 120
    let probesEach = 4
    let fm = FileManager.default
    func photos(_ person: String) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: "\(root)/\(person)")) ?? []).filter { $0.hasSuffix(".jpg") }.sorted()
    }
    let everyone = ((try? fm.contentsOfDirectory(atPath: root)) ?? []).sorted()
        .filter { photos($0).count >= shots + probesEach }
    let chosen = Array(everyone.prefix(wanted))
    // --probe-scale shrinks the probe photos to imitate a face seen from farther away.
    let probeScale = Double(options["--probe-scale"] ?? "") ?? 1
    var faceWidths: [CGFloat] = []
    func embedding(_ person: String, _ photo: String, scale: Double = 1) -> [Float]? {
        guard var buffer = loadPixelBuffer("\(root)/\(person)/\(photo)") else { return nil }
        if scale != 1 {
            let w = Int(Double(CVPixelBufferGetWidth(buffer)) * scale), h = Int(Double(CVPixelBufferGetHeight(buffer)) * scale)
            guard let small = PixelWarp.warp(buffer, toSource: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale), width: w, height: h) else { return nil }
            buffer = small
        }
        guard let face = centralFace(embedder, buffer) else { return nil }
        if scale != 1 { faceWidths.append(face.pixelWidth) }
        return face.embedding
    }

    // Collect raw scores once, then sweep the decision rule over them.
    struct Probe { let truth: String?; let ranked: [(String, Float)] }
    let store = MemoryStore(url: nil)
    var enrolled: [String] = []
    for (i, person) in chosen.enumerated() where i % 2 == 0 {
        let samples = photos(person).prefix(shots).compactMap { embedding(person, $0) }
        guard !samples.isEmpty else { continue }
        store.remember(person: person, samples: samples)
        enrolled.append(person)
    }
    let gallery = store.people
    var probes: [Probe] = []
    var attempted = 0
    for (i, person) in chosen.enumerated() {
        let known = i % 2 == 0 && enrolled.contains(person)
        if i % 2 == 0, !known { continue }
        let list = known ? Array(photos(person).dropFirst(shots).prefix(probesEach)) : Array(photos(person).prefix(probesEach))
        for photo in list {
            attempted += known ? 1 : 0
            guard let e = embedding(person, photo, scale: probeScale) else { continue }
            let ranked = gallery
                .map { ($0.name, $0.samples.map { PixelWarp.cosine($0, e) }.max() ?? -1) }
                .sorted { $0.1 > $1.1 }
            probes.append(Probe(truth: known ? person : nil, ranked: ranked))
        }
    }
    let knownCount = probes.filter { $0.truth != nil }.count
    let strangerCount = probes.count - knownCount
    if probeScale != 1 {
        let widths = faceWidths.sorted()
        print(String(format: "probe scale %.2f: median face width %.0f px; %d of %d known probes had no usable face",
                     probeScale, Double(widths.isEmpty ? 0 : widths[widths.count / 2]), attempted - probes.filter { $0.truth != nil }.count, attempted))
    }
    print("\(enrolled.count) people enrolled with \(shots) photo(s) each; \(knownCount) photos of them, \(strangerCount) photos of \(chosen.count - enrolled.count) strangers")
    print("threshold margin | known: right  missed  wrong name | strangers given a name")
    for threshold in [Float(0.30), 0.35, 0.40, 0.45, 0.50] {
        for margin in [Float(0), 0.05] {
            var right = 0, missed = 0, wrong = 0, strangersNamed = 0
            for probe in probes {
                var decision: String?
                if let best = probe.ranked.first, best.1 >= threshold,
                   probe.ranked.count < 2 || best.1 - probe.ranked[1].1 >= margin {
                    decision = best.0
                }
                switch (probe.truth, decision) {
                case let (truth?, name?): if truth == name { right += 1 } else { wrong += 1 }
                case (_?, nil): missed += 1
                case (nil, _?): strangersNamed += 1
                case (nil, nil): break
                }
            }
            print(String(format: "   %.2f    %.2f  |      %5.1f%%  %5.1f%%   %5.1f%%    |   %5.1f%%", threshold, margin,
                         100 * Double(right) / Double(max(1, knownCount)), 100 * Double(missed) / Double(max(1, knownCount)),
                         100 * Double(wrong) / Double(max(1, knownCount)), 100 * Double(strangersNamed) / Double(max(1, strangerCount))))
        }
    }
}

/// Checks of the frame-to-frame logic with scripted match scores (no model needed).
///   eyes-cli faces tracker
private func faceTrackerChecks() {
    var failures = 0
    func check(_ what: String, _ ok: Bool, _ detail: String = "") {
        if !ok { failures += 1 }
        print(ok ? "ok    " : "FAIL  ", what, detail)
    }
    let here = CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.25)
    /// One frame showing one face that scores `score` against `name` (and less against "Other").
    func frame(_ name: String, _ score: Float, at box: CGRect = here, width: CGFloat = 120) -> [FaceTracker.Observation] {
        let match: MemoryMatch? = score >= MemoryStore.faceMaybeThreshold
            ? MemoryMatch(name: name, score: score, tentative: score < MemoryStore.faceThreshold) : nil
        return [FaceTracker.Observation(box: box, pixelWidth: width, candidates: [(name, score), ("Other", 0.05)], match: match)]
    }
    let start = Date()
    func run(_ steps: [(TimeInterval, [FaceTracker.Observation])]) -> [FaceTracker.Verdict?] {
        var tracker = FaceTracker()
        return steps.map { tracker.update($0.1, at: start.addingTimeInterval($0.0)).first }
    }
    func said(_ v: FaceTracker.Verdict?) -> String { v.map { ($0.name ?? "unknown") + ($0.tentative ? "?" : "") } ?? "none" }

    var out = run([(0, frame("Sarah", 0.6)), (0.4, frame("Sarah", 0.27)), (0.8, frame("Sarah", 0.25)), (1.2, frame("Sarah", 0.55))])
    check("a sure name survives two poor frames", out.map(said) == ["Sarah", "Sarah", "Sarah", "Sarah"], "\(out.map(said))")

    out = run([(0, frame("Sarah", 0.6)), (0.4, frame("Sarah", 0.15))])
    check("but not a frame that looks like a stranger", said(out[1]) == "unknown", "\(out.map(said))")

    out = run([(0, frame("Sarah", 0.6)), (0.4, frame("Tom", 0.27))])
    check("nor a frame where someone else is the best match", said(out[1]) == "unknown", "\(out.map(said))")

    out = run([(0, frame("Sarah", 0.6)), (1, frame("Sarah", 0.26)), (2, frame("Sarah", 0.26)), (3, frame("Sarah", 0.26)),
               (3.9, frame("Sarah", 0.26)), (4.5, frame("Sarah", 0.26))])
    check("a held name lapses after four seconds without a sure frame",
          out.map(said) == ["Sarah", "Sarah", "Sarah", "Sarah", "Sarah", "unknown"], "\(out.map(said))")

    out = run([(0, frame("Sarah", 0.32)), (0.4, frame("Sarah", 0.33)), (0.8, frame("Sarah", 0.31)), (1.2, frame("Sarah", 0.26))])
    check("three probable frames in a row become sure, and are then held", out.map(said) == ["Sarah?", "Sarah?", "Sarah", "Sarah"], "\(out.map(said))")

    out = run([(0, frame("Sarah", 0.32)), (0.4, frame("Sarah", 0.2)), (0.8, frame("Sarah", 0.32)), (1.2, frame("Sarah", 0.32))])
    check("an unknown frame restarts that count", out.map(said) == ["Sarah?", "unknown", "Sarah?", "Sarah?"], "\(out.map(said))")

    out = run([(0, frame("Sarah", 0.6)), (0.4, frame("Sarah", 0.26, at: here.offsetBy(dx: 0.4, dy: 0)))])
    check("a face somewhere else in the view does not inherit the name", said(out[1]) == "unknown", "\(out.map(said))")

    out = run([(0, frame("Sarah", 0.6)), (2.0, frame("Sarah", 0.26))])
    check("nor does a face that reappears after a gap", said(out[1]) == "unknown", "\(out.map(said))")

    func learned(_ steps: [(TimeInterval, [FaceTracker.Observation])]) -> [String] { run(steps).map { $0?.learnAs ?? "-" } }
    var views = learned((0...8).map { (Double($0), frame("Sarah", 0.6)) })
    check("learns from the second sure sighting, then at most every three seconds",
          views == ["-", "Sarah", "-", "-", "Sarah", "-", "-", "Sarah", "-"], "\(views)")
    views = learned([(0, frame("Sarah", 0.6)), (1, frame("Sarah", 0.9)), (2, frame("Sarah", 0.4)), (3, frame("Sarah", 0.6, width: 40))])
    check("never from a near-copy, a weak match or a small face", views == ["-", "-", "-", "-"], "\(views)")
    print(failures == 0 ? "all tracker checks pass" : "\(failures) tracker checks FAILED")
}

/// What Vision reports for the faces it finds in a folder of photos (searched one level deep): how
/// sure it is each is a face, and its capture quality. Run on photos with and without people to see
/// what separates real faces from things that merely resemble one.
///   eyes-cli faces quality <arcface.mlpackage> <dir> [--limit N]
private func faceQuality(_ embedder: FaceEmbedder, _ positional: [String], _ options: [String: String]) {
    guard positional.count >= 2 else { print("need <dir>"); return }
    let fm = FileManager.default
    var paths: [String] = []
    for entry in ((try? fm.contentsOfDirectory(atPath: positional[1])) ?? []).sorted() {
        let path = "\(positional[1])/\(entry)"
        var isDirectory: ObjCBool = false
        fm.fileExists(atPath: path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            paths += ((try? fm.contentsOfDirectory(atPath: path)) ?? []).filter { $0.hasSuffix(".jpg") }.sorted().prefix(1).map { "\(path)/\($0)" }
        } else if entry.hasSuffix(".jpg") || entry.hasSuffix(".png") {
            paths.append(path)
        }
    }
    paths = Array(paths.prefix(Int(options["--limit"] ?? "") ?? 300))
    embedder.minFaceWidth = 20
    var confidences: [Float] = [], qualities: [Float] = [], widths: [Float] = []
    var photosWithFace = 0
    for path in paths {
        guard let buffer = loadPixelBuffer(path) else { continue }
        let faces = embedder.faces(in: buffer, limit: 6, measuringQuality: true)
        if !faces.isEmpty { photosWithFace += 1 }
        for face in faces {
            confidences.append(face.confidence)
            qualities.append(face.quality ?? -1)
            widths.append(Float(face.pixelWidth))
            if options["--list"] != nil {
                print(String(format: "  %@  width %.0f  confidence %.2f  quality %.2f", (path as NSString).lastPathComponent, face.pixelWidth, face.confidence, face.quality ?? -1))
            }
        }
    }
    let c = confidences.sorted(), q = qualities.sorted()
    print("\(paths.count) photos, \(photosWithFace) with at least one face found, \(c.count) faces")
    print(String(format: "  confidence  min %.2f  p5 %.2f  p50 %.2f  p95 %.2f", c.first ?? .nan, percentile(c, 0.05), percentile(c, 0.5), percentile(c, 0.95)))
    print(String(format: "  quality     min %.2f  p5 %.2f  p50 %.2f  p95 %.2f", q.first ?? .nan, percentile(q, 0.05), percentile(q, 0.5), percentile(q, 0.95)))
}

/// End-to-end checks of MemoryEngine with real photos: enrol, recognise, reject, rename, persist.
///   eyes-cli faces engine <arcface.mlpackage> <people dir> <photo without a face> <yoloe26m.mlpackage> <yoloe_labels.json>
private func faceEngineChecks(_ embedder: FaceEmbedder, _ positional: [String]) {
    guard positional.count >= 5, let detector = try? ObjectDetector(compiledModel: compileModel(positional[3]), labels: URL(fileURLWithPath: positional[4])) else {
        print("need <people dir> <photo without a face> <yoloe26m.mlpackage> <yoloe_labels.json>")
        return
    }
    let root = positional[1]
    let fm = FileManager.default
    func snapshot(_ frame: CVPixelBuffer?) -> Snapshot? {
        frame.map { Snapshot(frame: $0, detections: detector.detect(in: $0), depth: nil) }
    }
    func photos(_ person: String) -> [Snapshot] {
        ((try? fm.contentsOfDirectory(atPath: "\(root)/\(person)")) ?? []).filter { $0.hasSuffix(".jpg") }.sorted()
            .prefix(8).compactMap { snapshot(loadPixelBuffer("\(root)/\(person)/\($0)")) }
    }
    let rich = ((try? fm.contentsOfDirectory(atPath: root)) ?? []).sorted().filter {
        ((try? fm.contentsOfDirectory(atPath: "\(root)/\($0)")) ?? []).count >= 8
    }
    guard rich.count >= 3 else { print("need three people with 8+ photos"); return }
    // LFW photos are small and dated, and some fall below the enrolment bar; the checks that expect
    // an enrolment to succeed use only photos that meet it (the refusal checks do not care).
    func meetsBar(_ shot: Snapshot) -> Bool {
        guard let face = embedder.faces(in: shot.frame, measuringQuality: true).first else { return false }
        let centre = CGPoint(x: face.box.midX, y: face.box.midY)
        return face.pixelWidth >= MemoryEngine.enrollFaceWidth && (face.quality ?? 0) >= MemoryEngine.enrollFaceQuality
            && shot.detections.contains { ($0.label == "person" || $0.label == "face") && $0.box.insetBy(dx: -0.03, dy: -0.03).contains(centre) }
    }
    let everyone = [photos(rich[0]), photos(rich[1]), photos(rich[2])]
    let good = everyone.map { $0.filter(meetsBar) }
    print("\(good.map(\.count).reduce(0, +)) of \(everyone.map(\.count).reduce(0, +)) photos meet the enrolment bar")
    guard good.allSatisfy({ $0.count >= 6 }) else { print("need six usable photos per person; got \(good.map(\.count))"); return }
    let a = good[0], b = good[1], c = good[2]
    let file = fm.temporaryDirectory.appendingPathComponent("eyes-memory-test-\(UUID().uuidString).json")
    defer { try? fm.removeItem(at: file) }
    let engine = MemoryEngine(store: MemoryStore(url: file), faceEmbedder: embedder)

    var failures = 0
    func check(_ what: String, _ ok: Bool, _ detail: String = "") {
        if !ok { failures += 1 }
        print(ok ? "ok    " : "FAIL  ", what, detail)
    }
    func feed(_ shots: [Snapshot?]) -> () -> Snapshot? {
        var queue = shots
        return { queue.isEmpty ? nil : queue.removeFirst() }
    }
    func shrink(_ shot: Snapshot, _ scale: Double) -> Snapshot? {
        snapshot(PixelWarp.warp(shot.frame, toSource: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale),
                                width: Int(Double(CVPixelBufferGetWidth(shot.frame)) * scale), height: Int(Double(CVPixelBufferGetHeight(shot.frame)) * scale)))
    }
    let wall = snapshot(loadPixelBuffer(positional[2]))
    let done = DispatchSemaphore(value: 0)
    Task {
        var outcome = await engine.remember(person: "Alpha", first: a[0], live: feed([a[1], a[2], a[3]]))
        if case .remembered(let n, nil, false) = outcome { check("enrol Alpha from four frames", n >= 2, "(\(n) samples)") } else { check("enrol Alpha", false, "\(outcome)") }
        check("a thumbnail is kept", (engine.store.people.first?.thumbnail?.count ?? 0) > 500)

        var seen = await engine.whoIsHere(frame: a[4].frame, depth: nil)
        check("recognise Alpha in a new photo", seen.first?.name == "Alpha" && seen.first?.tentative == false, "\(seen.map { $0.name ?? "unknown" })")
        seen = await engine.whoIsHere(frame: b[0].frame, depth: nil)
        check("a stranger gets no name", seen.count == 1 && seen[0].name == nil)

        outcome = await engine.remember(person: "Bravo", first: b[0], live: feed([b[1], c[0], b[2]]))
        if case .remembered(let n, nil, false) = outcome { check("enrol Bravo, ignoring a frame of someone else", n == 3, "(\(n) samples)") } else { check("enrol Bravo", false, "\(outcome)") }
        seen = await engine.whoIsHere(frame: b[4].frame, depth: nil)
        check("recognise Bravo", seen.first?.name == "Bravo")
        seen = await engine.whoIsHere(frame: a[5].frame, depth: nil)
        check("still recognise Alpha with two people enrolled", seen.first?.name == "Alpha")
        seen = await engine.whoIsHere(frame: c[1].frame, depth: nil)
        check("third person is still a stranger", seen.first?.name == nil)

        // Learning extra views, on a separate memory so it does not disturb the checks around it.
        // Each person is introduced with two photos and then seen in their others; whether a photo is
        // learned depends on its score (sure, but not a near-copy of a stored view).
        let learner = MemoryEngine(store: MemoryStore(url: nil), faceEmbedder: embedder)
        var learnedTotal = 0, expected = 0
        for (index, shots) in good.enumerated() {
            let name = "Person \(index)"
            _ = await learner.remember(person: name, first: shots[0], live: feed([shots[1]]))
            var scores: [Float] = []
            for shot in shots.dropFirst(2) {
                // The same photo twice: the first sighting establishes the track, the second may be learned from.
                _ = await learner.whoIsHere(frame: shot.frame, depth: nil)
                scores.append((await learner.whoIsHere(frame: shot.frame, depth: nil)).first?.score ?? -1)
                try? await Task.sleep(for: .milliseconds(3100))
            }
            let learned = learner.store.people.first { $0.name == name }?.learned?.count ?? 0
            learnedTotal += learned
            expected += scores.filter { FaceTracker.learnScores.contains($0) }.count > 0 ? 1 : 0
            print("       \(name): other photos matched at \(scores.map { String(format: "%.2f", $0) }.joined(separator: " ")), \(learned) views learned")
        }
        check("seeing known people at new angles adds views of them", learnedTotal >= expected && (expected == 0 || learnedTotal > 0),
              "(\(learnedTotal) learned, \(expected) people had a photo worth learning)")
        let total = learner.store.people.map { $0.learned?.count ?? 0 }.reduce(0, +)
        _ = await learner.whoIsHere(frame: wall!.frame, depth: nil)
        check("learned views never exceed the cap", learner.store.people.allSatisfy { ($0.learned?.count ?? 0) <= MemoryStore.maxLearned } && total == learnedTotal)

        outcome = await engine.remember(person: "Alfie", first: a[3], live: feed([a[4], a[5]]))
        if case .remembered(_, "Alpha"?, _) = outcome { check("same face, new name renames", true) } else { check("same face, new name renames", false, "\(outcome)") }
        check("only Alfie and Bravo remain", Set(engine.store.people.map(\.name)) == ["Alfie", "Bravo"], "\(engine.store.people.map(\.name))")
        outcome = await engine.remember(person: "Alfie Oh Wait", first: a[3], live: feed([a[4], a[5]]))
        check("the same name with stray words after it is not a rename", engine.store.people.map(\.name).sorted() == ["Alfie", "Bravo"], "\(outcome) \(engine.store.people.map(\.name))")

        // The cases that must NOT store anyone.
        outcome = await engine.remember(person: "Nobody", first: wall, live: feed([wall, wall]))
        if case .nothingInView = outcome { check("no face in view", true) } else { check("no face in view", false, "\(outcome)") }
        outcome = await engine.remember(person: "Ghost", first: c[0], live: feed([wall, wall, wall, wall, wall, wall]))
        if case .remembered = outcome { check("a face only in the first frame, then a wall, is refused", false, "\(outcome)") } else { check("a face only in the first frame, then a wall, is refused", true, "(\(outcome))") }
        outcome = await engine.remember(person: "Glimpse", first: wall, live: feed([c[0], wall, wall, wall, wall, wall]))
        if case .remembered = outcome { check("a face in a single frame is refused", false, "\(outcome)") } else { check("a face in a single frame is refused", true, "(\(outcome))") }
        outcome = await engine.remember(person: "Far", first: shrink(c[0], 0.45), live: feed([shrink(c[1], 0.45), shrink(c[2], 0.45)]))
        if case .tooFar = outcome { check("small face is refused as too far", true) } else { check("small face is refused as too far", false, "\(outcome)") }
        let undetected = Snapshot(frame: c[0].frame, detections: [], depth: nil)
        outcome = await engine.remember(person: "Poster", first: undetected, live: feed([undetected, undetected]))
        if case .unclear = outcome { check("a face the object detector does not confirm is refused", true) } else { check("a face the object detector does not confirm is refused", false, "\(outcome)") }
        check("refused enrolments stored nothing", engine.store.people.count == 2, "\(engine.store.people.map(\.name))")

        let reloaded = MemoryEngine(store: MemoryStore(url: file), faceEmbedder: embedder)
        seen = await reloaded.whoIsHere(frame: b[5].frame, depth: nil)
        check("memory survives a restart", seen.first?.name == "Bravo")
        check("forget removes a person", reloaded.store.forget("bravo") == "Bravo" && reloaded.store.people.map(\.name) == ["Alfie"])
        seen = await reloaded.whoIsHere(frame: b[5].frame, depth: nil)
        check("forgotten person is a stranger again", seen.first?.name == nil)
        print(failures == 0 ? "all engine checks pass" : "\(failures) engine checks FAILED")
        done.signal()
    }
    done.wait()
}

private func cgImage(from buffer: CVPixelBuffer) -> CGImage? {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let context = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer), width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    return context?.makeImage()
}
