import AVFoundation
import UIKit

/// Text-to-speech. Text can be fed incrementally while the model generates; complete sentences are
/// spoken as soon as they are available.
///
/// While VoiceOver is running it does the speaking: each sentence is posted as an announcement. That
/// leaves one voice instead of two talking over each other, it is the voice and rate the user chose,
/// and the reply also reaches a braille display.
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    var onFinished: (() -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private let settings = VoiceSettings.shared
    private var buffer = ""
    private var queued = 0
    private var inputEnded = true
    /// Sentences for VoiceOver, oldest first. Only the first has been posted: VoiceOver cannot be
    /// asked to forget what it was given, so the rest wait here, where `stop()` can still drop them.
    private var announcements: [String] = []
    /// Set when a reply is cut off while VoiceOver is mid-sentence, so that the next thing said
    /// interrupts that sentence instead of waiting behind it.
    private var interruptsVoiceOver = false

    override init() {
        super.init()
        synthesizer.delegate = self
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(announcementDidFinish), name: UIAccessibility.announcementDidFinishNotification, object: nil)
        center.addObserver(self, selector: #selector(voiceOverStatusDidChange), name: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil)
    }

    /// One audio session for the whole app: record for push-to-talk, play through the loudspeaker.
    static func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        // The microphone is always open here, and iOS mutes the Taptic Engine while a session records
        // unless it opts in: without this the proximity haptics never play.
        try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try? session.setActive(true)
    }

    /// Begins a new reply, interrupting anything still being spoken.
    func begin() {
        stop()
        inputEnded = false
    }

    /// Appends generated text; speaks every sentence that is now complete.
    func feed(_ text: String) {
        buffer += text
        // A sentence ends at punctuation followed by whitespace, so "3.5" mid-stream is not cut in two.
        while let end = buffer.range(of: #"[.!?]+\s+|\n+"#, options: .regularExpression) {
            speak(String(buffer[..<end.upperBound]))
            buffer = String(buffer[end.upperBound...])
        }
    }

    /// Marks the reply complete and speaks whatever is left.
    func end() {
        speak(buffer)
        buffer = ""
        inputEnded = true
        if queued == 0 { onFinished?() }
    }

    func say(_ text: String) {
        begin()
        feed(text)
        end()
    }

    func stop() {
        buffer = ""
        queued = 0
        inputEnded = true
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        if !announcements.isEmpty {
            announcements = []
            interruptsVoiceOver = true
        }
    }

    private func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        queued += 1
        if UIAccessibility.isVoiceOverRunning {
            announcements.append(trimmed)
            if announcements.count == 1 { announce(trimmed) }
        } else {
            let utterance = AVSpeechUtterance(string: trimmed)
            utterance.voice = settings.voice
            utterance.rate = settings.rate
            synthesizer.speak(utterance)
        }
    }

    private func announce(_ sentence: String) {
        var text = AttributedString(sentence)
        // Low priority queues behind whatever VoiceOver is saying, which may be something the user
        // just asked it to read; default priority cuts in.
        text.accessibilitySpeechAnnouncementPriority = interruptsVoiceOver ? .default : .low
        interruptsVoiceOver = false
        AccessibilityNotification.Announcement(text).post()
    }

    private func finishedOne() {
        guard queued > 0 else { return }
        queued -= 1
        if queued == 0, inputEnded { onFinished?() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishedOne() }
    }

    /// VoiceOver finished with an announcement, read to the end or interrupted: either way the next
    /// sentence is due. Announcements that are not the current sentence (a reply that was stopped, a
    /// status message posted elsewhere) are not ours to count.
    @objc private nonisolated func announcementDidFinish(_ notification: Notification) {
        let value = notification.userInfo?[UIAccessibility.announcementStringValueUserInfoKey]
        guard let read = value as? String ?? (value as? NSAttributedString)?.string else { return }
        Task { @MainActor in
            guard read == self.announcements.first else { return }
            self.announcements.removeFirst()
            if let next = self.announcements.first { self.announce(next) }
            self.finishedOne()
        }
    }

    /// VoiceOver switched off mid-reply would leave the rest waiting for a notification that never
    /// comes; the app's own voice says it instead.
    @objc private nonisolated func voiceOverStatusDidChange() {
        Task { @MainActor in
            guard !UIAccessibility.isVoiceOverRunning, !self.announcements.isEmpty else { return }
            let unread = self.announcements
            self.announcements = []
            self.queued -= unread.count
            unread.forEach(self.speak)
        }
    }
}
