import Foundation

/// Tells a question about the last half minute ("did someone just walk by?") from one about what
/// is in view now. The first kind is answered from the kept frames; everything else goes on being
/// answered from the frame at the start of the press.
///
/// Deliberately narrow, like the command parser: the model is good at what happened in a clip and
/// poor at what is true at its end (asked "is the person still there?" of clips in which they had
/// left, it said yes every time), so a question only counts as about the past when its wording
/// says so. "Did I leave the stove on?" is past tense and about now; it stays with the single frame.
enum Recall {
    static func isAboutThePast(_ question: String) -> Bool {
        let q = question.lowercased()
        func has(_ pattern: String) -> Bool { q.range(of: pattern, options: .regularExpression) != nil }
        // Things that happen and are over: someone passing, something moving or falling.
        let event = #"(walk(ed)?|pass(ed)?|c[ao]me|go|went|leave|left|enter(ed)?|move[ds]?|happen(ed)?|fall|fell|drop(ped)?|r[au]n|arrive[ds]?|show(ed)? up|appear(ed)?|drive|drove|change[ds]?|open(ed)?|close[ds]?|say|said|do|did)"#
        if has(#"\bwhat( just| has just|'s just)? happened\b"#) || has(#"\bwhat was (that|this)\b"#) || has(#"\bwho was (that|this|here)\b"#) { return true }
        if has(#"\b(just now|a (moment|second|minute|few seconds|little while) ago|earlier|before now|recently)\b"#) { return true }
        if has(#"\b(did|has|have|was|were)\b.*\bjust\b"#) || has(#"\bjust\b.*\b"# + event + #"\b"#) { return true }
        // "Did someone walk by?", "Has anyone come in?", "Was there a dog?"
        let someone = #"(some|any)(one|body|thing)|a (person|man|woman|car|bus|dog|cat|bike)|people|they|he|she|it|that|the [a-z]+"#
        if has(#"^(did|has|have) ("# + someone + #") (\w+ )?"# + event + #"\b"#) { return true }
        if has(#"^(was|were) there\b"#) || has(#"^who (was|came|left|walked|passed|went)\b"#) { return true }
        if has(#"^what did (that|the|this|it|he|she|they)\b"#) { return true }
        return false
    }

    /// The question as the model is given it. Told nothing, the fine-tuned model treats the
    /// frames as one photo and an open question about them as not a question about it: "What
    /// just happened?" got "No question about photo." or "No clear event captured." on all six
    /// test clips, three of which show someone arriving. With these words in front it described
    /// the person in those three. A longer preface ("These pictures are the last half minute,
    /// oldest first.") did not help.
    static func forTheModel(_ question: String) -> String {
        "In this video: " + question
    }

    /// "What did that sign say?": text that has gone out of view, for the text recogniser to read
    /// off the kept frames.
    static func asksForPastText(_ question: String) -> Bool {
        let q = question.lowercased()
        return q.range(of: #"^what (did|was) (that|the|this|it)\b.*\b(say|said|read|written)\b"#, options: .regularExpression) != nil
            || q.range(of: #"^what was (written|printed) (on|there)\b"#, options: .regularExpression) != nil
    }
}
