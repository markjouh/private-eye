import AVFoundation
import SwiftUI
import UIKit

/// How replies are spoken: the user's choice of speed and voice, kept across launches. Set on the
/// last onboarding screen and under Memories > Settings.
///
/// While VoiceOver is running it speaks the replies (see `Speaker`), in its own voice and at its own
/// speed, and these settings wait until it is off.
@MainActor
final class VoiceSettings: ObservableObject {
    static let shared = VoiceSettings()

    static let defaultRate: Float = 0.58
    /// The ends of the speed slider, in `AVSpeechUtterance`'s units (0.5 is the system's usual pace).
    static let rateRange: ClosedRange<Float> = 0.4...0.7

    @Published var rate: Float {
        didSet { defaults.set(rate, forKey: Keys.rate) }
    }
    /// Identifier of the chosen voice; always one of `choices` (or "" on a device with no voices).
    @Published var voiceID: String {
        didSet { defaults.set(voiceID, forKey: Keys.voice) }
    }
    /// The voices offered: the best one installed first (the default), then up to two that sound
    /// different from it.
    let choices: [AVSpeechSynthesisVoice]

    var voice: AVSpeechSynthesisVoice? {
        choices.first { $0.identifier == voiceID } ?? choices.first
    }

    private enum Keys {
        static let rate = "speechRate"
        static let voice = "voiceIdentifier"
    }
    private let defaults: UserDefaults
    private let sampler = AVSpeechSynthesizer()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        choices = Self.voicesOffered()
        let savedRate = (defaults.object(forKey: Keys.rate) as? NSNumber)?.floatValue
        rate = savedRate.map { min(max($0, Self.rateRange.lowerBound), Self.rateRange.upperBound) } ?? Self.defaultRate
        let savedVoice = defaults.string(forKey: Keys.voice)
        voiceID = choices.first { $0.identifier == savedVoice }?.identifier ?? choices.first?.identifier ?? ""
    }

    /// Says a few words with the current settings, so a change can be heard as it is made.
    func sample() {
        // VoiceOver is already talking, and it is its voice the user will hear replies in.
        guard !UIAccessibility.isVoiceOverRunning else { return }
        sampler.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: "This is how I sound.")
        utterance.voice = voice
        utterance.rate = rate
        sampler.speak(utterance)
    }

    func stopSample() {
        sampler.stopSpeaking(at: .immediate)
    }

    /// A voice's name without the quality the system appends ("Ava (Premium)" -> "Ava").
    static func displayName(_ voice: AVSpeechSynthesisVoice) -> String {
        String(voice.name.split(separator: "(").first ?? "").trimmingCharacters(in: .whitespaces)
    }

    private static func voicesOffered() -> [AVSpeechSynthesisVoice] {
        // The natural-sounding voices only. The system also lists the synthetic ones of old Macs
        // (Fred, Junior, Ralph) and the novelty ones (Bells, Zarvox), under other identifiers.
        let english = AVSpeechSynthesisVoice.speechVoices().filter { voice in
            voice.language == "en-US" && ["com.apple.voice.", "com.apple.ttsbundle."].contains { voice.identifier.hasPrefix($0) }
        }
        // Best quality first; within a quality, the order the system lists them in.
        let ranked = [AVSpeechSynthesisVoiceQuality.premium, .enhanced, .default].flatMap { quality in
            english.filter { $0.quality == quality }
        }
        var chosen: [AVSpeechSynthesisVoice] = []
        func offer(_ voice: AVSpeechSynthesisVoice) {
            // One entry per voice, not one per quality it is installed in.
            guard chosen.count < 3, !chosen.contains(where: { displayName($0) == displayName(voice) }) else { return }
            chosen.append(voice)
        }
        // The default: a downloaded higher-quality voice if there is one, else the system's own choice.
        if let usual = ranked.first(where: { $0.quality != .default }) ?? AVSpeechSynthesisVoice(language: "en-US") ?? ranked.first {
            offer(usual)
        }
        // Then one of the other gender, so the choices are easy to tell apart by ear.
        if let different = ranked.first(where: { $0.gender != .unspecified && $0.gender != chosen.first?.gender }) { offer(different) }
        ranked.forEach(offer)
        return chosen
    }
}
