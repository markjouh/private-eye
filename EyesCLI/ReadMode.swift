import Foundation

/// Text reading on image files: every line the recogniser found, and what would be read aloud.
///   eyes-cli read [--numbers] <image> ...
/// `--numbers` shows the reply to a question asking for a number. With no images, checks which
/// questions are sent to the reader at all.
func runReadMode(_ arguments: [String]) {
    var paths = arguments
    var request = TextReader.Request.everything
    if paths.first == "--numbers" {
        request = .numbers
        paths.removeFirst()
    }
    if paths.isEmpty { return checkReadRequests() }
    let kept = TextReader.minConfidence
    TextReader.minConfidence = 0   // show everything, with its confidence
    for path in paths {
        guard let buffer = loadPixelBuffer(path) else { print("could not read \(path)"); continue }
        let start = Date()
        let lines = TextReader.lines(in: buffer)
        print(String(format: "\n[%@] %d lines in %.0f ms", (path as NSString).lastPathComponent, lines.count, Date().timeIntervalSince(start) * 1000))
        for line in lines { print(String(format: "  %.2f  h %.3f  %@", line.confidence, line.box.height, line.text)) }
        print("  spoken:", TextReader.spoken(lines.filter { $0.confidence >= kept }, request) ?? "(no text)")
    }
}

private func checkReadRequests() {
    let cases: [(String, TextReader.Request?)] = [
        ("Read this", .everything),
        ("What does it say?", .everything),
        ("What does the sign say?", .everything),
        ("Can you read the label?", .everything),
        ("What is the student ID number?", .numbers),
        ("What is his student ID number?", .numbers),
        ("What is this ID number?", .numbers),
        ("What's the phone number on this?", .numbers),
        ("Read me the number", .numbers),
        ("What number is this bus?", .numbers),
        ("How many chairs are there?", nil),
        ("What is the number of people here?", nil),
        ("What is this?", nil),
        ("What university is he from?", nil),
        ("Is this ready?", nil),
        ("Where is the door?", nil),
    ]
    var failed = 0
    for (question, expected) in cases where TextReader.request(in: question) != expected {
        failed += 1
        print("FAIL  \"\(question)\"  expected \(String(describing: expected))  got \(String(describing: TextReader.request(in: question)))")
    }
    let lines = ["Campus Card", "Sam Doe", "555 010 0199", "Expires: 1/02/2031", "Issued: 102302026", "1/02/2026", "Issue Code: 0", "$4.99", "500 mg", "Room 204"]
        .map { TextReader.Line(text: $0, box: .zero, confidence: 1) }
        + [TextReader.Line(text: "555 010 0198", box: .zero, confidence: 0.5)]   // an unsure reading is not spoken
    let numbers = TextReader.spoken(lines, .numbers)
    if numbers != "555 010 0199, $4.99, 500 mg." {
        failed += 1
        print("FAIL  numbers only: \(numbers ?? "nil")")
    }
    if TextReader.spoken(Array(lines.prefix(2)), .numbers) != nil {
        failed += 1
        print("FAIL  no numbers in view should leave the question to the model")
    }
    print(failed == 0 ? "all \(cases.count + 2) read-request checks pass" : "\(failed) FAILED")
}
