import CoreGraphics
import Foundation
import llama

struct LLMError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct LLMStats {
    var imageTokens = 0
    var imageMs = 0.0        // vision encode + prefill of system prompt and image
    var questionTokens = 0
    var ttftMs = 0.0         // from answer() call to first generated token
    var generatedTokens = 0
    var tokensPerSecond = 0.0
}

/// Tightly packed 8-bit RGB pixels, the input format of the vision encoder.
struct RGBImage {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Draws `image` scaled so its longer side is at most `maxSide`.
    init?(cgImage image: CGImage, maxSide: Int) {
        let scale = min(1.0, Double(maxSide) / Double(max(image.width, image.height)))
        let w = max(1, Int((Double(image.width) * scale).rounded()))
        let h = max(1, Int((Double(image.height) * scale).rounded()))
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = rgba.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(
                data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) {
            rgb[i * 3] = rgba[i * 4]
            rgb[i * 3 + 1] = rgba[i * 4 + 1]
            rgb[i * 3 + 2] = rgba[i * 4 + 2]
        }
        width = w
        height = h
        pixels = rgb
    }
}

/// LFM3-VL running through llama.cpp + mtmd.
///
/// A turn is two calls: `ingest(image:)` evaluates the system prompt and the image, then
/// `answer(question:)` evaluates the question and generates. Splitting them lets the image be
/// processed while the user is still speaking, and lets more than one question be asked of it.
///
/// Not thread-safe: use from a single serial queue. `cancel()` may be called from any thread.
final class LLMEngine {
    static let defaultSystemPrompt = AnswerStyle.systemPrompt
    /// nil: `AnswerStyle` picks the instruction that suits each question and filters the reply.
    static let defaultQuestionSuffix: String? = nil

    var systemPrompt = LLMEngine.defaultSystemPrompt
    /// The instruction appended to the question (after a newline); LFM3 follows one placed there and
    /// largely ignores the same words in the system prompt. Set it to take over the style of a call:
    /// the reply then comes back exactly as generated, with no `AnswerStyle` filtering.
    var questionSuffix = LLMEngine.defaultQuestionSuffix
    /// LFM3 reasons inside <think> tags before answering when enabled. Slower; off by default.
    var thinking = false
    private(set) var stats = LLMStats()
    /// Size of the state copied by the last `isCloseUp()`, and how long its three steps took (copying
    /// the state, asking, putting the state back), for the record.
    private(set) var stateBytes = 0
    private(set) var closeUpTiming = ""

    private let model: OpaquePointer
    private let ctx: OpaquePointer
    private let mctx: OpaquePointer
    private let vocab: OpaquePointer
    private let sampler: UnsafeMutablePointer<llama_sampler>
    private let bosText: String
    private let nBatch: Int32 = 2048
    private var nPast: llama_pos = 0
    private let cancelled = UnsafeMutablePointer<Bool>.allocate(capacity: 1)

    init(modelPath: String, mmprojPath: String, gpu: Bool = true, verbose: Bool = false) throws {
        if !verbose {
            llama_log_set({ _, _, _ in }, nil)
            mtmd_log_set({ _, _, _ in }, nil)
            mtmd_helper_log_set({ _, _, _ in }, nil)
        }
        llama_backend_init()

        var mparams = llama_model_default_params()
        mparams.n_gpu_layers = gpu ? 999 : 0
        guard let model = llama_model_load_from_file(modelPath, mparams) else {
            throw LLMError("could not load model at \(modelPath)")
        }
        self.model = model
        vocab = llama_model_get_vocab(model)

        var cparams = llama_context_default_params()
        cparams.n_ctx = 4096
        cparams.n_batch = UInt32(nBatch)
        cparams.n_ubatch = UInt32(nBatch)
        let threads = Int32(max(2, min(6, ProcessInfo.processInfo.activeProcessorCount - 2)))
        cparams.n_threads = threads
        cparams.n_threads_batch = threads
        guard let ctx = llama_init_from_model(model, cparams) else {
            throw LLMError("could not create llama context")
        }
        self.ctx = ctx

        var vparams = mtmd_context_params_default()
        vparams.use_gpu = gpu
        vparams.n_threads = threads
        vparams.print_timings = false
        guard let mctx = mtmd_init_from_file(mmprojPath, model, vparams) else {
            throw LLMError("could not load vision projector at \(mmprojPath)")
        }
        self.mctx = mctx

        // Sampling recommended by the model card: temp 0.1, top-k 50, repeat penalty 1.1.
        sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        llama_sampler_chain_add(sampler, llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), 64, 1.1, 0, 0))
        llama_sampler_chain_add(sampler, llama_sampler_init_top_k(50))
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.1))
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(1234))

        bosText = LLMEngine.piece(vocab, llama_vocab_bos(vocab), special: true)
            .flatMap { String(bytes: $0, encoding: .utf8) } ?? ""

        cancelled.initialize(to: false)
        llama_set_abort_callback(ctx, { data in
            data!.assumingMemoryBound(to: Bool.self).pointee
        }, cancelled)
    }

    deinit {
        llama_sampler_free(sampler)
        mtmd_free(mctx)
        llama_free(ctx)
        llama_model_free(model)
        cancelled.deallocate()
    }

    /// Aborts a running `ingest`/`answer` as soon as possible. Safe from any thread.
    func cancel() { cancelled.pointee = true }

    /// Starts a new turn: clears the context, then evaluates the system prompt and `image`.
    func ingest(image: RGBImage) throws {
        cancelled.pointee = false
        stats = LLMStats()
        llama_memory_clear(llama_get_memory(ctx), true)
        llama_sampler_reset(sampler)
        nPast = 0

        let start = Date()
        let marker = String(cString: mtmd_default_marker())
        let system = systemPrompt.isEmpty ? "" : "<|im_start|>system\n\(systemPrompt)<|im_end|>\n"
        let prompt = "\(bosText)\(system)<|im_start|>user\n\(marker)"
        guard let bitmap = image.pixels.withUnsafeBufferPointer({
            mtmd_bitmap_init(UInt32(image.width), UInt32(image.height), $0.baseAddress)
        }) else { throw LLMError("could not create bitmap") }
        defer { mtmd_bitmap_free(bitmap) }
        let tokens = try eval(prompt, bitmaps: [bitmap], logitsLast: false)
        stats.imageTokens = tokens
        stats.imageMs = Date().timeIntervalSince(start) * 1000
    }

    /// True when the ingested image is a close-up of one thing (something held up to the camera, a
    /// sign, a laptop filling the view) rather than a scene. The model's own judgement, asked as a
    /// yes/no: on 78 taps saved from the phone it agreed with a person looking at the same frames
    /// every time. Costs one short question, about a tenth of a second.
    ///
    /// The question that follows must not be coloured by this one (left in the context, the yes/no
    /// made the next answer curt: a rescue sign read out in full became "Elevator."). The model's
    /// memory cannot be rewound to just after the image, because LFM3 keeps recurrent state that
    /// llama.cpp only drops whole, so the state is copied before asking and put back afterwards.
    func isCloseUp() throws -> Bool {
        let began = Date()
        let size = llama_state_seq_get_size(ctx, 0)
        stateBytes = size
        var afterImage = [UInt8](repeating: 0, count: size)
        guard llama_state_seq_get_data(ctx, &afterImage, size, 0) == size else { throw LLMError("could not save the model's state") }
        let saved = Date()
        var asked = saved
        let past = nPast, kept = stats
        defer {
            llama_memory_clear(llama_get_memory(ctx), false)
            _ = llama_state_seq_set_data(ctx, afterImage, size, 0)
            llama_sampler_reset(sampler)
            nPast = past
            stats = kept
            closeUpTiming = String(format: "copy %.0f ms, ask %.0f ms, restore %.0f ms", saved.timeIntervalSince(began) * 1000,
                                   asked.timeIntervalSince(saved) * 1000, Date().timeIntervalSince(asked) * 1000)
        }
        let usual = questionSuffix
        questionSuffix = AnswerStyle.closeUpSuffix
        defer { questionSuffix = usual }
        // The first word settles it; a second token would only be its full stop.
        let reply = try answer(question: AnswerStyle.closeUpQuestion, maxTokens: 1)
        asked = Date()
        return reply.lowercased().hasPrefix("yes")
    }

    /// Evaluates `question` against the ingested image and generates the reply. The model is given
    /// the image, the question and a style instruction, and nothing else: no detections, distances
    /// or names (see the README for what happened when it was).
    /// `onText` receives text as it is produced; return `false` from it to stop early.
    /// `maxTokens` defaults to the budget of the question's kind (160 when `questionSuffix` is set).
    @discardableResult
    /// `kind` sets the style of the answer when the caller knows better than the wording of the question.
    func answer(question: String, as kind: AnswerStyle.Kind? = nil, maxTokens: Int? = nil,
                onText: (String) -> Bool = { _ in true }) throws -> String {
        let start = Date()
        let think = thinking ? "<think>" : "<think></think>"
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = kind ?? AnswerStyle.kind(of: asked)
        var filter = questionSuffix == nil ? AnswerStyle.Filter(kind: kind) : nil
        let instruction = questionSuffix ?? AnswerStyle.suffix(for: kind)
        let suffix = instruction.isEmpty ? "" : "\n\(instruction)"
        let limit = maxTokens ?? (questionSuffix == nil ? AnswerStyle.maxTokens(for: kind) : 160)
        let prompt = "\(asked)\(suffix)<|im_end|>\n<|im_start|>assistant\n\(think)"
        stats.questionTokens = try eval(prompt, bitmaps: [], logitsLast: true)

        var reply = ""
        var pending = [UInt8]()   // bytes of an incomplete UTF-8 sequence
        var inThink = thinking
        var firstTokenAt: Date?
        var stopped = false       // the caller asked for no more text
        for _ in 0..<limit {
            if cancelled.pointee || filter?.isDone == true { break }
            var token = llama_sampler_sample(sampler, ctx, -1)
            if firstTokenAt == nil {
                firstTokenAt = Date()
                stats.ttftMs = firstTokenAt!.timeIntervalSince(start) * 1000
            }
            if llama_vocab_is_eog(vocab, token) { break }
            stats.generatedTokens += 1

            pending += LLMEngine.piece(vocab, token, special: inThink) ?? []
            if let text = String(bytes: pending, encoding: .utf8) {
                pending.removeAll(keepingCapacity: true)
                if inThink {
                    if text.contains("</think>") { inThink = false }
                } else {
                    let spoken = filter?.feed(text) ?? text
                    if !spoken.isEmpty {
                        reply += spoken
                        if !onText(spoken) {
                            stopped = true
                            break
                        }
                    }
                }
            }
            if llama_decode(ctx, llama_batch_get_one(&token, 1)) != 0 { break }
            nPast += 1
        }
        if let firstTokenAt, stats.generatedTokens > 1 {
            let seconds = Date().timeIntervalSince(firstTokenAt)
            stats.tokensPerSecond = Double(stats.generatedTokens - 1) / max(seconds, 1e-6)
        }
        if !stopped, !cancelled.pointee, let rest = filter?.finish(), !rest.isEmpty {
            reply += rest
            _ = onText(rest)
        }
        return reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Tokenizes and evaluates a prompt piece (text plus optional images); returns its token count.
    private func eval(_ text: String, bitmaps: [OpaquePointer], logitsLast: Bool) throws -> Int {
        guard let chunks = mtmd_input_chunks_init() else { throw LLMError("out of memory") }
        defer { mtmd_input_chunks_free(chunks) }
        var ptrs: [OpaquePointer?] = bitmaps
        let rc = text.withCString { cText -> Int32 in
            var input = mtmd_input_text(text: cText, text_len: strlen(cText), add_special: false, parse_special: true)
            return mtmd_tokenize(mctx, chunks, &input, &ptrs, ptrs.count)
        }
        guard rc == 0 else { throw LLMError("tokenize failed (\(rc))") }
        var newPast: llama_pos = nPast
        let ev = mtmd_helper_eval_chunks(mctx, ctx, chunks, nPast, 0, nBatch, logitsLast, &newPast)
        guard ev == 0 else {
            throw LLMError(cancelled.pointee ? "cancelled" : "eval failed (\(ev))")
        }
        nPast = newPast
        return Int(mtmd_helper_get_n_tokens(chunks))
    }

    private static func piece(_ vocab: OpaquePointer, _ token: llama_token, special: Bool) -> [UInt8]? {
        var buf = [CChar](repeating: 0, count: 64)
        var n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, special)
        if n < 0 {
            buf = [CChar](repeating: 0, count: Int(-n))
            n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, special)
        }
        guard n >= 0 else { return nil }
        return buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }
    }
}
