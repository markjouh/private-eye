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
    /// "Tell me when someone sits in the chair": look until it happens, for up to half a minute.
    case watch(condition: String)
    /// "Watch for my bus", "Help me find a chair": the same search, for a thing rather than an event.
    case lookFor(thing: String)
    case stopWatching
    /// "What are you watching for?"
    case watchStatus
    /// "Forget what you just saw": empties the half minute of frames kept for questions about the recent past.
    case forgetRecent
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

    private static func parse(sentence said: String) -> VoiceCommand? {
        guard !said.isEmpty else { return nil }
        let text = withoutLeadIn(said)

        // Searching. These come first: "let me know when this is my stop" is not an introduction.
        // Every way of saying "go and look for this" starts a search: "watch for", "find", "look
        // for", "I can't find", "help me find", "can you find". (On the phone, the first evening,
        // "Look for" with a name, "Look for my jacket" and "Look for a Canon camera" were each said,
        // once after an exclamation, before the one phrase that then worked, "Watch for".) Questions
        // about the view as it is stay questions: "where is my wallet", "do you see my keys".
        if let thing = thingSought(in: withoutRequest(text)) {
            return .lookFor(thing: thing)
        }
        // Only the plain instruction counts as an event to wait for. "Can you tell me when the
        // store closes?" and "tell me if this is milk" want an answer now, and stay questions for
        // the model.
        if let m = match(text, #"^(please )?(tell me|let me know|alert me|notify me|warn me|ping me|say|say so|shout|beep) (when|once|as soon as|whenever) (.+?)( please)?$"#)
            ?? match(text, #"^(please )?(let me know|alert me|notify me|warn me|ping me) (if) (.+?)( please)?$"#)
            ?? match(text, #"^(please )?(watch|wait|keep watching|keep waiting) (until|till|for when|for the moment) (.+?)( please)?$"#) {
            return .watch(condition: m[4])
        }
        let asked = withoutRequest(text)
        if match(asked, #"^(please )?(stop|cancel|end|quit|abort|halt) (watching|looking|searching|scanning|finding|hunting|beeping|the beeping|the beeps|the watch|that watch|watch mode|the search|that search|search mode|the alert|that alert)( for .+)?$"#) != nil
            || match(asked, #"^(never ?mind|forget|forget about|drop) (the|that) (watch|alert|search)$"#) != nil
            || match(asked, #"^(you can )?stop (telling|alerting) me$"#) != nil {
            return .stopWatching
        }
        if match(text, #"^what are you (watching|looking|waiting|searching|scanning|hunting) (for|out for)$"#) != nil
            || match(text, #"^what('s| is| are) (you|we) (looking|searching|watching) for$"#) != nil
            || match(text, #"^are you (still )?(watching|looking|searching)( for (anything|something))?$"#) != nil {
            return .watchStatus
        }
        if match(text, #"^(please )?(forget|clear|erase|delete|wipe) (what you (just )?saw|the (last|past) (few |30 |thirty )?(seconds|minute|minutes)|the (buffer|video|recording|footage)|(the )?recent (video|frames|footage))$"#) != nil {
            return .forgetRecent
        }

        if match(asked, #"^(what time is it|what('s| is) the time|do you have the time|have you got the time|got the time|do you know the time|do you know what time it is|tell me the time|tell me what time it is|the time|time|current time|what('s| is) the current time)( right)?( now)?( please)?$"#) != nil {
            return .tellTime
        }
        if match(asked, #"^(what day is it|which day is it|what date is it|what('s| is) (the|today's) date|what day is (it )?today|what('s| is) the day today|what day of the week is it|what('s| is) today|today's date|the date|tell me the date|tell me what day it is)( today)?( please)?$"#) != nil {
            return .tellDate
        }
        if match(asked, #"^(tell me )?how (far|close|near)\b|^(tell me )?what('s| is) the distance\b|^how many (feet|foot|meters|metres|steps|inches) (away|to|is|are|until|till)\b|^distance (to|from)\b"#) != nil {
            return .howFar
        }
        if match(text, #"^whose\b"#) != nil
            || match(text, #"^(is|are) (this|that|these|those|it) (mine|ours|my .+|our .+)$"#) != nil
            || match(text, #"^(does|do) (this|that|these|those|it) belong to me$"#) != nil
            || match(text, #"^(is|are) (this|that|these|those|it) (one )?of mine$"#) != nil
            || match(text, #"^who (does|do) (this|that|these|those|it) belong to$"#) != nil {
            return .whoseIsThis
        }
        if match(asked, #"^(please )?(show|open|go to|bring up|take me to|pull up) (me )?(my |the |your )?(memories|memory|memory screen|saved things|saved people|settings|voice settings)$"#) != nil {
            return .showMemory
        }
        let haptics = #"(the )?(haptics?|vibrations?|vibrating|buzzing|tapping|obstacle (warnings?|alerts?)|proximity (warnings?|alerts?))"#
        if let m = match(text, "^(please )?(turn |switch )?\(haptics) (on|off)$") ?? match(text, "^(please )?(turn|switch) (on|off) \(haptics)$") {
            return .obstacleWarnings(on: m.contains { $0.lowercased() == "on" })
        }
        if match(asked, #"^(please )?stop (buzzing|vibrating|tapping|the (buzzing|vibration|vibrations|haptics))$"#) != nil {
            return .obstacleWarnings(on: false)
        }
        if let m = match(asked, "^(please )?(enable|activate|start|unmute|disable|deactivate|mute|silence) \(haptics)$") {
            return .obstacleWarnings(on: ["enable", "activate", "start", "unmute"].contains(m[2].lowercased()))
        }
        if match(text, #"^(please )?(forget|delete|erase|clear|wipe|reset) (everyone|everybody|everything|all|all of (them|it)|your memory|the memory|your whole memory|all memories|all (the )?(people|faces|things))$"#) != nil {
            return .forgetEverything
        }
        if let m = match(text, #"^(please )?(forget|delete|remove|erase|unlearn) (about )?(.+)$"#) {
            return .forget(name: display(m[4]))
        }
        if match(text, #"^(who|what) (do|did) you (know|remember)\b"#) != nil
            || match(text, #"^(who|what) (have you|all have you) (met|learned|learnt|saved|remembered|stored|memorized)$"#) != nil
            || match(text, #"^what('s| is) in (your|the) memory$"#) != nil
            || match(text, #"^what (things|people|belongings|stuff|objects)\b.*\b(know|remember)\b"#) != nil
            || match(text, #"^list (my |your |the |all |all the )?(things|people|faces|belongings|memories|memory)$"#) != nil
            || match(asked, #"^(list|name|tell me) (all |all the |all of the )?(everyone|everything|people|things|faces)( that)? you (know|remember|have saved)$"#) != nil {
            return .listMemory
        }

        // "… my X": a belonging, unless X is a person ("my mom", "my friend Sarah").
        let belongingForms = [
            #"^(please )?(remember|save|memorize|learn) (this|that|these|those|it) (as|is|are) (my|our) (.+)$"#,
            #"^(this|that|these|those|it) (is|are) (my|our) (.+)$"#,
            #"^(please )?(remember|save|memorize|learn) (my|our) (.+)$"#,
            #"^(here is|here are|here's|heres) (my|our) (.+)$"#,
            #"^(that's|thats|those are) (my|our) (.+)$"#,
            #"^(please )?(add|track|keep track of|register) (my|our) (.+)$"#,
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
            #"^(his|her|their|the|this person's|this guy's) name's (.+)$"#,
            #"^(this person|this guy|this man|this woman|this lady|he|she) is (called|named) (.+)$"#,
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
            // The same in the contracted forms people use: "That's Tom", "Here's Sarah".
            #"^(that's|thats|he's|she's|here's|heres|here is) (.+)$"#,
            #"^(please )?(call|name) (this person|this guy|this man|this woman|this lady|him|her|them) (.+)$"#,
        ]
        for form in loosePersonForms {
            if let m = match(text, form), let said = m.last, let name = personName(from: said, requireCapital: true) {
                return .rememberPerson(name: name)
            }
        }

        if match(asked, #"^(tell me |do you know |any idea )?who('s| is| are| am i)\b"#) != nil
            || match(asked, #"^(tell me )?who (do|can) you see\b"#) != nil
            || match(asked, #"^(tell me |do you know )?who (this|that|he|she|it) is$"#) != nil
            || match(asked, #"^(name|identify) (this|that|the|these|those) (person|people|guy|man|woman|lady|girl|boy|one|face)$"#) != nil
            || match(text, #"\bdo you (recognize|recognise|know) (this|that|him|her|them|who|anyone|anybody|these|those)\b"#) != nil
            || match(text, #"\b(is|are) (this|that|these|those) (someone|somebody|people|anyone) (i|you) know\b"#) != nil
            || match(text, #"\b(anyone|anybody|someone|somebody) (here )?(that )?(i|you) know\b"#) != nil {
            return .whoIsThis
        }

        let findForms = [
            #"^(where is|where are|where's|wheres|where did i (leave|put)|where have i (left|put)|do you see|can you see|have you seen|did you see|any sign of) (my|our) (.+?)( here| around| anywhere| in view| right now| now)?$"#,
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
            return match(text, "^(where is|where's|wheres|do you see|can you see|have you seen|did you see|any sign of) \(n)( here| around| anywhere| nearby| now)?$") != nil
                || match(text, "^is \(n) (here|around|around here|nearby|in view|there|in the room|with me)$") != nil
        }
    }

    // MARK: Searching

    /// What follows the thing sought and is not part of it.
    private static let afterThing = #"( please| for me| for us| now| right now| again| anywhere| around here)*"#

    /// Every form of "go and look for X", each ending in the thing. The words before the thing
    /// decide; the thing itself can be anything, and is the last group but one.
    private static let seekingForms = [
        // "Watch for", and what it has been heard as: "Watch from my jacket".
        #"^(watch|watch out|look|look out|look around|keep watch|keep watching|keep looking|start watching|start looking|go looking) (for|from|four) (.+?)"#,
        #"^(search|search around|search the room|search this room|search here|scan|scan around|scan the room|scan this room|hunt|hunt around|keep searching|start searching|keep a lookout|keep a look out|keep an eye out|keep your eyes open|keep your eyes peeled|be on the lookout) for (.+?)"#,
        #"^(find me|find us|find|locate|spot|track down|hunt down|seek out|seek) (.+?)"#,
        #"^(i'm|i am|we're|we are) (looking|searching|hunting|watching) for (.+?)"#,
        #"^(i'm|i am|we're|we are) trying to (find|locate|spot) (.+?)"#,
        #"^(i need to|i want to|i have to|i've got to|i gotta|i'd like to|i would like to|we need to|let's|lets|help me|help me to|help us|help us to) (find|look for|locate|spot|search for|track down|watch for) (.+?)"#,
        #"^(i lost|i've lost|i have lost|i dropped|i've dropped|i have dropped|i misplaced|i've misplaced|i have misplaced|i can't find|i cannot find|i can not find|i couldn't find) (.+?)"#,
        #"^(tell me|let me know|say|say so|shout|yell|beep|ping me|alert me|notify me) (when|if|once|as soon as) you (see|can see|find|spot|notice) (.+?)"#,
    ]

    /// Things that cannot be searched for: a word standing in for something only the speaker
    /// knows ("find it"), or a length of time ("watch for a second").
    private static let notThings: Set<String> = [
        "it", "this", "that", "them", "these", "those", "one", "something", "anything", "nothing", "everything",
        "me", "you", "us", "here", "there", "out", "a second", "a sec", "a minute", "a moment", "a bit", "a while", "now",
    ]

    /// The thing a sentence asks to have looked for, or nil when it asks for no search.
    private static func thingSought(in text: String) -> String? {
        for form in seekingForms {
            guard let m = match(text, "^(please )?\(form.dropFirst())\(afterThing)$") else { continue }
            let thing = m[m.count - 2].trimmingCharacters(in: .whitespaces)
            let lower = thing.lowercased()
            // "Find out what this is" and "look for a second" are not searches, and "watch for
            // when the door opens" is an event to wait for, taken further down.
            if thing.isEmpty || notThings.contains(lower) || ["out ", "when ", "the moment "].contains(where: lower.hasPrefix) { return nil }
            return thing
        }
        return nil
    }

    /// The sentence without the words that turn an instruction into a request: "can you find my
    /// keys" asks for what "find my keys" does. Used only for commands that are safe to start on
    /// a request; "can you tell me when the store closes" must stay a question.
    private static func withoutRequest(_ text: String) -> String {
        let request = #"^((can|could|would|will) (you|we)|i want you to|i need you to|i'd like you to|i would like you to|go ahead and|go and|go|try to|try and)( please| just| quickly| also| now)* "#
        guard let regex = try? NSRegularExpression(pattern: request, options: [.caseInsensitive]) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    /// The sentence without what people say before they get to the point: "Okay so", "Hey", and
    /// the exclamation that came before one search on the phone.
    private static func withoutLeadIn(_ text: String) -> String {
        let leadIn = #"^((oh my god|holy shit|holy crap|hey|hi|ok|okay|alright|all right|so|now|um|uh|er|oh|yo|well|and|then|damn|shit|private eye) )+"#
        guard let regex = try? NSRegularExpression(pattern: leadIn, options: [.caseInsensitive]) else { return text }
        let rest = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        return rest.isEmpty ? text : rest
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
            // A possessive is someone's thing, not someone: "This is John's water bottle" was taken
            // as an introduction to "John's".
            guard word.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "-" }), !lower.hasSuffix("'s"),
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
            // The recogniser sometimes writes a typographic apostrophe.
            let c = scalar == "\u{2019}" ? "'" : Character(scalar)
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
