import CoreGraphics
import Foundation

/// Runs `LLMEngine` on its own serial queue and exposes it to async callers.
final class VLMService: @unchecked Sendable {
    /// Longer side of the image handed to the model. LFM3-VL spends about one token per 32x32 pixels,
    /// so this trades detail (small text) against time to first word.
    static let imageMaxSide = 768
    /// The language model in the app bundle. `eyes-ft-v2` is Witness-2B, our second fine-tune of
    /// LFM3-VL-2B: relabelled VizWiz answers plus sighted-guide tap replies and useful declines (it says
    /// what is wrong and what to do when it cannot see the answer). `eyes-ft-v1` is the earlier fine-tune
    /// and `LFM3-VL-2B-QAD-Q4_0` the stock file. All work with the same vision projector. Change
    /// `project.yml` too.
    static let modelName = "eyes-ft-v2-Q4_K_M"

    private let queue = DispatchQueue(label: "eyes.vlm", qos: .userInitiated)
    private var engine: LLMEngine?
    private let lock = NSLock()
    /// Counts calls to `ingest`, so that one overtaken by a newer frame before it began is skipped.
    private var ingests = 0

    func load() async throws {
        try await run {
            guard self.engine == nil else { return }
            guard let model = Bundle.main.path(forResource: Self.modelName, ofType: "gguf"),
                  let mmproj = Bundle.main.path(forResource: "mmproj-LFM3-VL-2B-Q8_0", ofType: "gguf")
            else { throw LLMError("model files missing from app bundle") }
            let engine = try LLMEngine(modelPath: model, mmprojPath: mmproj)
            // The first pass through the vision encoder and the LLM compiles Metal pipelines and takes
            // about a second longer than later ones; pay that at launch instead of on the first question.
            let side = 256
            try engine.ingest(image: RGBImage(width: side, height: side, pixels: [UInt8](repeating: 128, count: side * side * 3)))
            try engine.answer(question: "Hi", maxTokens: 4)
            self.engine = engine
        }
    }

    /// Starts a turn by evaluating the image. Returns once the image is in the model's context.
    /// Called again before the question is asked, it drops the earlier image for this one.
    func ingest(_ image: CGImage) async throws {
        let mine = lock.withLock {
            ingests += 1
            return ingests
        }
        // Stops the earlier image being evaluated, if it still is.
        cancel()
        try await run {
            guard let engine = self.engine else { throw LLMError("model not loaded") }
            guard self.lock.withLock({ self.ingests }) == mine else { throw LLMError("replaced by a newer frame") }
            guard let rgb = RGBImage(cgImage: image, maxSide: Self.imageMaxSide) else {
                throw LLMError("could not convert camera frame")
            }
            try engine.ingest(image: rgb)
        }
    }

    /// `suffix` replaces the engine's usual style instruction for this one answer (e.g. to ask for a
    /// bare list); `maxTokens` caps its length.
    func answer(_ question: String, as kind: AnswerStyle.Kind? = nil, suffix: String? = nil, maxTokens: Int? = nil,
                onText: @escaping @Sendable (String) -> Void) async throws -> (String, LLMStats) {
        try await run {
            guard let engine = self.engine else { throw LLMError("model not loaded") }
            let usualSuffix = engine.questionSuffix
            if let suffix { engine.questionSuffix = suffix }
            defer { engine.questionSuffix = usualSuffix }
            let reply = try engine.answer(question: question, as: kind, maxTokens: maxTokens) { text in
                onText(text)
                return true
            }
            return (reply, engine.stats)
        }
    }

    /// Whether the frame is a close-up of one thing rather than a scene (see `LLMEngine.isCloseUp`).
    /// Also returns how long the steps took, for the log.
    func isCloseUp() async throws -> (Bool, String) {
        try await run {
            guard let engine = self.engine else { throw LLMError("model not loaded") }
            return (try engine.isCloseUp(), engine.closeUpTiming)
        }
    }

    /// Aborts whatever turn is in flight.
    func cancel() {
        engine?.cancel()
    }

    private func run<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }
}
