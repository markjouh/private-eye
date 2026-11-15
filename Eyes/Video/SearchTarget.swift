import Foundation

/// What a search is looking for. The kind decides who judges whether it is in view: face memory
/// for someone the user has introduced, belonging memory for one of their own things, and the
/// language model for everything else. Each judge is used alone; none feeds another.
///
/// Why memory judges alone where it can (frames and console log saved from the phone, 2026-11-14):
/// - People: of 360 faces the phone reported as it went, the 245 it named scored 0.26 to 1.00
///   against the person named (88% of them 0.5 or more) and the 115 it left unnamed 0.33 at most
///   (83% of them under 0.2). The model cannot know who "Dana" is at all.
/// - Things: all 23 saved turns with a belonging matched had the box on the right object, and a
///   plastic water bottle standing next to the enrolled steel one in ten of them was never
///   matched, not even as a maybe. Asked for "a water bottle" the model would take either.
enum SearchTarget: Equatable {
    /// Someone the user has introduced, by the name they are stored under.
    case person(String)
    /// One of the user's own things, by the name it is stored under.
    case belonging(String)
    /// Anything else, as a statement about the picture for the language model to agree with.
    /// `thing` is the noun phrase when the user named a thing ("a chair") rather than an event.
    case sight(WatchCondition, thing: String?)

    /// The target for "watch for …" / "help me find …", where `said` is the thing as spoken:
    /// "Dana", "my water bottle", "a chair", "the exit". nil when nothing was said.
    static func named(_ said: String, people: [String], belongings: [String]) -> SearchTarget? {
        let thing = said.trimmingCharacters(in: CharacterSet(charactersIn: " .!?,;:\n\t"))
        guard !thing.isEmpty else { return nil }
        let key = MemoryStore.key(thing)
        // The name alone, or after a word saying who they are: "my friend Sarah".
        if let person = people.first(where: { MemoryStore.key($0) == key })
            ?? people.first(where: { key.split(separator: " ").count == $0.split(separator: " ").count + 1 && key.hasSuffix(" " + MemoryStore.key($0)) }) {
            return .person(person)
        }
        // A belonging is the user's own, so it takes "my": "watch for a water bottle" means any.
        // The bare name counts too ("watch for water bottle"), as speech often drops the "my".
        let first = thing.lowercased().split(separator: " ").first.map(String.init) ?? ""
        if !["a", "an", "any", "some", "another", "someone's", "somebody's"].contains(first),
           let own = belongings.first(where: { MemoryStore.key($0) == key }) {
            return .belonging(own)
        }
        guard let condition = WatchCondition(statement(for: thing)) else { return nil }
        return .sight(condition, thing: thing)
    }

    /// The target for "tell me when …", where `said` is the event: "someone sits in the chair".
    /// "Tell me when you see Dana" and "… when my water bottle is in view" name a thing, and
    /// are judged the way that thing would be.
    static func when(_ said: String, people: [String], belongings: [String]) -> SearchTarget? {
        let event = said.trimmingCharacters(in: CharacterSet(charactersIn: " .!?,;:\n\t"))
        let lower = event.lowercased()
        var thing: String?
        for lead in ["you see ", "you can see ", "you find ", "you spot ", "you notice ", "there is ", "there's ", "there are "] where lower.hasPrefix(lead) {
            thing = String(event.dropFirst(lead.count))
        }
        for tail in [" is in view", " are in view", " is here", " is in sight", " comes into view", " is in front of me", " shows up", " appears"] where lower.hasSuffix(tail) {
            thing = String(event.dropLast(tail.count))
        }
        // "When you see a chair" and "when a chair is in view" ask for the chair. Anything else
        // is left as the user put it: "a chair frees up" is not the same as "a chair".
        if let thing, let found = named(thing, people: people, belongings: belongings) { return found }
        return WatchCondition(event).map { .sight($0, thing: nil) }
    }

    /// The statement put to the model about a thing, in the wording the check was measured with
    /// ("there is a chair in view").
    static func statement(for thing: String) -> String {
        let lower = thing.lowercased()
        let words = lower.split(separator: " ").map(String.init)
        guard let first = words.first, let last = words.last else { return thing }
        if ["someone", "somebody", "anyone", "anybody", "people", "a person", "person", "a human"].contains(lower) {
            return "there is a person in view"
        }
        if ["a", "an", "any", "some", "another"].contains(first) { return "there is \(lower) in view" }
        let several = last.count > 3 && last.hasSuffix("s") && !last.hasSuffix("ss")
        let definite: Set<String> = ["the", "my", "our", "your", "his", "her", "their", "this", "that", "these", "those"]
        // A name or "Sarah's bag" stands as it is, and so does anything already pinned down.
        if definite.contains(first) || first.hasSuffix("'s") || thing.first?.isUppercase == true {
            return "\(thing) \(several && words.count > 1 ? "are" : "is") in view"
        }
        if several { return "there are \(lower) in view" }
        return "there is \("aeiou".contains(first.first ?? "x") ? "an" : "a") \(lower) in view"
    }

    /// The target as said back to the user: "Dana", "your water bottle", "a chair".
    var name: String {
        switch self {
        case .person(let name): return name
        case .belonging(let name): return "your \(name)"
        case .sight(let condition, let thing):
            guard let thing else { return "when \(condition.inSentence)" }
            let lower = thing.lowercased()
            if lower.split(separator: " ").count == 1, thing.first?.isUppercase != true, !lower.hasSuffix("s"),
               !["someone", "somebody", "anyone", "anybody", "people"].contains(lower) {
                return "\("aeiou".contains(lower.first ?? "x") ? "an" : "a") \(lower)"
            }
            // As it was said, capitals and all ("a Canon camera"), but for a leading "A" or "The"
            // and with "my" turned to "your".
            let words = thing.split(separator: " ").map(String.init)
            let said = (["a", "an", "the", "my", "our", "some", "any"].contains(words[0].lowercased()) ? [words[0].lowercased()] + words.dropFirst() : words).joined(separator: " ")
            return said.replacingOccurrences(of: #"\b(my|our)\b"#, with: "your", options: [.regularExpression, .caseInsensitive])
        }
    }

    /// Said when the search starts, so a misheard target is caught at once.
    var starting: String {
        if case .sight(_, nil) = self { return "Watching for \(name)." }
        return "Looking for \(name)."
    }

    /// Said when the time runs out with nothing found.
    var notFound: String {
        if case .sight(_, nil) = self { return "Not seen. Stopped watching." }
        return "Didn't find \(name)."
    }

    /// Said when the model has judged it in view. (People and belongings are announced with where
    /// they are, by `MemoryReplies`.)
    var found: String {
        guard case .sight(let condition, let thing) = self else { return "Found \(name)." }
        return thing == nil ? condition.spoken : "Found \(name)."
    }
}

/// When sightings of a remembered person or thing add up to "found". Memory reports each look as
/// sure, unsure or nothing; a sure sighting is enough on its own, an unsure one must be repeated.
struct SightingJudge {
    enum Verdict: Equatable {
        case nothing
        case found
        /// Seen `unsureNeeded` times running without ever being sure: said as "might be".
        case probablyFound
    }

    /// Unsure sightings in a row that count as found. On the frames saved from the phone the
    /// user's jacket, a soft thing that never looks the same twice, was matched on five turns and
    /// unsure on all five (0.62 to 0.68, the bar for sure being 0.70): a search that waited for a
    /// sure match would have walked past it every time.
    var unsureNeeded = 2
    private var unsure = 0

    mutating func saw(sure: Bool, unsure tentative: Bool) -> Verdict {
        if sure { return .found }
        guard tentative else {
            unsure = 0
            return .nothing
        }
        unsure += 1
        return unsure >= unsureNeeded ? .probablyFound : .nothing
    }
}
