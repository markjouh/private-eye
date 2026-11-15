import CoreGraphics
import Foundation

/// The words spoken for memory features. Built by code, never by the language model, so they are
/// short, predictable and only state what was actually measured.
enum MemoryReplies {
    /// "Sarah, 3 feet ahead." in the house style (see `AnswerStyle`).
    private static func located(_ who: String, _ face: RecognizedFace) -> String {
        Surroundings.phrase(who, distance: face.distance, side: Surroundings.side(of: face.box)) + "."
    }

    // MARK: People

    static func who(_ faces: [RecognizedFace]) -> String {
        guard !faces.isEmpty else { return "No one in view." }
        let known = faces.filter { $0.name != nil }
        let strangers = faces.filter { $0.name == nil }
        var parts = known.map { located(($0.tentative ? "Possibly " : "") + $0.name!, $0) }
        switch (known.isEmpty, strangers.count) {
        case (_, 0): break
        case (true, 1): parts.append(located("Unknown person", strangers[0]))
        case (true, let n): parts.append("\(n) people, none known.")
        case (false, 1): parts.append("One unknown.")
        case (false, let n): parts.append("\(n) unknown.")
        }
        return parts.joined(separator: " ")
    }

    /// Answer to "Where is Sarah?" / "Is Sarah here?".
    static func whereIs(_ name: String, among faces: [RecognizedFace]) -> String {
        guard let face = faces.first(where: { $0.name.map(MemoryStore.key) == MemoryStore.key(name) }) else {
            return "\(name) not in view."
        }
        return located((face.tentative ? "Possibly " : "") + name, face)
    }

    static func remembered(person name: String, _ outcome: EnrollOutcome) -> String {
        switch outcome {
        case .remembered(_, let renamedFrom?, _): "\(renamedFrom) renamed to \(name)."
        case .remembered(_, nil, true), .replaced: "Updated \(name)."
        case .remembered(_, nil, false): "Remembered \(name)."
        case .nothingInView: "No face in view."
        case .tooFar: "Too far. Move closer."
        case .unclear: "Couldn't see a face clearly. Try again."
        }
    }

    // MARK: Belongings

    static func remembered(belonging name: String, _ outcome: EnrollOutcome) -> String {
        switch outcome {
        case .remembered(_, let renamedFrom?, _): "Your \(renamedFrom) is now your \(name)."
        case .remembered(_, nil, true): "Updated your \(name)."
        case .remembered(_, nil, false): "Remembered your \(name)."
        // Said differently from "Updated": the old one is gone, which the user should hear.
        case .replaced: "Replaced your \(name) with this one."
        case .nothingInView, .tooFar, .unclear: "I couldn't get a look at it. Point the camera at it and try again."
        }
    }

    /// Answer to "Where is my water bottle?".
    static func whereIs(_ belonging: Belonging, found: FoundBelonging?, now: Date = Date()) -> String {
        if let found {
            let side = Surroundings.side(of: found.box)
            let direction = side == "ahead" ? "ahead" : "to your \(side)"
            let place = found.distance.map { "\(Surroundings.spoken($0)) \(direction)" } ?? direction
            return found.tentative
                ? "That might be your \(belonging.name), \(place)."
                : "Your \(belonging.name) is \(place)."
        }
        guard let seen = belonging.lastSeen else { return "I don't see your \(belonging.name)." }
        var place = ""
        if let surface = seen.near.first(where: { $0.hasPrefix("on:") }) { place += " on the \(surface.dropFirst(3))" }
        if let beside = seen.near.first(where: { !$0.hasPrefix("on:") }) { place += (place.isEmpty ? " near " : ", near ") + article(beside) }
        return "I don't see your \(belonging.name). I last saw it \(ago(seen.date, now: now))\(place)."
    }

    /// The user's thing nearest the middle of the view, which is what "this" refers to.
    static func pointedAt(_ found: [FoundBelonging]) -> FoundBelonging? {
        found.min { hypot($0.box.midX - 0.5, $0.box.midY - 0.5) < hypot($1.box.midX - 0.5, $1.box.midY - 0.5) }
    }

    /// The centre of a thing's outline is within this of the middle of the view (as a fraction of the
    /// view) when the camera is pointed at it. Of 23 turns saved from the phone with one of the user's
    /// things in view, it was what the camera was pointed at in 6, 0.09 or less from the middle each
    /// time, and beside or behind that (a bottle on the desk behind a mask held up) in 17, 0.20 or more.
    static let pointedWithin = 0.15

    /// "Your jacket." when the camera is pointed at one of the user's things, "Possibly your jacket."
    /// when the match is an unsure one. Nil when it is pointed at none of them.
    static func thisIs(_ found: [FoundBelonging]) -> String? {
        guard let thing = pointedAt(found), hypot(thing.box.midX - 0.5, thing.box.midY - 0.5) <= pointedWithin else { return nil }
        return thing.tentative ? "Possibly your \(thing.name)." : "Your \(thing.name)."
    }

    /// Answer to "Whose bottle is this?" / "Is this mine?".
    static func whose(_ found: [FoundBelonging]) -> String {
        guard let thing = pointedAt(found) else { return "Not one I know." }
        return thing.tentative ? "Possibly your \(thing.name)." : "Yours. Your \(thing.name)."
    }

    /// "just now", "5 minutes ago", "2 hours ago", "3 days ago".
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 45 { return "just now" }
        if seconds < 90 { return "a minute ago" }
        if seconds < 3600 { return "\(Int((seconds / 60).rounded())) minutes ago" }
        if seconds < 5400 { return "an hour ago" }
        if seconds < 36 * 3600 { return "\(Int((seconds / 3600).rounded())) hours ago" }
        return "\(Int((seconds / 86400).rounded())) days ago"
    }

    private static func article(_ label: String) -> String {
        if label.hasSuffix("s") && !label.hasSuffix("ss") { return label }
        return ("aeiou".contains(label.first ?? "x") ? "an " : "a ") + label
    }

    // MARK: Memory in general

    static func forgot(_ spoken: String, removed: String?) -> String {
        removed.map { "Forgot \($0)." } ?? "No \(spoken) in memory."
    }

    static func list(people: [String], belongings: [String]) -> String {
        if people.isEmpty && belongings.isEmpty { return "Nothing remembered yet." }
        var parts: [String] = []
        if !people.isEmpty { parts.append("People: \(people.joined(separator: ", ")).") }
        if !belongings.isEmpty { parts.append("Things: \(belongings.joined(separator: ", ")).") }
        return parts.joined(separator: " ")
    }
}
