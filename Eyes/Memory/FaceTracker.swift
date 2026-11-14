import CoreGraphics
import Foundation

/// Follows each face in view from frame to frame so that who it is does not flicker.
///
/// A single frame is a noisy witness: a turned head or motion blur drops the match score of a known
/// person well below the naming threshold (0.24 to 0.30 on the phone, where strangers score under
/// 0.2). Judging every frame alone, the app named someone, forgot them, and named them again. The
/// tracker instead keeps a name it was sure of while the same person remains the best match, promotes
/// a run of probable matches, and picks out good frames to learn extra views from.
struct FaceTracker {
    /// One face in the current frame with how it compares to the people remembered.
    struct Observation {
        let box: CGRect
        let pixelWidth: CGFloat
        /// Remembered people by similarity, best first.
        let candidates: [(name: String, score: Float)]
        /// The store's own verdict on this frame alone.
        let match: MemoryMatch?
    }

    struct Verdict {
        let name: String?
        let tentative: Bool
        /// The person whose stored views this frame should be added to, when it is a good new view.
        let learnAs: String?
    }

    /// A name is kept this long after the last frame that was sure of it.
    static let holdTime: TimeInterval = 4
    /// While a name is held, that person must still be the best candidate with at least this score.
    /// Strangers scored at most 0.19 against anyone in testing.
    static let keepScore: Float = 0.24
    /// This many probable matches in a row for the same person count as a sure one.
    static let promoteAfter = 3
    /// A face not seen for this long is a new face when it reappears.
    static let forgetAfter: TimeInterval = 1.5
    /// A frame is worth learning from when the match is sure but not a near-copy of a stored view,
    /// and the face is large enough to be a good sample.
    static let learnScores: ClosedRange<Float> = 0.45...0.72
    static let learnWidth: CGFloat = 60
    /// At most one learned view per person in this many seconds.
    static let learnInterval: TimeInterval = 3

    private struct Track {
        var box: CGRect
        var lastSeen: Date
        var name: String?
        var sureAt: Date?
        var probable: (name: String, count: Int)?
    }

    private var tracks: [Track] = []
    private var lastLearned: [String: Date] = [:]

    mutating func update(_ observations: [Observation], at now: Date) -> [Verdict] {
        tracks.removeAll { now.timeIntervalSince($0.lastSeen) > Self.forgetAfter }
        var taken = Set<Int>()
        return observations.map { seen in
            // The nearest track not yet claimed, if the face has not moved more than its own width.
            let nearest = tracks.indices.filter { !taken.contains($0) }.min { a, b in
                distance(tracks[a].box, seen.box) < distance(tracks[b].box, seen.box)
            }
            var index = nearest.flatMap { distance(tracks[$0].box, seen.box) <= max(seen.box.width, tracks[$0].box.width) ? $0 : nil }
            if index == nil {
                tracks.append(Track(box: seen.box, lastSeen: now))
                index = tracks.count - 1
            }
            taken.insert(index!)
            var track = tracks[index!]
            let verdict = judge(seen, track: &track, now: now)
            tracks[index!] = track
            return verdict
        }
    }

    private mutating func judge(_ seen: Observation, track: inout Track, now: Date) -> Verdict {
        track.box = seen.box
        track.lastSeen = now
        let best = seen.candidates.first

        if let match = seen.match, !match.tentative {
            // Learn only from a face already established on this track, never from a first glimpse.
            let established = track.name == match.name && track.sureAt != nil
            let due = now.timeIntervalSince(lastLearned[match.name] ?? .distantPast) >= Self.learnInterval
            let worth = Self.learnScores.contains(match.score) && seen.pixelWidth >= Self.learnWidth
            track.name = match.name
            track.sureAt = now
            track.probable = nil
            if established && due && worth {
                lastLearned[match.name] = now
                return Verdict(name: match.name, tentative: false, learnAs: match.name)
            }
            return Verdict(name: match.name, tentative: false, learnAs: nil)
        }

        if let held = track.name, let sureAt = track.sureAt, now.timeIntervalSince(sureAt) <= Self.holdTime,
           let best, best.name == held, best.score >= Self.keepScore {
            return Verdict(name: held, tentative: false, learnAs: nil)
        }
        track.name = nil
        track.sureAt = nil

        guard let match = seen.match else {
            track.probable = nil
            return Verdict(name: nil, tentative: false, learnAs: nil)
        }
        let count = (track.probable?.name == match.name ? track.probable!.count : 0) + 1
        track.probable = (match.name, count)
        if count >= Self.promoteAfter {
            track.name = match.name
            track.sureAt = now
            return Verdict(name: match.name, tentative: false, learnAs: nil)
        }
        return Verdict(name: match.name, tentative: true, learnAs: nil)
    }

    private func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        hypot(a.midX - b.midX, a.midY - b.midY)
    }
}
