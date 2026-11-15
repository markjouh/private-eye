import Foundation

/// What the user asked to be told about ("someone sits in the chair"), and the forms of it the app
/// needs: the question put to the language model, and the sentence spoken when it happens.
struct WatchCondition: Equatable {
    /// As the user said it, without the "tell me when" and without closing punctuation.
    let words: String

    /// nil when nothing was said after "tell me when".
    init?(_ heard: String) {
        let trimmed = heard.trimmingCharacters(in: CharacterSet(charactersIn: " .!?,;:\n\t"))
        guard !trimmed.isEmpty else { return nil }
        words = trimmed
    }

    /// The question about a single frame, with "{}" standing for the condition. A statement to
    /// agree or disagree with takes any condition as it was spoken; turning "a chair frees up"
    /// into "Is a chair free?" would need grammar the app does not have.
    ///
    /// The model leans towards yes, and the wording decides by how much. On 427 frames saved from
    /// the phone, asked whether a person, and whether a chair, was in view, with a yes counted
    /// from 0.9 up: "Is this true right now: …?" passed 10 of the 229 where there was none, this
    /// wording 5 (three of them one whiteboard with writing on it), and it failed 4 of the 198
    /// where there was one. "Is this false right now: …?" was tried as a cross-check and is no
    /// use: the model says yes to that too, whatever is in the picture.
    static let template = "Look at the picture. Can you clearly see that {}?"

    /// The yes/no question put to the model. It is asked about what the camera sees, so the user's
    /// "I" and "me" become the camera: "I'm pointing at the cereal" is true when the cereal is in
    /// the middle of the picture, and the model has no other way to know who "I" is.
    func question(template: String = WatchCondition.template) -> String {
        var text = " " + words.lowercased() + " "
        for (pattern, replacement) in Self.forTheCamera {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return template.replacingOccurrences(of: "{}", with: text.trimmingCharacters(in: .whitespaces))
    }

    /// What is said when it happens: the user's own words handed back, so there is no doubt which
    /// watch this is. "I'm pointing at the cereal" comes back as "You're pointing at the cereal."
    var spoken: String {
        var text = " " + words + " "
        for (pattern, replacement) in Self.forTheListener {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
        }
        text = text.trimmingCharacters(in: .whitespaces)
        return text.prefix(1).uppercased() + text.dropFirst() + "."
    }

    /// The same, for the middle of a sentence: "Will tell you when you're pointing at the cereal."
    var inSentence: String {
        let said = spoken.dropLast()
        // "You're" starts lower-case mid-sentence; a name the user said first keeps its capital.
        return said.hasPrefix("You") ? said.prefix(1).lowercased() + said.dropFirst() : String(words.prefix(1) + said.dropFirst())
    }

    private static let forTheCamera: [(String, String)] = [
        (#"\b(i'm|i am|i) (now )?(pointing|pointed|aimed|aiming|facing|looking|point|aim|face|look) (at|towards?|to)\b"#, "the camera is pointing at"),
        (#"\bin front of me\b"#, "in front of the camera"),
        (#"\b(i'm|i am)\b"#, "the camera is"),
        (#"\bmy\b"#, "the"),
        (#"\bme\b"#, "the camera"),
        (#"\bi\b"#, "the camera"),
    ]

    private static let forTheListener: [(String, String)] = [
        (#"\bI'm\b"#, "you're"),
        (#"\bI am\b"#, "you are"),
        (#"\bI've\b"#, "you've"),
        (#"\bmyself\b"#, "yourself"),
        (#"\bmine\b"#, "yours"),
        (#"\bmy\b"#, "your"),
        (#"\bme\b"#, "you"),
        (#"\bI\b"#, "you"),
    ]
}
