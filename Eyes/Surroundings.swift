import CoreGraphics
import Foundation

/// Turns what was measured (detections, LiDAR distances) into words, for the replies built by code:
/// where a thing is, how far away, and the answers to questions the language model must not answer.
enum Surroundings {
    /// The patch of the view used for "what is straight ahead" distance.
    static let centerRegion = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)

    // MARK: Where things are

    /// Which third of the view a box sits in.
    static func side(of box: CGRect) -> String {
        if box.midX < 0.36 { return "left" }
        if box.midX > 0.64 { return "right" }
        return "ahead"
    }

    /// A thing and where it is, in the house style (see `AnswerStyle`): "Car, 13 feet, left",
    /// "Sarah, 3 feet ahead", "Bus, right", "Traffic light ahead".
    static func phrase(_ name: String, distance: Float?, side: String) -> String {
        let label = name.prefix(1).uppercased() + name.dropFirst()
        let lateral = side == "ahead" ? " ahead" : ", \(side)"
        guard let distance else { return label + lateral }
        return "\(label), \(spoken(distance))\(lateral)"
    }

    /// A measured distance as it is spoken: "1 foot", "2 feet", "13 feet". Everything inside the app is
    /// in meters (LiDAR's unit); this is where it becomes feet.
    static func spoken(_ meters: Float) -> String {
        let feet = Int((meters * 3.281).rounded())
        return feet <= 1 ? "1 foot" : "\(feet) feet"
    }

    /// The same distance for an on-screen tag: "2ft".
    static func tag(_ meters: Float) -> String {
        "\(max(1, Int((meters * 3.281).rounded())))ft"
    }

    /// The answer to "how far is that?": the LiDAR reading at the middle of the view. The language
    /// model cannot measure, so it is never asked.
    static func howFar(_ center: Float?) -> String {
        guard let center else { return "Nothing within \(spoken(DepthMap.maxRange)) straight ahead." }
        return "\(spoken(center)) straight ahead."
    }

    // MARK: Safety questions

    /// True for questions asking for a go/no-go on traffic ("is it safe to cross?", "any cars coming?").
    /// A small vision model answers these confidently and wrongly, so they never reach it.
    static func isSafetyQuestion(_ text: String) -> Bool {
        let q = text.lowercased()
        func has(_ pattern: String) -> Bool { q.range(of: pattern, options: .regularExpression) != nil }

        let movement = #"\b(cross|crossing|walk|go|step|proceed|move|continue|forward|ahead|street|road|traffic|intersection)\b"#
        if has(#"\bsafe(ly)?\b"#) && has(movement) { return true }
        if has(#"^\s*is (it|this|that) safe\b[\s?.!]*$"#) { return true }
        if has(#"\b(can|could|should|may) (i|we) (\w+ )?cross\b"#) { return true }
        if has(#"\b(ok|okay|alright|time|clear|good) to cross\b"#) { return true }
        if has(#"\bcross(ing)? (now|yet|here|(the|this|that) (street|road|intersection))"#) { return true }
        if has(#"\b(cars?|vehicles?|traffic|bus(es)?|trucks?|bikes?)\b.*\bcoming\b"#) { return true }
        if has(#"\b(any|is there|are there)\b.*\b(traffic|cars|vehicles)\b"#) { return true }
        if has(#"\b(walk|pedestrian|crossing|traffic) (signal|sign|light)\b"#) && has(#"\b(green|red|on|go|walk|say|says|showing|color|colour|look)\b"#) { return true }
        if has(#"\blight\b.*\b(green|red)\b"#) { return true }
        if has(#"\b(road|street|way|coast|path)\b.*\bclear\b"#) || has(#"\bclear to (go|cross|walk)\b"#) { return true }
        if has(#"\bcan i go\b"#) { return true }
        return false
    }

    private static let vehicles: Set<String> = ["car", "bus", "truck", "bicycle", "motorcycle", "scooter", "train"]

    /// A reply built only from what the detector and depth sensor report. It declines to judge and
    /// never says "safe"; seeing no vehicle is reported with its limit, so it cannot pass for all-clear.
    static func safetyReply(for detections: [Detection]) -> String {
        let seen = detections.filter { $0.confidence >= 0.25 }
        func said(_ d: Detection) -> String { phrase(d.label, distance: d.distance, side: side(of: d.box)) + "." }
        var parts = ["Can't judge crossing."]

        let traffic = seen
            .filter { vehicles.contains($0.label) }
            .sorted { ($0.distance ?? .greatestFiniteMagnitude) < ($1.distance ?? .greatestFiniteMagnitude) }
        parts += traffic.prefix(3).map(said)
        if traffic.count > 3 { parts.append("\(traffic.count - 3) more.") }

        if let light = seen.first(where: { $0.label == "traffic light" }) {
            parts.append(String(said(light).dropLast()) + ", can't read its color.")
        }
        parts += ["crosswalk", "stop sign"].compactMap { label in seen.first { $0.label == label }.map(said) }
        if traffic.isEmpty {
            parts.append("No vehicles seen, but I only see where the camera points. Listen for traffic.")
        }
        return parts.joined(separator: " ")
    }
}
