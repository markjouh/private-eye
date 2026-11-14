import CoreVideo
import Foundation
import Vision

/// Reads printed text in a frame with Apple's on-device recogniser, for "read this" and "what does
/// it say". The language model misreads fine print and digits: asked five times for the number on
/// one ID card it gave five different numbers, where this read the same, correct one four times out
/// of five, on the same frames.
enum TextReader {
    /// What a question wants read out.
    enum Request {
        /// "Read this", "What does it say?": all the text in view.
        case everything
        /// "What is the ID number?": only the lines that are numbers.
        case numbers
    }

    /// What `question` asks to have read, or nil when it is a question for the language model.
    ///
    /// Asking for a number counts because that is how people ask ("What is the student ID number?",
    /// seven times in two sessions, against no "read this"), and because a number is where the
    /// model's reading fails worst: one digit off, and nothing in the answer says so.
    static func request(in question: String) -> Request? {
        let q = question.lowercased()
        func has(_ pattern: String) -> Bool { q.range(of: pattern, options: .regularExpression) != nil }
        if has(#"\bnumbers?\b"#) && !has(#"\b(how many|number of)\b"#) { return .numbers }
        return AnswerStyle.kind(of: question) == .read ? .everything : nil
    }

    struct Line {
        let text: String
        /// Normalized to the frame, origin top-left.
        let box: CGRect
        let confidence: Float
    }

    /// The recogniser scores a line 0.3, 0.5 or 1; the 0.3s were nearly all noise ("ady", "*ORON BEE").
    static var minConfidence: Float = 0.5

    /// Every line of text found, top to bottom.
    static func lines(in frame: CVPixelBuffer) -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        guard (try? VNImageRequestHandler(cvPixelBuffer: frame, orientation: .up).perform([request])) != nil else { return [] }
        return (request.results ?? [])
            .compactMap { observation -> Line? in
                guard let best = observation.topCandidates(1).first, best.confidence >= minConfidence,
                      best.string.contains(where: { $0.isLetter || $0.isNumber })
                else { return nil }
                // Vision's boxes have their origin at the bottom-left; flip them.
                let b = observation.boundingBox
                return Line(text: best.string, box: CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height), confidence: best.confidence)
            }
            .sorted { $0.box.minY < $1.box.minY }
    }

    /// The text to read aloud, top to bottom, or nil when there is none. Each line is followed by a
    /// short pause, and the reading stops after `maxWords` so a whole page does not hold the user
    /// for a minute.
    ///
    /// Everything found is read. Reading only the largest text was tried and dropped: on an ID card it
    /// read the name and left out the number, which was the line that had been asked for.
    static func spoken(_ lines: [Line], _ request: Request = .everything, maxWords: Int = 50) -> String? {
        var parts: [String] = []
        var words = 0
        // A wrong digit is worse than no answer, and nothing in a number gives a misreading away, so
        // only lines the recogniser is sure of count as numbers.
        for line in lines where request == .everything || (isNumber(line.text) && line.confidence > 0.5) {
            let count = line.text.split(separator: " ").count
            guard words + count <= maxWords else {
                parts.append("and more")
                break
            }
            words += count
            // Capitals are for signs; the voice spells some of them out letter by letter.
            parts.append(line.text == line.text.uppercased() ? line.text.capitalized : line.text)
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: ", ") + "."
    }

    /// True for a line that is a number ("555 010 0199", "$4.99", "500 mg", "B12") rather than a
    /// sentence with a number in it ("Expires: 1/02/2031"): digits, with at most a unit or a prefix.
    /// A looser test (half the characters digits) let a misread date through as a second number.
    /// A date on a line of its own ("1/02/2026") is not what "the number" means either.
    static func isNumber(_ text: String) -> Bool {
        let isDate = text.range(of: #"^\s*\d{1,2}/\d{1,2}/\d{2,4}\s*$"#, options: .regularExpression) != nil
        return !isDate && text.filter(\.isNumber).count >= 2 && text.filter(\.isLetter).count <= 2
    }
}
