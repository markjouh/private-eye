import CoreGraphics
import Foundation

/// Prints how each question would be routed, then checks the replies built by code: the crossing
/// reply, the distance straight ahead, and who is in view.
func runSafetyMode(_ questions: [String]) {
    for q in questions { print(Surroundings.isSafetyQuestion(q) ? "SAFETY " : "model  ", q) }
    let sample = [
        Detection(label: "car", confidence: 0.8, box: CGRect(x: 0.05, y: 0.4, width: 0.25, height: 0.2), distance: 3.8),
        Detection(label: "bus", confidence: 0.3, box: CGRect(x: 0.7, y: 0.3, width: 0.3, height: 0.3), distance: nil),
        Detection(label: "traffic light", confidence: 0.6, box: CGRect(x: 0.45, y: 0.1, width: 0.05, height: 0.1), distance: nil),
        Detection(label: "chair", confidence: 0.9, box: CGRect(x: 0.4, y: 0.5, width: 0.2, height: 0.3), distance: 1.24),
        Detection(label: "person", confidence: 0.9, box: CGRect(x: 0.7, y: 0.2, width: 0.2, height: 0.6), distance: 2.6),
    ]
    let replies = [sample, Array(sample.suffix(2)), []].map { Surroundings.safetyReply(for: $0) }
    for reply in replies { print("reply:  ", reply) }
    // The two things a safety reply must always do, whatever its wording.
    let declines = replies.allSatisfy { $0.hasPrefix("Can't judge") }
    let neverSafe = replies.allSatisfy { $0.range(of: "safe", options: .caseInsensitive) == nil }
    print("declines to judge:", declines ? "ok" : "FAILED", " never says safe:", neverSafe ? "ok" : "FAILED")

    // The other replies built from measurements rather than by the model.
    var failed = 0
    func check(_ what: String, _ got: String, _ want: String) {
        if got != want { failed += 1 }
        print(got == want ? "ok     " : "FAILED ", "\(what): \(got)\(got == want ? "" : "  (expected: \(want))")")
    }
    check("how far, measured", Surroundings.howFar(1.3), "4 feet straight ahead.")
    check("how far, out of range", Surroundings.howFar(nil), "Nothing within 16 feet straight ahead.")

    func person(_ x: CGFloat, _ width: CGFloat = 0.2) -> Detection {
        Detection(label: "person", confidence: 0.9, box: CGRect(x: x, y: 0.2, width: width, height: 0.6), distance: nil)
    }
    func face(_ name: String?, _ x: CGFloat, tentative: Bool = false) -> RecognizedFace {
        RecognizedFace(box: CGRect(x: x, y: 0.25, width: 0.08, height: 0.1), name: name, tentative: tentative, distance: nil, score: 0.6)
    }
    let chair = sample[3]
    check("nobody: objects are the model's to describe", SceneDescription.known(detections: [chair], faces: []), "")
    check("a stranger", SceneDescription.known(detections: [chair, person(0.7)], faces: [face(nil, 0.76)]), "Person to your right.")
    check("someone known", SceneDescription.known(detections: [person(0.7)], faces: [face("Sarah", 0.76)]), "Sarah to your right.")
    check("a tentative match", SceneDescription.known(detections: [person(0.4)], faces: [face("Sarah", 0.46, tentative: true)]), "Possibly Sarah ahead.")
    check("a known face without a body box", SceneDescription.known(detections: [], faces: [face("Sarah", 0.1)]), "Sarah to your left.")
    check("names before strangers", SceneDescription.known(detections: [person(0.0), person(0.6, 0.35)], faces: [face("Sarah", 0.06)]),
          "Sarah to your left. Person to your right.")
    check("names alone, for saying at once", SceneDescription.names(detections: [person(0.0), person(0.6, 0.35)], faces: [face("Sarah", 0.06)]),
          "Sarah to your left.")
    check("the rest, said after them", SceneDescription.others(detections: [person(0.0), person(0.6, 0.35)], faces: [face("Sarah", 0.06)]),
          "Person to your right.")
    check("no names, nothing said early", SceneDescription.names(detections: [person(0.7)], faces: [face(nil, 0.76)]), "")
    check("two strangers together", SceneDescription.known(detections: [person(0.35), person(0.45)], faces: []), "2 people ahead.")
    check("a group", SceneDescription.known(detections: [person(0.0), person(0.3), person(0.6), person(0.75)], faces: [face("Sarah", 0.36)]),
          "Sarah ahead. 4 people in view.")
    let bottle = CGRect(x: 0.05, y: 0.5, width: 0.15, height: 0.3)
    check("their own things, each said once, an unsure match as such",
          SceneDescription.known(detections: [person(0.7)], faces: [], belongings: [
              FoundBelonging(name: "water bottle", box: bottle, distance: 0.5, tentative: false, score: 0.8),
              FoundBelonging(name: "water bottle", box: bottle.insetBy(dx: 0.01, dy: 0.01), distance: 0.5, tentative: false, score: 0.75),
              FoundBelonging(name: "keys", box: bottle, distance: 0.5, tentative: true, score: 0.62)]),
          "Person to your right. Your water bottle to your left. Possibly your keys to your left.")
    // "What is this?" and a tap on a close-up: the user's own thing, when the camera is pointed at it.
    let middle = CGRect(x: 0.2, y: 0.25, width: 0.6, height: 0.45)
    func thing(_ name: String, _ box: CGRect, tentative: Bool = false) -> FoundBelonging {
        FoundBelonging(name: name, box: box, distance: 0.5, tentative: tentative, score: tentative ? 0.67 : 0.8)
    }
    check("pointed at their own thing", MemoryReplies.thisIs([thing("jacket", middle)]) ?? "nil", "Your jacket.")
    check("pointed at it, an unsure match", MemoryReplies.thisIs([thing("jacket", middle, tentative: true)]) ?? "nil", "Possibly your jacket.")
    check("their thing off to one side", MemoryReplies.thisIs([thing("water bottle", bottle)]) ?? "nil", "nil")
    check("their thing behind what is held up",
          MemoryReplies.thisIs([thing("water bottle", CGRect(x: 0.48, y: 0.05, width: 0.27, height: 0.47))]) ?? "nil", "nil")
    check("two of their things, the one in the middle",
          MemoryReplies.thisIs([thing("water bottle", bottle), thing("jacket", middle, tentative: true)]) ?? "nil", "Possibly your jacket.")
    print(failed == 0 ? "all code-built replies ok" : "\(failed) FAILED")
}
