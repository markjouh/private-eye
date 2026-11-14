import CoreGraphics
import CoreVideo
import Foundation

/// End-to-end checks of belonging memory with real photos: enrol, find, reject, rename, last seen.
///   eyes-cli belongings <dinov3_s.mlpackage> <yoloe26m.mlpackage> <yoloe_labels.json> <objectron dir>
/// The folder holds `{category}_{instance}_{view}.jpg`: several views of each object.
func runBelongingsMode(_ args: [String]) {
    guard args.count >= 4 else {
        print("usage: eyes-cli belongings <dinov3_s.mlpackage> <yoloe26m.mlpackage> <yoloe_labels.json> <objectron dir>")
        return
    }
    do {
        let embedder = try ThingEmbedder(compiledModel: compileModel(args[0]))
        let detector = try ObjectDetector(compiledModel: compileModel(args[1]), labels: URL(fileURLWithPath: args[2]))
        let dir = args[3]
        func shot(_ name: String) -> Snapshot? {
            guard let frame = loadPixelBuffer("\(dir)/\(name).jpg") else { return nil }
            return Snapshot(frame: frame, detections: detector.detect(in: frame), depth: nil)
        }
        func feed(_ names: [String]) -> () -> Snapshot? {
            var queue = names
            return { queue.isEmpty ? nil : shot(queue.removeFirst()) }
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("eyes-belongings-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = MemoryEngine(store: MemoryStore(url: file), thingEmbedder: embedder)

        var failures = 0
        func check(_ what: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failures += 1 }
            print(ok ? "ok    " : "FAIL  ", what, detail)
        }
        func score(_ found: FoundBelonging?) -> String {
            found.map { String(format: "(score %.2f%@)", $0.score, $0.tentative ? ", tentative" : "") } ?? "(not found)"
        }
        let done = DispatchSemaphore(value: 0)
        Task {
            var outcome = await engine.remember(belonging: "water bottle", first: shot("bottle_0_0"), live: feed(["bottle_0_1"]))
            if case .remembered(let n, nil, false) = outcome { check("enrol water bottle from two views", n == 2, "(\(n) samples)") } else { check("enrol water bottle", false, "\(outcome)") }
            let bottle = engine.store.belonging(named: "my water bottle")
            check("stored with the detector's label", bottle?.label == "bottle", "(\(bottle?.label ?? "none"))")

            var found = await engine.find(bottle!, in: [shot("bottle_0_2")!])
            check("find it in a new view", found != nil && found?.tentative == false, score(found))
            found = await engine.find(bottle!, in: [shot("bottle_0_3")!])
            check("find it in another view", found != nil, score(found))
            found = await engine.find(bottle!, in: [shot("laptop_1_0")!])
            check("not found in a photo of a laptop", found == nil, score(found))
            found = await engine.find(bottle!, in: [shot("cup_1_0")!])
            check("not found in a photo of a cup", found == nil, score(found))
            found = await engine.find(bottle!, in: [shot("bottle_5_0")!])
            check("a different bottle is not confidently theirs", found == nil || found!.tentative, score(found))

            let view = shot("bottle_0_2")!
            let inView = await engine.belongings(in: view)
            check("a scan of the frame finds it by name", inView.first?.name == "water bottle", "\(inView.map(\.name))")
            let said = SceneDescription.known(detections: view.detections, faces: [], belongings: inView)
            check("the description calls it theirs", said.contains("Your water bottle"), "→ \(said)")
            check("\"whose is this\" answers yours", MemoryReplies.whose(inView) == "Yours. Your water bottle.", "→ \(MemoryReplies.whose(inView))")
            check("thumbnail saved for the memories screen", (engine.store.belonging(named: "water bottle")?.thumbnail?.count ?? 0) > 500)
            let outline = CGRect(x: 0.1, y: 0.4, width: 0.2, height: 0.3)
            let stacked = ["jacket", "blanket", "towel"].map { Detection(label: $0, confidence: 0.6, box: outline, distance: 0.5) }
            let once = SceneDescription.known(detections: stacked, faces: [], belongings: [
                FoundBelonging(name: "jacket", box: outline, distance: 0.5, tentative: false, score: 0.9)])
            check("one thing under three labels is said once", once == "Your jacket to your left.", "→ \(once)")
            let elsewhere = await engine.belongings(in: shot("laptop_1_0")!)
            check("a scan elsewhere finds nothing", elsewhere.isEmpty, "\(elsewhere.map(\.name))")

            outcome = await engine.remember(belonging: "mug", first: shot("cup_0_0"), live: feed(["cup_0_1"]))
            if case .remembered = outcome { check("enrol a mug", true) } else { check("enrol a mug", false, "\(outcome)") }
            found = await engine.find(engine.store.belonging(named: "mug")!, in: [shot("cup_0_3")!])
            check("find the mug", found != nil, score(found))
            found = await engine.find(engine.store.belonging(named: "water bottle")!, in: [shot("cup_0_3")!])
            check("the bottle is not found where the mug is", found == nil, score(found))
            found = await engine.find(engine.store.belonging(named: "mug")!, in: [shot("laptop_2_1")!, shot("cup_0_2")!])
            check("search falls back to the second frame", found != nil, score(found))

            outcome = await engine.remember(belonging: "flask", first: shot("bottle_0_2"), live: feed([]))
            if case .remembered(_, "water bottle"?, _) = outcome { check("same thing, new name renames", true) } else { check("same thing, new name renames", false, "\(outcome)") }
            check("names are now flask and mug", Set(engine.store.belongings.map(\.name)) == ["flask", "mug"], "\(engine.store.belongings.map(\.name))")

            engine.noticeBelongings(in: shot("cup_0_2")!) { _ in }
            try? await Task.sleep(for: .milliseconds(600))
            let seen = engine.store.belonging(named: "mug")?.lastSeen
            check("noticing the mug records a sighting", seen != nil, seen.map { "(\($0.side), near \($0.near))" } ?? "")
            check("the flask was not sighted there", engine.store.belonging(named: "flask")?.lastSeen == nil)
            let mug = engine.store.belonging(named: "mug")!
            print("       reply when found:    ", MemoryReplies.whereIs(mug, found: FoundBelonging(name: "mug", box: CGRect(x: 0.1, y: 0.4, width: 0.2, height: 0.2), distance: 0.6, tentative: false, score: 0.8)))
            print("       reply when not found:", MemoryReplies.whereIs(mug, found: nil, now: Date().addingTimeInterval(300)))

            let reloaded = MemoryEngine(store: MemoryStore(url: file), thingEmbedder: embedder)
            found = await reloaded.find(reloaded.store.belonging(named: "flask")!, in: [shot("bottle_0_3")!])
            check("memory survives a restart", found != nil, score(found))
            check("forget removes a belonging", reloaded.store.forget("my mug") == "your mug" && reloaded.store.belongings.map(\.name) == ["flask"])
            print(failures == 0 ? "all belonging checks pass" : "\(failures) belonging checks FAILED")
            done.signal()
        }
        done.wait()
    } catch {
        print("belongings failed: \(error)")
    }
}
