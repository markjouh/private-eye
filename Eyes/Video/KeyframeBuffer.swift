import Foundation

/// The last half minute of the scene, as a handful of small frames, so that "did someone just walk
/// by?" can be answered. A frame is kept when the view has changed since the last one kept, so a
/// still scene costs nothing and a busy one is sampled about once a second.
///
/// Memory only, and a fixed amount of it: at most `capacity` frames of about 330 KB. Nothing here
/// is written to disk; `clear()` empties it when the app leaves the screen or the user asks.
final class KeyframeBuffer: @unchecked Sendable {
    struct Keyframe {
        let time: TimeInterval
        let image: RGBImage
        let signature: SceneSignature
        /// The same frame at `readingSide`, for the text recogniser; only the newest few have one.
        var readable: RGBImage?
    }

    /// How far back the buffer reaches.
    static let seconds: TimeInterval = 30
    /// With the frame from the moment of the question that makes 16: eight pairs for the model,
    /// each pair costing what one frame does.
    static let capacity = 15
    /// Longer side of a kept frame. One pair at this size is about 108 tokens.
    static let side = 384
    /// "What did that sign say?" needs more pixels than the model is shown: the newest
    /// `readableCount` frames are also kept at this size (2.4 MB each), for the text recogniser.
    static let readingSide = 1024
    static let readableCount = 6

    /// How different the view must be from the last kept frame (`SceneSignature.change`): more
    /// than a hand holding still does to it (0.66 at most, over two minutes), less than someone
    /// appearing in an eighth of the view does (1.3).
    var changeNeeded: Float = 0.8
    /// Kept frames are at least this far apart, in seconds; twice that when the phone is hot.
    var gap: TimeInterval = 1

    private let lock = NSLock()
    private var kept: [Keyframe] = []

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return kept.count
    }

    /// Offer every analysed frame. `image` is only called for a frame that is kept, so the cost of
    /// scaling it down is paid about once a second at most. Returns true when it was kept.
    @discardableResult
    func offer(at time: TimeInterval, signature: SceneSignature, heat: Heat = .normal, image: () -> RGBImage?,
               readable: () -> RGBImage? = { nil }) -> Bool {
        lock.lock(); defer { lock.unlock() }
        kept.removeAll { time - $0.time > Self.seconds }
        if let last = kept.last {
            guard heat != .tooHot, time - last.time >= (heat == .hot ? gap * 2 : gap),
                  signature.change(from: last.signature) >= changeNeeded
            else { return false }
        }
        guard let image = image() else { return false }
        kept.append(Keyframe(time: time, image: image, signature: signature, readable: readable()))
        if kept.count > Self.capacity { thin() }
        for index in kept.indices.dropLast(Self.readableCount) { kept[index].readable = nil }
        return true
    }

    /// Makes room by dropping the frame that leaves the smallest hole in time: where frames
    /// crowd together one is least missed, and the half minute stays covered end to end. The
    /// oldest and newest always stay.
    private func thin() {
        guard kept.count > 2 else { return }
        var drop = 1, smallest = TimeInterval.infinity
        for index in 1..<(kept.count - 1) {
            let hole = kept[index + 1].time - kept[index - 1].time
            if hole < smallest {
                smallest = hole
                drop = index
            }
        }
        kept.remove(at: drop)
    }

    /// The clip to show the model for a question asked at `now`: the kept frames from the last
    /// half minute, oldest first, then `current`, the view at the moment of asking. Times count
    /// from the first frame.
    func clip(at now: TimeInterval, current: RGBImage) -> [VideoFrame] {
        lock.lock()
        let recent = kept.filter { now - $0.time <= Self.seconds && $0.time < now }
        lock.unlock()
        let start = recent.first?.time ?? now
        return recent.map { VideoFrame(image: $0.image, seconds: $0.time - start) } + [VideoFrame(image: current, seconds: now - start)]
    }

    /// The larger copies of the newest kept frames, newest first, for reading text off them.
    func readableFrames() -> [RGBImage] {
        lock.lock(); defer { lock.unlock() }
        return kept.reversed().compactMap(\.readable)
    }

    func clear() {
        lock.lock()
        kept.removeAll()
        lock.unlock()
    }
}
