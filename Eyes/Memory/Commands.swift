import Foundation

/// Something the user said that the app carries out or answers itself instead of asking the language model.
enum VoiceCommand: Equatable {
    case rememberPerson(name: String)
    case rememberBelonging(name: String)
    case forget(name: String)
    case forgetEverything
    case whoIsThis
    /// "Where is my X?" The caller checks whether X is a remembered belonging before acting on it.
    case findBelonging(name: String)
    case listMemory
    /// Turn the proximity haptics on or off.
    case obstacleWarnings(on: Bool)
    /// "Whose bottle is this?" / "Is this mine?": is the thing in view one of the user's?
    case whoseIsThis
    /// Open the screen that lists what is remembered.
    case showMemory
    /// "What time is it?" and "What's the date?", answered from the phone's clock.
    case tellTime
    case tellDate
    /// "How far is that?", answered from the LiDAR reading straight ahead.
    case howFar
    /// The speaker began a command that changes memory and then took it back ("This is Dana. Oh wait.").
    case cancelled
}

/// Recognises memory commands in a transcript. Deliberately strict: a sentence that does not clearly
/// match stays a question for the language model, because acting on a misheard command (enrolling a
/// stranger as "Great") is worse than answering a question normally.
enum Commands {
    static func parse(_ transcript: String) -> VoiceCommand? {
        // Only the first sentence can be a command; anything after it is the speaker carrying on.
        guard let first = sentences(in: transcript).first else { return nil }
        let command = parse(sentence: clean(first))
        switch command {
        case .rememberPerson, .rememberBelonging, .forget, .forgetEverything:
            // Second thoughts anywhere in what was said mean memory is left alone: learning or
            // forgetting the wrong thing is worse than doing nothing.
            let all = clean(transcript)
            if match(all, #"\b(oh wait|wait|hold on|never ?mind|cancel|scratch that|actually no|no no|not that|i mean)\b"#) != nil {
                return .cancelled
            }
        default:
            break
        }
        return command
    }

    /// The transcript split at sentence ends, leaving titles ("Dr. Lee") whole.
    private static func sentences(in transcript: String) -> [String] {
        var text = transcript
        if let titles = try? NSRegularExpression(pattern: #"\b(Mr|Mrs|Ms|Dr|Prof|St)\."#, options: [.caseInsensitive]) {
            text = titles.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1")
        }
        return text.split(whereSeparator: { ".!?;".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func parse(sentence text: String) -> VoiceCommand? {
        guard !text.isEmpty else { return nil }

        if match(text, #"^(what time is it|what('s| is) the time|do you have the time|tell me the time|what time is it now)$"#) != nil {
            return .tellTime
        }
        if match(text, #"^(what day is it|what('s| is) (the|today's) date|what day is (it )?today|what('s| is) the day today)$"#) != nil {
            return .tellDate
        }
        if match(text, #"^how (far|close|near)\b|^what('s| is) the distance\b"#) != nil {
            return .howFar
        }
        if match(text, #"^whose\b"#) != nil
            || match(text, #"^(is|are) (this|that|these|those|it) (mine|ours|my .+|our .+)$"#) != nil
            || match(text, #"^(does|do) (this|that|these|those|it) belong to me$"#) != nil {
            return .whoseIsThis
        }
        if match(text, #"^(please )?(show|open|go to|bring up) (me )?(my |the |your )?(memories|memory|memory screen|saved things|saved people)$"#) != nil {
            return .showMemory
        }
        let haptics = #"(the )?(haptics?|vibrations?|vibrating|buzzing|tapping|obstacle (warnings?|alerts?)|proximity (warnings?|alerts?))"#
        if let m = match(text, "^(please )?(turn |switch )?\(haptics) (on|off)$") ?? match(text, "^(please )?(turn|switch) (on|off) \(haptics)$") {
            return .obstacleWarnings(on: m.contains { $0.lowercased() == "on" })
        }
        if match(text, #"^(please )?stop (buzzing|vibrating|tapping|the (buzzing|vibration|vibrations|haptics))$"#) != nil {
            return .obstacleWarnings(on: false)
        }
        if match(text, #"^(please )?(forget|delete|erase|clear) (everyone|everybody|everything|all|all of (them|it)|your memory|all memories)$"#) != nil {
            return .forgetEverything
        }
        if let m = match(text, #"^(please )?(forget|delete|remove) (about )?(.+)$"#) {
            return .forget(name: display(m[4]))
        }
        if match(text, #"^(who|what) (do|did) you (know|remember)\b"#) != nil
            || match(text, #"^what (things|people|belongings|stuff|objects)\b.*\b(know|remember)\b"#) != nil
            || match(text, #"^list (my |your |the )?(things|people|belongings|memories|memory)$"#) != nil {
            return .listMemory
        }

        // "… my X": a belonging, unless X is a person ("my mom", "my friend Sarah").
        let belongingForms = [
            #"^(please )?(remember|save|memorize|learn) (this|that|these|those|it) (as|is|are) (my|our) (.+)$"#,
            #"^(this|that|these|those|it) (is|are) (my|our) (.+)$"#,
            #"^(please )?(remember|save|memorize|learn) (my|our) (.+)$"#,
            #"^(here is|here are|here's|heres) (my|our) (.+)$"#,
        ]
        for form in belongingForms {
            guard let m = match(text, form), let said = m.last else { continue }
            if let person = relative(said) { return .rememberPerson(name: person) }
            if let thing = thingName(from: said) { return .rememberBelonging(name: thing) }
        }

        // Explicit introductions: the wording alone makes the intent clear.
        let explicitPersonForms = [
            #"^(please )?(remember|save|memorize|learn) (this person|this face|this guy|this man|this woman|this lady|him|her|them|this|that) as (.+)$"#,
            #"^(his|her|their|the|this person's|this guy's) name is (.+)$"#,
            #"^(please )?(remember|save|memorize|learn) (that )?(this|that|he|she) is (.+)$"#,
        ]
        for form in explicitPersonForms {
            if let m = match(text, form), let said = m.last, let name = personName(from: said, requireCapital: false) {
                return .rememberPerson(name: name)
            }
        }
        // Loose introductions ("This is Sarah") also match ordinary remarks ("this is great"), so they
        // only count when the recogniser capitalised the word as a proper name.
        let loosePersonForms = [
            #"^(this|that|he|she) is (.+)$"#,
            #"^(meet|say hi to|say hello to) (.+)$"#,
            #"^(please )?remember (.+)$"#,
        ]
        for form in loosePersonForms {
            if let m = match(text, form), let said = m.last, let name = personName(from: said, requireCapital: true) {
                return .rememberPerson(name: name)
            }
        }

        if match(text, #"^who('s| is| are| am i)\b"#) != nil
            || match(text, #"^who do you see\b"#) != nil
            || match(text, #"\bdo you (recognize|recognise|know) (this|that|him|her|them|who|anyone|anybody|these|those)\b"#) != nil
            || match(text, #"\b(is|are) (this|that|these|those) (someone|somebody|people|anyone) (i|you) know\b"#) != nil
            || match(text, #"\b(anyone|anybody|someone|somebody) (here )?(that )?(i|you) know\b"#) != nil {
            return .whoIsThis
        }

        let findForms = [
            #"^(where is|where are|where's|wheres|where did i (leave|put)|find|locate|look for|search for|do you see|can you see|have you seen|did you see) (my|our) (.+?)( here| around| anywhere| in view| right now| now)?$"#,
            #"^(is|are) (my|our) (.+?) (here|around|around here|in view|nearby|visible|there|anywhere)$"#,
        ]
        for form in findForms {
            if let m = match(text, form) {
                // The thing's name is the capture group after "my"/"our".
                let name = m[m.count - 2].isEmpty ? m[m.count - 1] : m[m.count - 2]
                return .findBelonging(name: name.lowercased())
            }
        }
        return nil
    }

    /// True for "What is this?": worth checking against the user's belongings before asking the model.
    static func asksWhatThisIs(_ transcript: String) -> Bool {
        match(clean(transcript), #"^what('s| is| are) (this|that|it|these|those)( thing| object)?$"#) != nil
    }

    /// The enrolled person whose whereabouts a question asks after ("Where is Sarah?", "Is Tom here?"),
    /// if any. Other questions that mention a name ("What is Sarah wearing?") are left for the model.
    static func personAsked(in transcript: String, among names: [String]) -> String? {
        let text = clean(transcript)
        return names.first { name in
            let n = NSRegularExpression.escapedPattern(for: clean(name))
            return match(text, "^(where is|where's|wheres|find|locate|look for|do you see|can you see|have you seen) \(n)( here| around| anywhere| nearby| now)?$") != nil
                || match(text, "^is \(n) (here|around|around here|nearby|in view|there|in the room|with me)$") != nil
        }
    }

    // MARK: Helpers

    private static let relations: Set<String> = [
        "friend", "wife", "husband", "mom", "mum", "mother", "dad", "father", "brother", "sister", "son",
        "daughter", "boss", "colleague", "coworker", "roommate", "partner", "girlfriend", "boyfriend",
        "teammate", "professor", "teacher", "doctor", "neighbor", "neighbour", "uncle", "aunt", "cousin",
        "grandma", "grandpa", "grandmother", "grandfather", "manager", "nurse", "caregiver", "buddy",
    ]

    /// "friend Sarah" -> "Sarah", "mom" -> "Mom"; nil when the words after "my" are not a person.
    private static func relative(_ words: String) -> String? {
        let parts = words.split(separator: " ").map(String.init)
        guard let first = parts.first, relations.contains(first.lowercased()) else { return nil }
        let rest = parts.dropFirst().joined(separator: " ")
        return personName(from: rest, requireCapital: false) ?? display(first)
    }

    /// Words that start "this is …" remarks which are not introductions.
    private static let notNames: Set<String> = [
        "a", "an", "the", "my", "your", "our", "his", "her", "their", "some", "not", "so", "very", "too",
        "what", "where", "how", "why", "it", "this", "that", "there", "here", "just", "really", "all",
        "great", "good", "bad", "nice", "cool", "weird", "broken", "fine", "ok", "okay", "amazing", "awesome",
        "me", "us", "them", "him", "nothing", "something", "everything", "to", "for", "in", "on", "about",
    ]

    /// Words that follow a name or a thing but are not part of it ("This is Mark like…", "my keys please").
    private static let trailers: Set<String> = [
        "like", "oh", "um", "uh", "er", "erm", "so", "and", "or", "but", "okay", "ok", "right", "yeah", "yes",
        "actually", "no", "sorry", "please", "now", "here", "there", "too", "then", "wait", "well", "i", "you",
        "he", "she", "we", "they", "is", "was", "by", "from", "who", "with", "at", "over", "thanks", "thank",
        "again", "also", "hey", "though", "anyway",
    ]

    /// The name at the start of `said` (at most three words), dropping whatever was said after it.
    /// With `requireCapital`, a word only counts while the recogniser capitalised it as a proper name,
    /// which is what separates "This is Sarah" from "this is great" and "Mark" from "Mark like".
    private static func personName(from said: String, requireCapital: Bool) -> String? {
        var kept: [String] = []
        for word in said.split(separator: " ").map(String.init) where kept.count < 3 {
            let lower = word.lowercased()
            guard word.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "-" }),
                  !trailers.contains(lower), !notNames.contains(lower),
                  !requireCapital || word.first?.isUppercase == true
            else { break }
            kept.append(word)
        }
        return kept.isEmpty ? nil : display(kept.joined(separator: " "))
    }

    /// What the user called a belonging, without trailing chatter ("water bottle please" -> "water bottle").
    private static func thingName(from said: String) -> String? {
        var kept: [String] = []
        for word in said.lowercased().split(separator: " ").map(String.init) where kept.count < 4 {
            if trailers.contains(word) { break }
            kept.append(word)
        }
        return kept.isEmpty ? nil : kept.joined(separator: " ")
    }

    /// Trimmed, single-spaced, without sentence punctuation (apostrophes and hyphens stay).
    private static func clean(_ text: String) -> String {
        let kept = text.unicodeScalars.map { scalar -> Character in
            let c = Character(scalar)
            return (c.isLetter || c.isNumber || c == "'" || c == "-" || c == " ") ? c : " "
        }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    /// Capitalises each word of a name for display and speech.
    private static func display(_ name: String) -> String {
        var words = name.split(separator: " ").map(String.init)
        while let first = words.first, ["my", "the", "our"].contains(first.lowercased()), words.count > 1 { words.removeFirst() }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// Case-insensitive match; returns the capture groups (index 0 is the whole match, missing groups are "").
    private static func match(_ text: String, _ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        return (0..<found.numberOfRanges).map { i in
            Range(found.range(at: i), in: text).map { String(text[$0]) } ?? ""
        }
    }
}
