import CoreGraphics
import Foundation

/// Chooses which parts of a frame belonging memory looks at: the one thing the user is pointing the
/// phone at when they name it, and the few regions worth comparing when they ask where it is.
enum BelongingTargeting {
    /// A part of the frame to embed, with what the detector knows about it.
    struct Region {
        /// Normalized to the frame, origin top-left.
        let box: CGRect
        /// The detector's label, or nil for a plain crop of the middle of the view.
        let label: String?
        /// Meters from the phone, when the detector's box had a LiDAR reading.
        let distance: Float?
    }

    /// People, furniture, fixtures, vehicles and street objects: things a belonging sits on, in or in
    /// front of. Their boxes are never taken for the belonging itself unless the user names them.
    static let surroundings: Set<String> = [
        "person", "face", "hand", "dog", "cat", "bird",
        "chair", "couch", "bed", "table", "desk", "bench", "stool", "shelf", "cabinet", "drawer", "door",
        "window", "stairs", "elevator", "escalator", "railing", "mirror", "curtain", "rug", "sink", "toilet",
        "bathtub", "shower", "refrigerator", "oven", "stove", "dishwasher", "washing machine", "television",
        "car", "bus", "truck", "bicycle", "motorcycle", "scooter", "train", "traffic light", "stop sign",
        "street sign", "sign", "crosswalk", "curb", "pole", "fire hydrant", "parking meter", "mailbox",
        "tree", "fence", "wheelchair", "stroller", "shopping cart", "atm", "vending machine",
    ]

    /// The middle of the view, used when the detector offers nothing: it does not know every object.
    static let centre = Region(box: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), label: nil, distance: nil)

    /// How far from the middle of the view the thing being shown may be, as a fraction of the frame
    /// from the centre to the nearest edge of its box: the phone is aimed by feel. A name the detector
    /// knows is evidence enough to look farther out; without one only what is practically under the
    /// middle counts.
    static let namedReach: CGFloat = 0.3
    static let unnamedReach: CGFloat = 0.15
    /// Detections with a longer edge below this fraction of the frame have too few pixels to embed.
    static let minEdge: CGFloat = 0.04

    /// The thing the user most likely means by "remember this as my <name>".
    ///
    /// They are pointing the phone at it, so: a detection near the middle whose label shares a word
    /// with the name ("water bottle" and "bottle"); otherwise the smallest detection over the middle
    /// that is not part of the surroundings (a bottle held over a desk is inside the desk's box, and
    /// the bottle is what they mean), or the nearest one just beside it; otherwise the middle of the view.
    ///
    /// Checked with `eyes-cli things` on 164 Objectron photos of things the detector has a word for:
    /// named, the rule took a detection with that label in 152 (the detector had none in the other 12);
    /// given a name that is no help, the geometry alone took the same box in 147.
    static func enrolmentTarget(in detections: [Detection], named name: String) -> Region {
        let middle = CGPoint(x: 0.5, y: 0.5)
        func offCentre(_ detection: Detection) -> CGFloat { reach(from: middle, to: detection.box) }
        // A confident detection just off the middle beats a doubtful one right on it: one tenth of the
        // frame off-centre costs as much as 0.3 of confidence.
        func aim(_ detection: Detection) -> CGFloat { CGFloat(detection.confidence) - 3 * offCentre(detection) }

        let spoken = words(name)
        let named = detections.filter { !spoken.isDisjoint(with: words($0.label)) && offCentre($0) <= namedReach }
        if let best = named.max(by: { aim($0) < aim($1) }) { return region(best) }

        let loose = detections.filter { !surroundings.contains($0.label) && max($0.box.width, $0.box.height) >= minEdge }
        if let smallest = loose.filter({ offCentre($0) == 0 }).min(by: { area($0.box) < area($1.box) }) { return region(smallest) }
        if let nearest = loose.filter({ offCentre($0) <= unnamedReach }).max(by: { aim($0) < aim($1) }) { return region(nearest) }
        return centre
    }

    /// True when the detector's label for a region shares a word with what the user called the thing
    /// ("water bottle" and "bottle"): the strongest sign that the region is the thing they mean.
    static func names(_ name: String, label: String?) -> Bool {
        guard let label else { return false }
        return !words(name).isDisjoint(with: words(label))
    }

    /// The regions worth embedding when looking for a belonging, most promising first.
    ///
    /// Each one costs a model run, so the list is short: detections with the label the belonging had
    /// when it was enrolled come first, then other loose objects by confidence (the detector may call
    /// the same bottle a cup from another side). Surroundings are skipped unless the belonging is one,
    /// and near-duplicate boxes are skipped. The middle of the view goes first for a belonging enrolled
    /// without a label, which the detector cannot see at all, and last, if there is room, when no
    /// detection is there: a thing held up to the camera is found even when the detector misses it.
    /// (That last rule raised right-object accepts at 0.70 from 84% to 87% on the Objectron photos, for
    /// 0.1 points more look-alikes.)
    static func searchCandidates(in detections: [Detection], label: String?, limit: Int = 4) -> [Region] {
        let usable = detections
            .filter { ($0.label == label || !surroundings.contains($0.label)) && max($0.box.width, $0.box.height) >= minEdge }
            .sorted { $0.confidence > $1.confidence }
        let ranked = usable.filter { $0.label == label } + usable.filter { $0.label != label }
        var chosen: [Region] = label == nil ? [centre] : []
        for detection in ranked where chosen.count < limit {
            if chosen.contains(where: { overlap($0.box, detection.box) > 0.6 }) { continue }
            chosen.append(region(detection))
        }
        let middle = CGPoint(x: 0.5, y: 0.5)
        if chosen.count < limit, !chosen.contains(where: { reach(from: middle, to: $0.box) <= unnamedReach }) {
            chosen.append(centre)
        }
        return chosen
    }

    // MARK: Helpers

    private static func region(_ detection: Detection) -> Region {
        Region(box: detection.box, label: detection.label, distance: detection.distance)
    }

    /// Lowercased words without a plural "s", so "keys" matches "key" and "Water Bottle" matches "bottle".
    private static func words(_ text: String) -> Set<String> {
        let ignored: Set<String> = ["my", "the", "a", "an", "our", "of"]
        return Set(text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !ignored.contains($0) }
            .map { $0.count > 3 && $0.hasSuffix("s") && !$0.hasSuffix("ss") ? String($0.dropLast()) : $0 })
    }

    /// Distance from a point to a box, zero inside it.
    private static func reach(from point: CGPoint, to box: CGRect) -> CGFloat {
        hypot(max(box.minX - point.x, 0, point.x - box.maxX), max(box.minY - point.y, 0, point.y - box.maxY))
    }

    private static func area(_ box: CGRect) -> CGFloat { box.width * box.height }

    /// Intersection over union.
    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let both = a.intersection(b)
        guard !both.isNull else { return 0 }
        let shared = area(both)
        return shared / (area(a) + area(b) - shared)
    }
}
