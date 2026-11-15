import Foundation

/// A person the user introduced, with the face embeddings captured at the time.
struct Person: Codable {
    var name: String
    /// Views captured when the person was introduced.
    var samples: [[Float]]
    /// Views added since, from frames where they were recognised with confidence at a new angle.
    var learned: [[Float]]?
    /// JPEG of the face as first learned, for the memories screen.
    var thumbnail: Data?
}

/// Where and when a belonging was last noticed by the camera.
struct Sighting: Codable {
    var date: Date
    /// "left", "ahead" or "right" in the view at the time.
    var side: String
    var distance: Float?
    /// What it was with: "on:desk" for a surface under it, plain labels ("laptop") for things beside it.
    var near: [String]
}

/// One of the user's things, with the appearance embeddings captured when they named it.
struct Belonging: Codable {
    var name: String
    /// The detector's label for it at enrolment ("bottle"), when it had one.
    var label: String?
    var samples: [[Float]]
    var lastSeen: Sighting?
    /// JPEG of the thing as first learned, for the memories screen.
    var thumbnail: Data?
}

/// The outcome of comparing an embedding with everything remembered.
struct MemoryMatch {
    let name: String
    /// Cosine similarity to the closest stored sample of the best candidate.
    let score: Float
    /// True when the score clears the "could be" bar but not the "is" bar.
    let tentative: Bool
}

/// Everything the app remembers about people and belongings. Kept on the phone only, as one JSON
/// file. Safe to use from any thread.
final class MemoryStore {
    /// Face cosine at or above which a face is the enrolled person. Measured with this app's own
    /// pipeline on LFW (`eyes-cli faces identify`: people enrolled from one photo, as many strangers,
    /// probes shrunk to 58 and 35 px wide to imitate distance): at 0.35 every known face was named and
    /// no stranger was; at 0.30 under 1% of strangers were. Different-person pairs never scored above
    /// 0.19. On the phone, known people on a poor frame scored 0.24 to 0.30.
    static let faceThreshold: Float = 0.36
    /// Between this and `faceThreshold` a single frame is only a probable match ("possibly Sarah");
    /// `FaceTracker` turns a run of them into a sure one.
    static let faceMaybeThreshold: Float = 0.30
    /// When several people are enrolled, the best must beat the runner-up by this much; otherwise two
    /// similar-looking enrolled people would flip between names.
    static let faceMargin: Float = 0.05
    /// At most this many samples are kept per person or thing; the oldest are dropped first.
    static let maxSamples = 8
    /// Extra views of a person picked up later, kept apart from the ones they were introduced with
    /// so those can never be pushed out.
    static let maxLearned = 8

    private struct Contents: Codable {
        var people: [Person] = []
        var belongings: [Belonging] = []
    }

    private let lock = NSLock()
    private var contents = Contents()
    private let url: URL?

    /// `url` is where the memory is saved; nil keeps it in RAM only (tests).
    init(url: URL?) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode(Contents.self, from: data) {
            contents = saved
        }
    }

    /// The store in the app's Application Support folder.
    static func onDevice() -> MemoryStore {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return MemoryStore(url: folder.appendingPathComponent("memory.json"))
    }

    var people: [Person] { lock.withLock { contents.people } }
    var belongings: [Belonging] { lock.withLock { contents.belongings } }

    // MARK: People

    /// Adds samples to a person, creating them if new. Returns true if the person already existed.
    @discardableResult
    func remember(person name: String, samples: [[Float]], thumbnail: Data? = nil) -> Bool {
        lock.withLock {
            defer { save() }
            if let i = contents.people.firstIndex(where: { Self.key($0.name) == Self.key(name) }) {
                contents.people[i].samples = Array((contents.people[i].samples + samples).suffix(Self.maxSamples))
                if contents.people[i].thumbnail == nil { contents.people[i].thumbnail = thumbnail }
                return true
            }
            contents.people.append(Person(name: name, samples: Array(samples.suffix(Self.maxSamples)), thumbnail: thumbnail))
            return false
        }
    }

    /// Everyone remembered, by similarity of their closest stored view to this face, best first.
    func ranked(face embedding: [Float]) -> [(name: String, score: Float)] {
        people
            .map { person in
                (name: person.name, score: (person.samples + (person.learned ?? [])).map { PixelWarp.cosine($0, embedding) }.max() ?? -1)
            }
            .sorted { $0.score > $1.score }
    }

    /// Who this face is, judged on this one frame, or nil when it matches nobody well enough.
    func identify(face embedding: [Float]) -> MemoryMatch? {
        let ranked = ranked(face: embedding)
        guard let best = ranked.first, best.score >= Self.faceMaybeThreshold else { return nil }
        if ranked.count > 1, best.score - ranked[1].score < Self.faceMargin { return nil }
        return MemoryMatch(name: best.name, score: best.score, tentative: best.score < Self.faceThreshold)
    }

    /// Adds a view of someone already known, dropping the oldest learned view beyond `maxLearned`.
    func learn(person name: String, view: [Float]) {
        lock.withLock {
            guard let i = contents.people.firstIndex(where: { Self.key($0.name) == Self.key(name) }) else { return }
            contents.people[i].learned = Array(((contents.people[i].learned ?? []) + [view]).suffix(Self.maxLearned))
            save()
        }
    }

    // MARK: Belongings

    /// Adds views to a belonging, creating it if new. Returns true if it already existed.
    /// `replacing` drops what was stored under the name first: the name now means another thing.
    @discardableResult
    func remember(belonging name: String, label: String?, samples: [[Float]], thumbnail: Data? = nil, replacing: Bool = false) -> Bool {
        lock.withLock {
            defer { save() }
            if let i = contents.belongings.firstIndex(where: { Self.key($0.name) == Self.key(name) }) {
                if replacing {
                    contents.belongings[i] = Belonging(name: contents.belongings[i].name, label: label,
                                                       samples: Array(samples.suffix(Self.maxSamples)), thumbnail: thumbnail)
                    return true
                }
                contents.belongings[i].samples = Array((contents.belongings[i].samples + samples).suffix(Self.maxSamples))
                if let label { contents.belongings[i].label = label }
                if contents.belongings[i].thumbnail == nil { contents.belongings[i].thumbnail = thumbnail }
                return true
            }
            contents.belongings.append(Belonging(name: name, label: label, samples: Array(samples.suffix(Self.maxSamples)), thumbnail: thumbnail))
            return false
        }
    }

    /// The remembered belonging whose name best fits what the user said ("my keys", "the water bottle").
    func belonging(named spoken: String) -> Belonging? {
        let wanted = Self.key(spoken)
        guard !wanted.isEmpty else { return nil }
        let all = belongings
        return all.first { Self.key($0.name) == wanted }
            ?? all.first { Self.key($0.name).contains(wanted) || wanted.contains(Self.key($0.name)) }
    }

    /// Similarity of a crop's embedding to one belonging (best over its stored views).
    func similarity(of embedding: [Float], to belonging: Belonging) -> Float {
        belonging.samples.map { PixelWarp.cosine($0, embedding) }.max() ?? -1
    }

    func recordSighting(of name: String, _ sighting: Sighting) {
        lock.withLock {
            guard let i = contents.belongings.firstIndex(where: { Self.key($0.name) == Self.key(name) }) else { return }
            let previous = contents.belongings[i].lastSeen
            contents.belongings[i].lastSeen = sighting
            // While a thing stays in view this is called every couple of seconds; the file does not
            // need rewriting that often.
            if previous.map({ sighting.date.timeIntervalSince($0.date) > 15 }) ?? true { save() }
        }
    }

    // MARK: Forgetting

    /// Removes a person or belonging by name; returns what kind was removed, if any.
    func forget(_ spoken: String) -> String? {
        lock.withLock {
            let wanted = Self.key(spoken)
            defer { save() }
            if let i = contents.people.firstIndex(where: { Self.key($0.name) == wanted }) {
                return contents.people.remove(at: i).name
            }
            if let i = contents.belongings.firstIndex(where: { Self.key($0.name) == wanted }) {
                return "your " + contents.belongings.remove(at: i).name
            }
            return nil
        }
    }

    func forgetEverything() {
        lock.withLock {
            contents = Contents()
            save()
        }
    }

    // MARK: Helpers

    /// Names compare without case, punctuation, a leading "my"/"the", or a plural "s".
    static func key(_ name: String) -> String {
        var words = name.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        while let first = words.first, ["my", "the", "a", "an", "our"].contains(first) { words.removeFirst() }
        if let last = words.last, last.count > 3, last.hasSuffix("s"), !last.hasSuffix("ss") {
            words[words.count - 1] = String(last.dropLast())
        }
        return words.joined(separator: " ")
    }

    /// Call with the lock held.
    private func save() {
        guard let url, let data = try? JSONEncoder().encode(contents) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
