import CoreGraphics
import Foundation

/// The spoken answer to a tap ("what's in front of me?") has two parts.
///
/// First, what only the app can know: who is there, by the name the user taught it, and which things
/// in view are the user's own. Then the language model describes the scene from the whole frame.
///
/// The detector's list of objects is not spoken. Measured on a session of real taps, it reported
/// things that were not there (a wallet, a handbag, a white cane for a cable) and missed what the
/// phone was pointed at (cans, a phone, a staircase), while the model named those in about six words.
/// The detector's "person" is the exception: the model, left to itself, leaves people out.
enum SceneDescription {
    /// True for spoken questions that ask for the same overview a tap gives.
    static func isOverviewQuestion(_ text: String) -> Bool {
        text.lowercased().range(
            of: #"^\s*(what('s| is| are)? (in front of me|ahead( of me)?|around( me)?|here|in the room|in this room)|what do you see|what can you see|describe (this|the|my)? ?(scene|room|view|area|place|surroundings)?|look around|what('s| is) around( me)?)[\s?.!]*$"#,
            options: .regularExpression) != nil
    }

    /// "Sarah to your right. Person ahead. Your water bottle to your left." Empty when no one and
    /// nothing of the user's is in view. Names come first; the app says those the moment a tap ends
    /// (`names`) and the rest (`others`) once it knows the tap is about the scene.
    static func known(detections: [Detection], faces: [RecognizedFace], belongings: [FoundBelonging] = []) -> String {
        [names(detections: detections, faces: faces), others(detections: detections, faces: faces, belongings: belongings)]
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// "Sarah to your right." for each recognised person, two at most, the nearest first.
    static func names(detections: [Detection], faces: [RecognizedFace]) -> String {
        people(in: detections, faces: faces).filter { $0.name != nil }.prefix(2).map(sentence).joined(separator: " ")
    }

    /// Everyone not named, and the user's own things: "Person ahead.", "2 people to your left.",
    /// "4 people in view." (a group is counted whole, named or not), "Your keys to your right."
    static func others(detections: [Detection], faces: [RecognizedFace], belongings: [FoundBelonging] = []) -> String {
        let everyone = people(in: detections, faces: faces)
        let strangers = everyone.filter { $0.name == nil }
        var sentences: [String]
        if everyone.count > 2 {
            sentences = ["\(everyone.count) people in view."]
        } else if strangers.count == 2, place(strangers[0].box) == place(strangers[1].box) {
            sentences = ["2 people \(place(strangers[0].box))."]
        } else {
            sentences = strangers.map(sentence)
        }
        // Each of the user's things is one object, said once however many outlines matched it.
        var said = Set<String>()
        for thing in belongings where !thing.tentative && said.insert(thing.name).inserted {
            sentences.append("Your \(thing.name) \(place(thing.box)).")
        }
        return sentences.joined(separator: " ")
    }

    private struct Someone {
        /// As it is said: "Sarah", "possibly Sarah", or nil for a stranger.
        let name: String?
        let box: CGRect
    }

    /// Everyone in view, the biggest (nearest) first: the detector's people, named where a recognised
    /// face sits inside the outline, and recognised faces whose body the detector missed.
    private static func people(in detections: [Detection], faces: [RecognizedFace]) -> [Someone] {
        var everyone = detections.filter { $0.label == "person" && $0.confidence >= ObjectDetector.displayConfidence }.map { body -> Someone in
            let face = faces.first { $0.name != nil && body.box.contains(CGPoint(x: $0.box.midX, y: $0.box.midY)) }
            return Someone(name: face.map { ($0.tentative ? "possibly " : "") + $0.name! }, box: body.box)
        }
        for face in faces {
            guard let name = face.name, !everyone.contains(where: { $0.name?.hasSuffix(name) == true }) else { continue }
            everyone.append(Someone(name: (face.tentative ? "possibly " : "") + name, box: face.box))
        }
        return everyone.sorted { $0.box.width * $0.box.height > $1.box.width * $1.box.height }
    }

    private static func sentence(_ person: Someone) -> String {
        let who = person.name ?? "person"
        return who.prefix(1).uppercased() + who.dropFirst() + " \(place(person.box))."
    }

    /// "ahead", "to your left", "to your right".
    private static func place(_ box: CGRect) -> String {
        let side = Surroundings.side(of: box)
        return side == "ahead" ? "ahead" : "to your \(side)"
    }
}
