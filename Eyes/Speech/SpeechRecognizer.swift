import Accelerate
import AVFoundation
import Foundation
@preconcurrency import Speech

/// Routes microphone buffers from the audio thread to whichever recognition request is active.
private final class AudioFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recording: AVAudioFile?
    /// Loudness (RMS) of each buffer since the current request was attached.
    private var levels: [Float] = []

    /// `recording`, when given, receives the same audio the recogniser hears (for debugging).
    func attach(_ request: SFSpeechAudioBufferRecognitionRequest?, recording: AVAudioFile? = nil) {
        lock.lock()
        self.request = request
        self.recording = recording   // dropping the previous file closes it
        levels.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    /// Stops feeding the recogniser while keeping the recording open for `finish`.
    func detach() {
        lock.lock()
        request = nil
        recording = nil
        lock.unlock()
    }

    func push(_ buffer: AVAudioPCMBuffer) {
        var level: Float = 0
        if let samples = buffer.floatChannelData?[0] { vDSP_rmsqv(samples, 1, &level, vDSP_Length(buffer.frameLength)) }
        lock.lock()
        let request = request, recording = recording
        if request != nil { levels.append(level) }
        lock.unlock()
        request?.append(buffer)
        try? recording?.write(from: buffer)
    }

    /// True when the last moments of audio are about as loud as the press as a whole, i.e. the user
    /// had not finished the word when they let go.
    var stillSpeaking: Bool {
        lock.lock(); defer { lock.unlock() }
        guard levels.count >= 8 else { return false }
        let overall = levels.reduce(0, +) / Float(levels.count)
        let recent = levels.suffix(3).reduce(0, +) / 3
        return overall > 0.003 && recent > 0.5 * overall
    }
}

/// Push-to-talk speech-to-text using Apple's on-device recognizer.
/// `start()` when the press begins, `finish()` when it ends.
///
/// The microphone engine is started once and left running, so a press begins capturing instantly
/// instead of waiting for the audio hardware (which lost first words and sometimes failed outright).
@MainActor
final class SpeechRecognizer {
    /// Called with the running transcript while the user speaks.
    var onPartial: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private let feed = AudioFeed()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var transcript = ""
    private var finalContinuation: CheckedContinuation<Void, Never>?
    private var isFinal = false
    /// Whether the last `finish` waited for the end of a word.
    private(set) var keptListening = false

    static func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in c.resume(returning: status == .authorized) }
        }
        let mic = await AVAudioApplication.requestRecordPermission()
        return speech && mic
    }

    /// Starts the microphone if it is not already running. Safe to call repeatedly; the engine can
    /// stop on its own after an interruption or a route change, and this brings it back.
    func prepare() throws {
        guard !audioEngine.isRunning else { return }
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw LLMError("microphone unavailable") }
        input.removeTap(onBus: 0)
        let feed = feed
        // Runs on the audio thread, so it must not be a main-actor closure.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in
            feed.push(buffer)
        }
        audioEngine.prepare()
        try audioEngine.start()
    }

    /// `recordingTo`, when given, is where the audio of this press is saved as AAC (for debugging).
    func start(recordingTo url: URL? = nil) throws {
        cancel()
        guard let recognizer, recognizer.isAvailable else { throw LLMError("speech recognizer unavailable") }
        try prepare()
        transcript = ""
        isFinal = false

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.addsPunctuation = true
        self.request = request
        let format = audioEngine.inputNode.outputFormat(forBus: 0)
        let recording = url.flatMap { url in
            try? AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount, AVEncoderBitRateKey: 64_000,
            ], commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        }
        feed.attach(request, recording: recording)

        task = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let done = result?.isFinal == true || error != nil
            Task { @MainActor in
                guard let self, self.request === request else { return }
                if let text, !text.isEmpty {
                    self.transcript = text
                    self.onPartial?(text)
                }
                if done {
                    self.isFinal = true
                    self.finalContinuation?.resume()
                    self.finalContinuation = nil
                }
            }
        }
    }

    /// Stops listening and returns the final transcript (waits briefly for the recognizer to settle).
    func finish() async -> String {
        guard let request else { return "" }
        // People let go of the button on their last word: in testing, 20 of 54 questions were still
        // at speaking volume in their final 150 ms, and two lost the word ("What is"). Those get a
        // moment longer; a question that had already tailed off is not delayed.
        keptListening = feed.stillSpeaking
        if keptListening {
            try? await Task.sleep(for: .milliseconds(300))
            guard self.request === request else { return "" }
        }
        feed.detach()
        request.endAudio()
        if !isFinal {
            let timeout = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(1000))
                self?.finalContinuation?.resume()
                self?.finalContinuation = nil
            }
            await withCheckedContinuation { finalContinuation = $0 }
            timeout.cancel()
        }
        // A newer press may have replaced the request while we waited.
        guard self.request === request else { return "" }
        let text = transcript
        task?.cancel()
        task = nil
        self.request = nil
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() {
        feed.attach(nil)
        task?.cancel()
        task = nil
        request = nil
        finalContinuation?.resume()
        finalContinuation = nil
    }
}
