import AVFoundation
import CoreML
import FluidAudio
import Foundation

/// Streaming speech-to-text with Parakeet Unified 0.6B (NVIDIA's FastConformer-RNNT, run on the
/// phone through FluidAudio's Core ML conversion). The audio of a press goes in as it arrives, so
/// when the button is let go only the last half second or so is left to recognise.
///
/// The model is in the app bundle (`Models/parakeet-unified-en-0.6b`, fetched by `tools/setup.sh`).
/// It takes a while to load the first time, on a queue of its own; until it has, and whenever it
/// fails, `SpeechRecognizer` goes on using Apple's recogniser.
final class ParakeetTranscriber: @unchecked Sendable {
    /// Which export of the model: the encoder takes 0.56 s of new audio at a time and looks 0.56 s
    /// ahead of it. On 228 of the app's own press recordings, marked against OpenAI's
    /// gpt-transcribe, this one got 7.4% of words wrong and 194 recordings exactly right; the
    /// export that looks 0.08 s ahead got 9.3% and 188, and Apple's recogniser on the phone 14.8%
    /// and 173 (see the README).
    static let tier = StreamingModelVariant.parakeetUnified1120ms
    /// Silence given to the model before and after the audio of a press. A press starts and ends
    /// on a word, and the model does badly with no room around speech: without this it heard
    /// nothing at all in 7 of the 228 recordings (short ones, such as a quick "What is this?"),
    /// with it 3, and exact transcripts went from 183 to 194. The silence after costs one more pass of the
    /// encoder once the button is let go.
    static let silenceBefore = 0.4, silenceAfter = 0.6
    /// The folder in the bundle holding the model, as FluidAudio lays it out.
    static let folder = "parakeet-unified-en-0.6b"

    enum State: Equatable {
        case notLoaded, loading, ready
        case failed(String)
    }

    private let lock = NSLock()
    private var current = State.notLoaded
    private var manager: StreamingUnifiedAsrManager?
    /// Which encoder loaded: "int8" or "fp16".
    private(set) var precision = ""
    /// Where the audio of the press under way is sent.
    private var feed: AsyncStream<AVAudioPCMBuffer>.Continuation?
    /// Takes the audio from `feed` to the model, in order.
    private var session: Task<Void, Never>?
    /// The model being cleared after the last press; the next one waits for it.
    private var clearing: Task<Void, Never>?

    var state: State { lock.withLock { current } }
    var isReady: Bool { state == .ready }

    /// Loads the model, once. The small int8 encoder is tried first; it is known not to load on
    /// some iPhone chips (FluidAudio issue 828, an A16), where the fp16 one does, so that is the
    /// second try: from the bundle if it is there, otherwise downloaded once (1.2 GB).
    func load() async {
        let begin: Bool = lock.withLock {
            guard current == .notLoaded else { return false }
            current = .loading
            return true
        }
        guard begin, let config = Self.tier.unifiedConfig else { return }
        let bundled = Bundle.main.resourceURL?.appendingPathComponent(Self.folder)
        var failures: [String] = []
        for precision in [UnifiedEncoderPrecision.int8, .fp16] {
            let began = Date()
            let manager = StreamingUnifiedAsrManager(config: config, encoderPrecision: precision)
            do {
                if let bundled, Self.has(precision, in: bundled, config: config) {
                    try await manager.loadModels(from: bundled)
                } else if precision == .fp16 {
                    try await manager.loadModels()
                } else {
                    failures.append("int8 not in the bundle")
                    continue
                }
                // The first pass through a model compiles it for the chip; pay that now.
                if let silence = Self.silence(seconds: 1) {
                    try await manager.appendAudio(silence)
                    try await manager.processBufferedAudio()
                    _ = try await manager.finish()
                    try await manager.reset()
                }
                lock.withLock {
                    self.manager = manager
                    self.precision = precision.rawValue
                    current = .ready
                }
                print(String(format: "[eyes] speech: Parakeet (%@, %@) ready in %.1f s", Self.tier.rawValue, precision.rawValue, Date().timeIntervalSince(began)))
                return
            } catch {
                failures.append("\(precision.rawValue): \(error)")
                print("[eyes] speech: Parakeet \(precision.rawValue) did not load: \(error)")
            }
        }
        lock.withLock { current = .failed(failures.joined(separator: "; ")) }
        print("[eyes] speech: Parakeet unavailable, using Apple's recogniser")
    }

    /// `seconds` of silence in the form the model takes (it converts whatever it is given).
    private static func silence(seconds: Double) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(16_000 * seconds))
        else { return nil }
        buffer.frameLength = buffer.frameCapacity   // a new buffer's samples are zero
        if let samples = buffer.floatChannelData?[0] { memset(samples, 0, Int(buffer.frameLength) * MemoryLayout<Float>.size) }
        return buffer
    }

    private static func has(_ precision: UnifiedEncoderPrecision, in folder: URL, config: UnifiedConfig) -> Bool {
        let encoder = config.family.streamingEncoderFile(precision: precision, contextSuffix: config.contextSuffix)
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent(encoder).path)
    }

    /// Starts a press. Audio given to `push` from now on is recognised as it comes; `onPartial`
    /// gets the words so far each time they change. False when the model is not ready.
    func begin(onPartial: @escaping @Sendable (String) -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard current == .ready, let manager else { return false }
        let (stream, feed) = AsyncStream<AVAudioPCMBuffer>.makeStream(bufferingPolicy: .unbounded)
        self.feed?.finish()
        self.feed = feed
        if let lead = Self.silence(seconds: Self.silenceBefore) { feed.yield(lead) }
        let clearing = clearing
        session = Task {
            await clearing?.value
            var said = ""
            for await buffer in stream {
                do {
                    try await manager.appendAudio(buffer)
                    try await manager.processBufferedAudio()
                    let text = await manager.getPartialTranscript()
                    if text != said {
                        said = text
                        onPartial(text)
                    }
                } catch {
                    print("[eyes] speech: Parakeet step failed: \(error)")
                }
            }
        }
        return true
    }

    /// Call with each microphone buffer, on the audio thread. The buffer is copied: the audio
    /// engine reuses its own.
    func push(_ buffer: AVAudioPCMBuffer) {
        guard let feed = lock.withLock({ feed }), let samples = buffer.floatChannelData,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength), let out = copy.floatChannelData
        else { return }
        copy.frameLength = buffer.frameLength
        for channel in 0..<Int(buffer.format.channelCount) {
            memcpy(out[channel], samples[channel], Int(buffer.frameLength) * MemoryLayout<Float>.size)
        }
        feed.yield(copy)
    }

    /// Ends the press and returns everything that was said; nil when no press was under way or
    /// the model failed.
    func finish() async -> String? {
        let (feed, session, manager): (AsyncStream<AVAudioPCMBuffer>.Continuation?, Task<Void, Never>?, StreamingUnifiedAsrManager?) = lock.withLock {
            defer { self.feed = nil; self.session = nil }
            return (self.feed, self.session, self.manager)
        }
        guard let feed, let session, let manager else { return nil }
        feed.finish()
        await session.value
        if let tail = Self.silence(seconds: Self.silenceAfter) {
            try? await manager.appendAudio(tail)
            try? await manager.processBufferedAudio()
        }
        let text = try? await manager.finish()
        let clear = Task { _ = try? await manager.reset() }
        lock.withLock { clearing = clear }
        return text?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Drops the press under way, if any.
    func cancel() {
        let (feed, session, manager): (AsyncStream<AVAudioPCMBuffer>.Continuation?, Task<Void, Never>?, StreamingUnifiedAsrManager?) = lock.withLock {
            defer { self.feed = nil; self.session = nil }
            return (self.feed, self.session, self.manager)
        }
        guard let feed, let session, let manager else { return }
        feed.finish()
        let clear = Task {
            await session.value
            _ = try? await manager.reset()
        }
        lock.withLock { clearing = clear }
    }
}
