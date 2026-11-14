import Foundation

/// How Eyes talks. Follow this for every reply, generated or built by code.
///
/// Everything is heard, not read, by someone who cannot skim: every word costs time. So replies are
/// telegraphic, the way a sighted guide talks.
///
/// 1. Answer first. No lead-in ("There is", "I can see", "In the image"), no repeating the question.
/// 2. Noun phrases, not sentences: no articles, no "is/are", no "you/your". "Kettle on stove, right."
/// 3. Say where: `left`, `ahead` or `right` (the thirds of the view, `Surroundings.side`), after what
///    it is on or next to. Bare words, not "to your left".
/// 4. A distance only when it was measured, which means only in replies built by code (the model is
///    never asked for one): worded by `Surroundings.spoken`, before the side, with a comma before
///    left/right: "Car, 12 feet, left." "Sarah, 3 feet ahead."
/// 5. Budgets: a direct answer is 3 to 8 words, a description at most 10. Text read aloud is exempt:
///    it is never shortened or reworded.
/// 6. Something asked about that is not in view: "Not visible." A yes/no answer starts "Yes" or "No".
/// 7. People: hair, clothing, what they are doing, where. Never ethnicity, skin colour, age or build,
///    and never a name the user has not taught us.
/// 8. A limit is stated once, plainly: "Can't judge crossing." No apology, no "please", and advice
///    only where safety depends on it.
///
/// LFM3-VL follows an instruction placed after the question, and copies the shape of an example given
/// there, so each kind of question gets its own suffix. `Filter` then enforces the rules on the text
/// as it streams, because the model still slips into full sentences.
enum AnswerStyle {
    enum Kind {
        case read, count, locate, yesNo, person, describe, describeThings, object, general
    }

    /// Sets the register; on its own the model mostly ignores it, but it tightens what the suffixes get.
    static let systemPrompt =
        "You are a sighted guide for a blind person. They show you what their phone camera sees and ask a question. Answer in as few words as you can, without full sentences."

    /// Asked of a frame before describing it, to tell one thing held up to the camera from a scene.
    /// "Am I holding something up?" and "Is one object filling the picture?" were tried first and
    /// said yes to half of all scenes.
    static let closeUpQuestion = "Is this a close-up of one object?"
    static let closeUpSuffix = "Answer \"Yes\" or \"No\"."
    /// What a tap asks when the answer to that is yes.
    static let objectQuestion = "What is this?"

    /// What sort of answer `question` calls for. Order matters: "Can you read this?" is reading, not yes/no.
    static func kind(of question: String) -> Kind {
        // A polite wrapper is not the question: "Can you tell me what this is?" asks what it is, and
        // answered as yes/no it came back "Yes, in hand."
        let q = replace(#"^(please |hey |ok |okay )*(can|could|would|will) you (please )?(tell me|describe|explain|identify|let me know|help me understand)\s+"#,
                        in: question.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), with: "")
        func has(_ pattern: String) -> Bool { q.range(of: pattern, options: .regularExpression) != nil }

        if has(#"\b(read|say|says|written|spell)\b"#) || (has(#"^what\b"#) && has(#"\b(text|label|sign|menu|title|caption)\b"#)) {
            return .read
        }
        if has(#"^how many\b"#) { return .count }
        if has(#"^what('s| is| are) (this|that|it|these|those)( thing| object| item)?[\s?.!]*$"#) || has(#"^what am i holding\b"#) { return .object }
        if has(#"^(where|which side)\b"#) || has(#"\b(where is|where are|where's|find)\b"#) { return .locate }
        if has(#"^(is|are|am|do|does|did|can|could|was|were|has|have|will|should|if|whether)\b"#) { return .yesNo }
        let aboutSomeone = has(#"\b(person|people|man|woman|guy|girl|boy|lady|kid|child|he|she|him|her|they|them|someone|somebody)\b"#)
        if has(#"^who\b|\bwho( is|'s| are)\b"#) || (aboutSomeone && has(#"\b(looks? like|describe|appearance)\b"#)) {
            return .person
        }
        if has(#"\b(in front|ahead|around|nearby|describe|surroundings|what do you see|what can you see|what'?s here|what is here)\b"#) {
            return .describe
        }
        return .general
    }

    /// The instruction appended to the question. Each example fixes the shape of the answer; its nouns
    /// are things rarely in view, because the model sometimes copies them ("on shelf"). No example
    /// has a number in it: one that did made the model invent distances.
    static func suffix(for kind: Kind) -> String {
        switch kind {
        case .read:
            "Read the text exactly as written."
        case .count:
            "Answer with the number and what, like \"Three umbrellas.\""
        case .locate:
            "Name it and say where it is in a few words with left, right or ahead, like \"Hat on shelf, left.\" If it is not in view, say \"Not visible.\""
        case .yesNo:
            "Answer yes or no, then a few words, like \"Yes, on shelf, left.\" or \"No.\""
        case .person:
            "Describe only hair, clothing and what they are doing, like \"Short gray hair, green jacket, reading a book.\""
        case .describe:
            "Name the nearest things and where they are in a few words, like \"Bed ahead, lamp left, door right.\""
        case .describeThings:
            // For a scene whose people the app has already announced. Without the last sentence the
            // model names one of them again in one answer out of six ("Tom ahead. Person center.").
            // "Name the nearest things, not people" was tried and cost the positions ("Table, laptops, cans.").
            "Name the nearest things and where they are in a few words, like \"Bed ahead, lamp left, door right.\" Do not mention people."
        case .object:
            // Asked only to name it, the model says "Water bottle." and leaves out a label in plain view.
            // Asked to "read any label on it", it read one off whatever else was in view: a sleep mask
            // held in front of a water bottle came back as "Sleep mask. Water."
            "Say what it is. If it has a label of its own, read it, like \"Shampoo bottle, Head and Shoulders, 13 ounces.\""
        case .general:
            "Answer in a short, specific phrase, like \"Tall green bottle.\" or \"Reading a book.\""
        }
    }

    /// Spoken length allowed per kind. Words are counted after the filter has compressed the text.
    static func limits(for kind: Kind) -> (sentences: Int, words: Int) {
        switch kind {
        case .read: (.max, .max)
        case .describe, .describeThings: (2, 10)
        case .object: (2, 20)   // a name, then its label: a sign's can be a dozen words
        case .person: (2, 16)   // room for two people
        default: (1, 8)
        }
    }

    /// Generation cap, a guard against run-on output; the filter normally stops the model much sooner.
    static func maxTokens(for kind: Kind) -> Int {
        switch kind {
        case .read: 400
        case .describe, .describeThings, .person, .object: 64
        default: 40
        }
    }

    // MARK: Streaming filter

    /// Rewrites generated text into the house style while it streams. Feed it the pieces as they are
    /// generated; it returns whole sentences, ready to speak. Reading aloud passes through untouched.
    struct Filter {
        private let kind: Kind
        private let limits: (sentences: Int, words: Int)
        private var buffer = ""
        private var sentences = 0
        private var words = 0
        /// True once the reply is as long as its kind allows: stop generating.
        private(set) var isDone = false

        init(kind: Kind) {
            self.kind = kind
            limits = AnswerStyle.limits(for: kind)
        }

        mutating func feed(_ text: String) -> String {
            if kind == .read { return text }
            buffer += text
            var out = ""
            while !isDone, let end = sentenceEnd(in: buffer) {
                out += accept(String(buffer[..<end.lowerBound]))
                buffer = String(buffer[end.upperBound...])
            }
            return out
        }

        /// Call when generation has ended; returns whatever was still held back.
        mutating func finish() -> String {
            if kind == .read { return "" }
            var out = isDone ? "" : accept(buffer)
            buffer = ""
            // Never silence: this happens when the whole reply was something we refuse to say.
            if sentences == 0 { out = "Not sure." }
            return out
        }

        /// A sentence ends at punctuation followed by whitespace (so "0.6 m" survives), like `Speaker`,
        /// except after a title, which would otherwise end "Dr. Pepper" at "Dr.".
        private func sentenceEnd(in text: String) -> Range<String.Index>? {
            var from = text.startIndex
            while let end = text.range(of: #"[.!?]+\s+|\n+"#, options: .regularExpression, range: from..<text.endIndex) {
                let before = text[..<end.lowerBound]
                if before.range(of: #"\b(Mr|Mrs|Ms|Dr|St|vs)$"#, options: .regularExpression) == nil { return end }
                from = end.upperBound
            }
            return nil
        }

        /// One sentence in, the same sentence in house style out ("" when nothing of it is kept).
        private mutating func accept(_ sentence: String) -> String {
            // The model sometimes answers "where" with a bounding box.
            let text = AnswerStyle.replace(#"\[\s*[\d.]+(\s*,\s*[\d.]+){3}\s*\]"#, in: sentence, with: "")
            var kept: [String] = []
            for raw in text.components(separatedBy: CharacterSet(charactersIn: ",;")) {
                let phrase = telegraphic(raw)
                guard !phrase.isEmpty else { continue }
                let count = phrase.split(separator: " ").count
                // The first phrase of a reply is always said; after that the word budget decides.
                if words > 0 && words + count > limits.words {
                    isDone = true
                    break
                }
                kept.append(phrase)
                words += count
            }
            guard !kept.isEmpty else { return "" }
            sentences += 1
            if sentences >= limits.sentences { isDone = true }
            let joined = kept.joined(separator: ", ")
            return (sentences > 1 ? " " : "") + joined.prefix(1).uppercased() + String(joined.dropFirst()) + "."
        }

        /// A phrase (the text between two commas) with the scaffolding taken out.
        private func telegraphic(_ phrase: String) -> String {
            var s = phrase.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.!?:\"*"))
            for (pattern, replacement) in AnswerStyle.rewrites { s = AnswerStyle.replace(pattern, in: s, with: replacement) }
            return AnswerStyle.replace(#"\s{2,}"#, in: s, with: " ").trimmingCharacters(in: CharacterSet(charactersIn: " -"))
        }
    }

    // MARK: Rewrite rules

    private static let personNoun = "(?:man|woman|male|female|person|people|boy|girl|guy|lady|gentleman|child|kid|men|women|individual)s?"
    private static let skinTone = "(?:light|dark|fair|pale|tan|tanned|olive|brown|black|white|medium)"

    /// Applied in order to each phrase. Everything here is scaffolding or something rule 7 forbids;
    /// none of it carries information the listener acts on.
    private static let rewrites: [(String, String)] = [
        // "No readable label." after the name of a thing that has none.
        (#"(?i)^no (readable |visible |main )?(label|labels|text|words|writing)( visible| on it)?$"#, ""),
        // Lead-ins.
        (#"(?i)^(and|but|also|then)\s+"#, ""),
        (#"(?i)^(in|on|from) (the|this) (image|picture|photo|photograph|scene|frame)$"#, ""),
        (#"(?i)^(the|this) (image|picture|photo|photograph|scene) (shows|depicts|features|contains|displays|is of)\s+"#, ""),
        (#"(?i)^(there (is|are|appears to be|seems to be)|there's|i (can )?see|you are looking at|it (is|looks like|appears to be)|it's|this (is|looks like|appears to be)|that (is|looks like)|that's|these are|those are|they are)\s+"#, ""),
        (#"(?i)^((the|this|that) (person|man|woman|individual)|he|she|they) (has|have|is wearing|are wearing|wears|is|are)\s+"#, ""),
        (#"(?i)\s+(from|of) (the )?(camera|phone)\S*( (position|viewpoint|perspective|depth sensor))?"#, ""),
        (#"(?i)\s+(in|on|of|from) (the|this) (image|picture|photo|photograph)\b"#, ""),
        // Sides as bare words.
        (#"(?i)\b(to|on|at) (the|your|my) (left|right)( hand)?( side)?\b"#, "$3"),
        (#"(?i)\b(directly |right |straight )?in front of (you|me)\b"#, "ahead"),
        (#"(?i)\b(directly|straight) ahead\b"#, "ahead"),
        (#"(?i)\bahead of (you|me)\b"#, "ahead"),
        (#"(?i)^ahead (is|are|there is|there are)\s+"#, ""),
        // Articles and the words a noun phrase does without.
        (#"(?i)(?<!half )\b(a|an|the)\s+(?!(few|little|lot|couple|bit)\b)"#, ""),
        (#"(?i)^(your|my)\s+"#, ""),
        (#"(?i)\b(is|are)\s+(?=(on|in|at|under|above|below|behind|beside|near|next|between|inside|left|right|ahead|not|half|[a-z]+ing)\b|\d)"#, ""),
        // People: no ethnicity, skin colour or age (rule 7). "Boy" and "girl" are guesses at age too.
        (#"(?i)\b(boy|girl)\b"#, "person"),
        (#"(?i)\b(boys|girls)\b"#, "people"),
        (#"(?i)\b(?:(?:young|younger|old|older|elderly|middle[- ]aged|teenage|senior|asian|caucasian|african[- ]american|african|hispanic|latino|latina|indian|middle[- ]eastern|european|white|black)[ ,]+)+(?="# + personNoun + #"\b)"#, ""),
        (#"(?i)\b"# + skinTone + #"[- ]skinned\s+"#, ""),
        (#"(?i)\b"# + skinTone + #"[- ](?:skin|complexion)(?: tone)? and\s+"#, ""),
        (#"(?i)(?:\b(?:and|with|has|have)\s+)?\b"# + skinTone + #"[- ](?:skin|complexion)(?: tone)?\b"#, ""),
        (#"(?i)\bin (?:his|her|their) (?:early |mid[- ]|late )?(?:teens|twenties|thirties|forties|fifties|sixties|seventies|eighties|\d0s)\b"#, ""),
        (#"(?i)\b(?:who )?(?:appears?|looks?|seems?) to be (?:young|older|elderly|middle[- ]aged|an adult|adults)\b"#, ""),
    ]

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }
}
