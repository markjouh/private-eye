import AVFoundation
import UIKit

/// The sounds and taps of a search: a soft beep while it is looking, a rising chime with a strong
/// tap when it has found the thing, and a falling pair of notes when it gives up. Each comes before
/// any words, so none can be taken for part of an answer. The sounds are made here rather than
/// shipped as files, and play through the app's own audio session, so the ringer switch does not
/// silence them.
///
/// The taps are kept for the ends of a search. While it is looking there is only the beep, so that
/// a tap in the hand always means "found" (or "gave up"), never "still looking".
@MainActor
final class AlertCue {
    enum Sound {
        /// Still looking: one short, quiet beep, repeated every `tickEvery` seconds.
        case tick
        /// Found: three rising notes and a strong tap.
        case found
        /// Gave up: two falling notes and a duller tap.
        case gaveUp

        /// How long it lasts; speech that follows waits this long.
        var seconds: Double {
            switch self {
            case .tick: 0.06
            case .found: 0.46
            case .gaveUp: 0.40
            }
        }
    }

    /// Seconds from one beep to the next while a search is on.
    static let tickEvery = 1.0

    private let tick: AVAudioPlayer?
    private let found: AVAudioPlayer?
    private let gaveUp: AVAudioPlayer?
    private let notification = UINotificationFeedbackGenerator()
    private let thump = UIImpactFeedbackGenerator(style: .heavy)

    init() {
        // A tick is quiet and low enough to sit under speech from someone nearby; the chime is
        // an octave up and twice as loud.
        tick = Self.player([(740, 0.06)], volume: 0.25)
        found = Self.player([(880, 0.11), (1108.7, 0.11), (1318.5, 0.24)], volume: 0.5)
        gaveUp = Self.player([(587.3, 0.14), (440, 0.26)], volume: 0.4)
    }

    func play(_ sound: Sound) {
        switch sound {
        case .tick:
            start(tick)
        case .found:
            notification.notificationOccurred(.success)
            start(found)
            // Two more thumps under the chime's last note: a single tap is easy to miss in a hand
            // that is moving the phone about.
            Task {
                for _ in 0..<2 {
                    try? await Task.sleep(for: .milliseconds(160))
                    thump.impactOccurred(intensity: 1)
                }
            }
        case .gaveUp:
            notification.notificationOccurred(.warning)
            start(gaveUp)
        }
    }

    /// Readies the players and the Taptic Engine, so the first beep of a search is not late.
    func prepare() {
        notification.prepare()
        thump.prepare()
    }

    private func start(_ player: AVAudioPlayer?) {
        player?.currentTime = 0
        player?.play()
    }

    private static func player(_ notes: [(frequency: Double, seconds: Double)], volume: Double) -> AVAudioPlayer? {
        let player = try? AVAudioPlayer(data: wav(notes, volume: volume))
        player?.prepareToPlay()
        return player
    }

    /// The notes one after another as 16-bit mono WAV data.
    private static func wav(_ notes: [(frequency: Double, seconds: Double)], volume: Double) -> Data {
        let rate = 44_100.0
        var samples: [Int16] = []
        for note in notes {
            let count = Int(note.seconds * rate)
            for i in 0..<count {
                // A few milliseconds of fade at each end, or the note starts and stops with a click.
                let edge = min(1, Double(min(i, count - i)) / (0.008 * rate))
                samples.append(Int16(sin(2 * .pi * note.frequency * Double(i) / rate) * edge * volume * Double(Int16.max)))
            }
        }
        var data = Data()
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + bytes).littleEndian)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16).littleEndian)
        append(UInt16(1).littleEndian); append(UInt16(1).littleEndian)            // PCM, mono
        append(UInt32(rate).littleEndian); append(UInt32(rate * 2).littleEndian)  // sample rate, bytes a second
        append(UInt16(2).littleEndian); append(UInt16(16).littleEndian)           // bytes a sample, bits a sample
        data.append(contentsOf: Array("data".utf8)); append(bytes.littleEndian)
        samples.forEach { append($0.littleEndian) }
        return data
    }
}
