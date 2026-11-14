import CoreGraphics
import CoreVideo
import Foundation

/// A face in view, named when it matches someone the user introduced.
struct RecognizedFace: Identifiable {
    let id = UUID()
    /// Normalized to the frame, origin top-left.
    let box: CGRect
    /// nil for someone not recognised.
    let name: String?
    /// True when the match is only probable; say "possibly".
    let tentative: Bool
    var distance: Float?
    /// Similarity to the best-matching known person (also set for faces left unnamed).
    var score: Float?
}

/// A camera frame together with what the detector and LiDAR found in it.
struct Snapshot {
    let frame: CVPixelBuffer
    let detections: [Detection]
    let depth: DepthMap?
}

/// One of the user's belongings located in a frame.
struct FoundBelonging {
    let name: String
    /// Normalized to the frame, origin top-left.
    let box: CGRect
    let distance: Float?
    /// True when it only might be theirs (a look-alike scores this high too); say "might be".
    let tentative: Bool
    let score: Float
}

enum EnrollOutcome {
    /// `renamedFrom` is set when this face was already known under another name, which is replaced.
    case remembered(samples: Int, renamedFrom: String?, alreadyKnown: Bool)
    case nothingInView
    /// The face is too small in the frame to learn reliably.
    case tooFar
    /// Something face-like was there but not clearly enough to learn from.
    case unclear
}

/// Runs face (and belonging) memory off the main thread: learning from the camera when asked, and
/// recognising what is in view.
final class MemoryEngine: @unchecked Sendable {
    let store: MemoryStore

    /// Faces must be at least this wide (pixels) to be learned: enrolment sets the quality ceiling for
    /// every later match, so it is stricter than recognition (FaceEmbedder.minFaceWidth).
    static let enrollFaceWidth: CGFloat = 70
    /// Samples from one enrolment must agree this well, or the frames caught different people.
    static let enrollConsistency: Float = 0.5
    /// Vision's capture quality a face needs to be learned. On LFW (small, dated photos) real faces
    /// score 0.13 / 0.34 / 0.59 at the 5th / 50th / 95th percentile; the one false face found in 208
    /// photos without people scored 0.18 (`eyes-cli faces quality`).
    static let enrollFaceQuality: Float = 0.2

    private let queue = DispatchQueue(label: "eyes.memory", qos: .userInitiated)
    private let lock = NSLock()
    private var faceEmbedder: FaceEmbedder?
    private var thingEmbedder: ThingEmbedder?
    /// Used on the memory queue only.
    private var tracker = FaceTracker()
    private var scanning = false
    private var lastScan = Date.distantPast
    private var watching = false
    private var lastWatch = Date.distantPast
    private var lastLook = Date.distantPast
    private var lastReportedCount = 0

    /// The embedders are for tests; the app loads the bundled models.
    init(store: MemoryStore, faceEmbedder: FaceEmbedder? = nil, thingEmbedder: ThingEmbedder? = nil) {
        self.store = store
        self.faceEmbedder = faceEmbedder
        self.thingEmbedder = thingEmbedder
        // Load ahead of first use; Core ML's first load of a model takes a second or two.
        queue.async {
            _ = self.embedder()
            _ = self.things()
        }
    }

    private func things() -> ThingEmbedder? {
        if thingEmbedder == nil {
            do {
                thingEmbedder = try ThingEmbedder()
                print("[eyes] belonging model runs on compute units \(thingEmbedder!.computeUnits.rawValue)")
            } catch {
                print("[eyes] belonging model failed to load: \(error)")
            }
        }
        return thingEmbedder
    }

    private func embedder() -> FaceEmbedder? {
        if faceEmbedder == nil {
            do { faceEmbedder = try FaceEmbedder() } catch { print("[eyes] face model failed to load: \(error)") }
        }
        return faceEmbedder
    }

    // MARK: Watching the live view

    /// Call with each analysed camera frame (any thread). A few times a second, when someone is in
    /// view and the user has introduced at least one person, it recognises the faces and reports them.
    /// `onFaces` is also called with an empty list once people leave the view.
    func watch(frame: CVPixelBuffer, depth: DepthMap?, detections: [Detection], onFaces: @escaping ([RecognizedFace]) -> Void) {
        let someoneVisible = detections.contains { ($0.label == "person" || $0.label == "face") && $0.confidence >= 0.3 }
        let now = Date()
        lock.lock()
        guard !watching, now.timeIntervalSince(lastWatch) >= 0.35 else { lock.unlock(); return }
        // The detector can miss a face that fills the view, so look anyway every couple of seconds.
        let overdue = now.timeIntervalSince(lastLook) >= 2
        let look = (someoneVisible || overdue) && !store.people.isEmpty
        let hadFaces = lastReportedCount > 0
        lastWatch = now
        if look {
            watching = true
            lastLook = now
        } else if !someoneVisible {
            lastReportedCount = 0
        }
        lock.unlock()
        guard look else {
            if hadFaces, !someoneVisible { onFaces([]) }
            return
        }
        queue.async {
            let faces = self.recognise(in: frame, depth: depth)
            self.lock.lock()
            self.watching = false
            self.lastReportedCount = faces.count
            self.lock.unlock()
            onFaces(faces)
        }
    }

    // MARK: On demand

    /// Everyone in `frame`, largest face first.
    func whoIsHere(frame: CVPixelBuffer, depth: DepthMap?) async -> [RecognizedFace] {
        await run { self.recognise(in: frame, depth: depth) }
    }

    /// Learns the face nearest the middle of the view under `name`. It looks at `first` (the frame from
    /// when the user started speaking) and then at live frames from `live`, a moment apart, so the
    /// person is stored with slightly different expressions and angles.
    ///
    /// A face is only learned on good evidence, because a wrong entry is worse than a retry:
    /// - it must be a real, usable face: wide enough, above `enrollFaceQuality`, and inside a person or
    ///   face box from the object detector (two different models agreeing);
    /// - it must still be in view now, not only in the frame from when the press began (the user may
    ///   have turned to a wall while speaking);
    /// - it must be seen at least twice, the views agreeing with each other.
    func remember(person name: String, first: Snapshot?, live: @escaping () -> Snapshot?) async -> EnrollOutcome {
        var samples: [[Float]] = []
        var thumbnail: Data?
        var sawSmallFace = false, sawPoorFace = false, seenLive = false
        for attempt in 0..<7 where samples.count < 4 {
            if attempt > 1 { try? await Task.sleep(for: .milliseconds(180)) }
            guard let shot = attempt == 0 ? first : live() else { continue }
            let face: FaceObservation? = await run {
                self.embedder()?.faces(in: shot.frame, measuringQuality: true).min { a, b in
                    hypot(a.box.midX - 0.5, a.box.midY - 0.5) < hypot(b.box.midX - 0.5, b.box.midY - 0.5)
                }
            }
            guard let face else {
                print("[eyes] learn \(name): frame \(attempt) has no face")
                continue
            }
            let centre = CGPoint(x: face.box.midX, y: face.box.midY)
            let confirmed = shot.detections.contains {
                ($0.label == "person" || $0.label == "face") && $0.box.insetBy(dx: -0.03, dy: -0.03).contains(centre)
            }
            let agreement = samples.first.map { PixelWarp.cosine($0, face.embedding) }
            print(String(format: "[eyes] learn %@: frame %d face %.0f px wide, quality %.2f, detector %@%@", name, attempt,
                         Double(face.pixelWidth), face.quality ?? -1, confirmed ? "agrees" : "sees no person there",
                         agreement.map { String(format: ", %.2f like the first", $0) } ?? ""))
            guard face.pixelWidth >= Self.enrollFaceWidth else { sawSmallFace = true; continue }
            guard confirmed, (face.quality ?? 0) >= Self.enrollFaceQuality else { sawPoorFace = true; continue }
            if let agreement, agreement < Self.enrollConsistency { continue }
            if samples.isEmpty { thumbnail = PixelWarp.jpeg(face.crop) }
            samples.append(face.embedding)
            if attempt > 0 { seenLive = true }
        }
        guard samples.count >= 2, seenLive else {
            return sawPoorFace ? .unclear : sawSmallFace ? .tooFar : .nothingInView
        }
        // The same face under a different name (a nickname, or the recogniser spelling it differently)
        // would leave two near-identical people that block each other, so the new name replaces the old.
        var name = name
        var renamedFrom: String?
        if let known = store.identify(face: samples[0]), !known.tentative,
           MemoryStore.key(known.name) != MemoryStore.key(name) {
            if MemoryStore.key(name).hasPrefix(MemoryStore.key(known.name) + " ") {
                // The known name with extra words after it is the same name plus stray speech
                // ("Dana" heard as "Dana Oh Wait"), not a rename.
                name = known.name
            } else {
                renamedFrom = known.name
                let old = store.people.first { $0.name == known.name }?.samples ?? []
                _ = store.forget(known.name)
                samples = old + samples
            }
        }
        let existed = store.remember(person: name, samples: samples, thumbnail: thumbnail)
        return .remembered(samples: samples.count, renamedFrom: renamedFrom, alreadyKnown: existed)
    }

    // MARK: Belongings

    /// Views of one thing must agree at least this well during enrolment, or the frames caught
    /// different things (the user moved the phone).
    static let enrollThingConsistency = ThingEmbedder.maybeThreshold
    /// When a newly named thing matches an existing belonging this well it is taken to be that
    /// belonging under a new name. Higher than the accept threshold: at 0.78 about 1% of look-alikes
    /// score this high (see the README's belonging numbers), and wrongly merging two of the user's
    /// things is worse than keeping one thing under two names.
    static let sameThing: Float = 0.78

    /// Learns the thing the phone is pointed at under `name`: the frame from when the user started
    /// speaking, then a few live ones a moment apart, so it is stored from slightly different views.
    func remember(belonging name: String, first: Snapshot?, live: @escaping () -> Snapshot?) async -> EnrollOutcome {
        var samples: [[Float]] = []
        var label: String?
        var thumbnail: Data?
        for attempt in 0..<5 where samples.count < 3 {
            if attempt > 1 { try? await Task.sleep(for: .milliseconds(250)) }
            guard let shot = attempt == 0 ? first : live() else { continue }
            let view: (embedding: [Float], label: String?, picture: Data?)? = await run {
                let region = BelongingTargeting.enrolmentTarget(in: shot.detections, named: name)
                guard let embedding = self.things()?.embed(shot.frame, box: region.box) else { return nil }
                return (embedding, region.label, ThingEmbedder.crop(shot.frame, box: region.box).flatMap(PixelWarp.jpeg))
            }
            guard let view else { continue }
            let agreement = samples.first.map { PixelWarp.cosine($0, view.embedding) }
            print("[eyes] learn \(name): frame \(attempt) took " + (view.label.map { "the \($0)" } ?? "the middle of the view")
                  + (agreement.map { String(format: ", %.2f like the first", $0) } ?? ""))
            if let agreement, agreement < Self.enrollThingConsistency { continue }
            if samples.isEmpty {
                label = view.label
                thumbnail = view.picture
            }
            // A frame identical to one already kept teaches nothing.
            if samples.contains(where: { PixelWarp.cosine($0, view.embedding) > 0.98 }) { continue }
            samples.append(view.embedding)
        }
        guard !samples.isEmpty else { return .nothingInView }

        var renamedFrom: String?
        let twin = store.belongings.first { known in
            MemoryStore.key(known.name) != MemoryStore.key(name)
                && samples.contains { store.similarity(of: $0, to: known) >= Self.sameThing }
        }
        if let twin {
            renamedFrom = twin.name
            _ = store.forget(twin.name)
            samples = twin.samples + samples
        }
        let existed = store.remember(belonging: name, label: label, samples: samples, thumbnail: thumbnail)
        return .remembered(samples: samples.count, renamedFrom: renamedFrom, alreadyKnown: existed)
    }

    /// Looks for one belonging in the given frames, newest first; nil when it is in none of them.
    func find(_ belonging: Belonging, in shots: [Snapshot]) async -> FoundBelonging? {
        for shot in shots {
            let regions = BelongingTargeting.searchCandidates(in: shot.detections, label: belonging.label)
            if let found = await run({ self.match(regions, in: shot, wanted: [belonging], logging: true).first }) { return found }
        }
        return nil
    }

    /// Every belonging of the user's that is in `shot`, including uncertain ("tentative") ones.
    func belongings(in shot: Snapshot) async -> [FoundBelonging] {
        await run { self.scan(shot) }
    }

    /// Call with each analysed camera frame (any thread). Every second or so, when the user has
    /// belongings, it checks which are in view, reports them through `onFound` (an empty list once
    /// they leave), and records where each confident one is, so "where is my …" can still be
    /// answered after the thing has left the view.
    func noticeBelongings(in shot: Snapshot, onFound: @escaping ([FoundBelonging]) -> Void) {
        let now = Date()
        lock.lock()
        guard !scanning, now.timeIntervalSince(lastScan) >= 1.0 else { lock.unlock(); return }
        lastScan = now
        let any = !store.belongings.isEmpty
        if any { scanning = true }
        lock.unlock()
        guard any else { return }
        queue.async {
            let found = self.scan(shot)
            for thing in found where !thing.tentative {
                let sighting = Sighting(date: now, side: Surroundings.side(of: thing.box), distance: thing.distance,
                                        near: Self.neighbours(of: thing.box, in: shot.detections))
                self.store.recordSighting(of: thing.name, sighting)
            }
            self.lock.lock()
            self.scanning = false
            self.lock.unlock()
            onFound(found)
        }
    }

    /// Looks for all of the user's belongings in one frame. The same few regions serve every
    /// belonging, so each region is embedded once.
    private func scan(_ shot: Snapshot) -> [FoundBelonging] {
        let wanted = store.belongings
        guard !wanted.isEmpty else { return [] }
        var regions: [BelongingTargeting.Region] = []
        for label in Set(wanted.map(\.label)) {
            for region in BelongingTargeting.searchCandidates(in: shot.detections, label: label)
            where regions.count < 6 && !regions.contains(where: { $0.box == region.box }) {
                regions.append(region)
            }
        }
        return match(regions, in: shot, wanted: wanted)
    }

    /// Embeds `regions` and returns, for each wanted belonging found among them, its best region.
    /// A region counts when it scores at least `ThingEmbedder.maybeThreshold` and beats every other
    /// belonging of the user's by `ThingEmbedder.margin`, which keeps two similar things of theirs apart.
    private func match(_ regions: [BelongingTargeting.Region], in shot: Snapshot, wanted: [Belonging], logging: Bool = false) -> [FoundBelonging] {
        guard let embedder = things() else { return [] }
        let everything = store.belongings
        var best: [String: FoundBelonging] = [:]
        for region in regions {
            guard let embedding = embedder.embed(shot.frame, box: region.box) else { continue }
            let scores = everything.map { (name: $0.name, score: store.similarity(of: embedding, to: $0)) }
            if logging {
                print("[eyes] looking at \(region.label ?? "the middle of the view"): "
                      + scores.map { String(format: "%@ %.2f", $0.name, $0.score) }.joined(separator: ", "))
            }
            for belonging in wanted {
                guard let own = scores.first(where: { $0.name == belonging.name })?.score, own >= ThingEmbedder.maybeThreshold else { continue }
                let rival = scores.filter { $0.name != belonging.name }.map(\.score).max() ?? -1
                guard own - rival >= ThingEmbedder.margin, own > (best[belonging.name]?.score ?? -1) else { continue }
                best[belonging.name] = FoundBelonging(
                    name: belonging.name, box: region.box, distance: region.distance ?? shot.depth?.distance(in: region.box),
                    tentative: own < ThingEmbedder.acceptThreshold, score: own)
            }
        }
        return wanted.compactMap { best[$0.name] }
    }

    /// What a belonging was sitting on or next to: a surface under it first, then the nearest other thing.
    private static func neighbours(of box: CGRect, in detections: [Detection]) -> [String] {
        let centre = CGPoint(x: box.midX, y: box.midY)
        let others = detections.filter { $0.confidence >= ObjectDetector.displayConfidence && $0.box != box && !["person", "face", "hand"].contains($0.label) }
        let surfaces: Set<String> = ["desk", "table", "bench", "bed", "couch", "shelf", "cabinet", "chair", "stool"]
        var names: [String] = []
        if let under = others.first(where: { surfaces.contains($0.label) && $0.box.insetBy(dx: -0.05, dy: -0.05).contains(centre) }) {
            names.append("on:" + under.label)
        }
        let nearby = others
            .filter { !surfaces.contains($0.label) }
            .min { hypot($0.box.midX - centre.x, $0.box.midY - centre.y) < hypot($1.box.midX - centre.x, $1.box.midY - centre.y) }
        if let nearby, hypot(nearby.box.midX - centre.x, nearby.box.midY - centre.y) < 0.35 { names.append(nearby.label) }
        return names
    }

    // MARK: Internals (memory queue)

    private func recognise(in frame: CVPixelBuffer, depth: DepthMap?) -> [RecognizedFace] {
        guard let embedder = embedder() else { return [] }
        let found = embedder.faces(in: frame)
        let observations = found.map { face in
            FaceTracker.Observation(box: face.box, pixelWidth: face.pixelWidth,
                                    candidates: store.ranked(face: face.embedding), match: store.identify(face: face.embedding))
        }
        let verdicts = tracker.update(observations, at: Date())
        return found.indices.map { i in
            let face = found[i], verdict = verdicts[i], score = observations[i].candidates.first?.score
            if let name = verdict.learnAs {
                store.learn(person: name, view: face.embedding)
                print(String(format: "[eyes] learned another view of %@ (it matched at %.2f)", name, score ?? 0))
            }
            return RecognizedFace(box: face.box, name: verdict.name, tentative: verdict.tentative,
                                  distance: depth?.distance(in: face.box), score: score)
        }
    }

    private func run<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}
