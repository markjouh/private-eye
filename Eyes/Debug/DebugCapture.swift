import AVFAudio
import CoreVideo
import Foundation
import UIKit

/// Everything the app measured and decided on one turn, saved next to the frame it acted on.
struct TurnRecord: Codable {
    struct Box: Codable {
        var label: String
        var confidence: Float?
        var distance: Float?
        /// Normalized to the frame, origin top-left.
        var x: Double, y: Double, width: Double, height: Double
        /// Anything worth knowing about this box ("tentative", a match score).
        var note: String?

        init(_ label: String, _ box: CGRect, confidence: Float? = nil, distance: Float? = nil, note: String? = nil) {
            self.label = label
            self.confidence = confidence
            self.distance = distance
            x = box.minX; y = box.minY; width = box.width; height = box.height
            self.note = note
        }
    }

    var id: String
    var date: Date
    /// What started the turn: "press" (screen or hardware button), "intent", or "launch".
    var trigger: String
    var pressSeconds: Double
    var heard: String
    /// Which part of the app answered: "memory", "detector", "text", "description" (a tap on a scene),
    /// "object" (a tap on one thing), "model" or "error".
    var route: String
    var reply: String
    var model: String
    var thermal: String
    var centerDistance: Float?
    var detections: [Box]
    var faces: [Box]
    var belongings: [Box]
    /// Who and what was remembered at the time.
    var knownPeople: [String]
    var knownThings: [String]
    /// Console lines printed while the turn ran, each with seconds since the press began.
    var notes: [String]
}

/// Keeps what a debugging session needs afterwards: every console line with a timestamp, and for each
/// turn a `TurnRecord` with the camera frame, the LiDAR depth map and the audio of the press. Pull it
/// to the Mac with `tools/pull_debug.sh`.
///
/// The frames show whoever was in front of the camera, so this lives in the app's Caches folder (not
/// backed up) and is switched off by launching with `-debugCapture NO`.
final class DebugCapture: @unchecked Sendable {
    static let shared = DebugCapture()

    let isEnabled: Bool
    private let folder: URL
    private let turns: URL
    private let pending: URL
    private var observers: [NSObjectProtocol] = []
    private let queue = DispatchQueue(label: "eyes.debug", qos: .utility)
    private var pipe: Pipe?
    /// Older turns are deleted beyond this many; a frame is about 100 KB.
    private static let maxTurns = 250
    /// Longer side of the saved frame.
    private static let frameSide: CGFloat = 960

    private init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.object(forKey: "debugCapture") == nil || defaults.bool(forKey: "debugCapture")
        folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("debug")
        turns = folder.appendingPathComponent("turns")
        pending = folder.appendingPathComponent("pending")
    }

    /// Call once at launch, before anything is printed.
    func start() {
        guard isEnabled else { return }
        try? FileManager.default.removeItem(at: pending)   // recordings of presses that never became a turn
        try? FileManager.default.createDirectory(at: turns, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        teeConsole()

        var system = utsname()
        uname(&system)
        let machine = withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let built = (try? Bundle.main.executableURL?.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
        UIDevice.current.isBatteryMonitoringEnabled = true
        print("[eyes] debug capture on. session \(Date()), \(machine), iOS \(UIDevice.current.systemVersion), "
              + "app built \(built.map { "\($0)" } ?? "?"), battery \(Int(UIDevice.current.batteryLevel * 100))%"
              + (ProcessInfo.processInfo.isLowPowerModeEnabled ? ", low power mode" : ""))
        watchSystemEvents()
    }

    /// Logs the things that change how the app behaves without any code of ours running: going to the
    /// background, heat, memory pressure, and audio being interrupted or re-routed.
    private func watchSystemEvents() {
        let center = NotificationCenter.default
        func watch(_ name: Notification.Name, _ line: @escaping (Notification) -> String) {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { print("[eyes] \(line($0))") })
        }
        watch(UIApplication.didBecomeActiveNotification) { _ in "app became active" }
        watch(UIApplication.willResignActiveNotification) { _ in "app will resign active" }
        watch(UIApplication.didEnterBackgroundNotification) { _ in "app entered background" }
        watch(UIApplication.didReceiveMemoryWarningNotification) { _ in "MEMORY WARNING" }
        watch(ProcessInfo.thermalStateDidChangeNotification) { _ in
            "thermal state now \(["nominal", "fair", "serious", "critical"][min(ProcessInfo.processInfo.thermalState.rawValue, 3)])"
        }
        watch(AVAudioSession.interruptionNotification) { note in
            "audio interruption \(note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == 1 ? "began" : "ended")"
        }
        watch(AVAudioSession.routeChangeNotification) { _ in
            let route = AVAudioSession.sharedInstance().currentRoute
            return "audio route: in \(route.inputs.map(\.portType.rawValue)), out \(route.outputs.map(\.portType.rawValue))"
        }
    }

    /// Where the audio of the press now starting should be recorded, or nil when capture is off.
    func newRecordingURL() -> URL? {
        isEnabled ? pending.appendingPathComponent(UUID().uuidString + ".m4a") : nil
    }

    /// Sends everything printed to the console into `console.log` as well, each line timestamped, so
    /// the log survives sessions that were not launched from the Mac.
    private func teeConsole() {
        let url = folder.appendingPathComponent("console.log")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let file = try? FileHandle(forWritingTo: url) else { return }
        file.seekToEndOfFile()
        let console = FileHandle(fileDescriptor: dup(STDOUT_FILENO), closeOnDealloc: false)
        let pipe = Pipe()
        self.pipe = pipe
        // Line-buffered: a pipe would otherwise hold output back in 4 KB blocks.
        setvbuf(stdout, nil, _IOLBF, 0)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss.SSS"
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            console.write(data)
            let time = clock.string(from: Date())
            let text = String(decoding: data, as: UTF8.self)
            let stamped = text.split(separator: "\n", omittingEmptySubsequences: true).map { "\(time) \($0)\n" }.joined()
            file.write(Data(stamped.utf8))
        }
    }

    /// Saves one turn as `turns/<id>.json`, with `<id>.jpg` (the frame), `<id>-depth.jpg` (LiDAR, near
    /// is bright, no reading is blue) and `<id>.m4a` (what the microphone heard) when there were any.
    func save(_ turn: TurnRecord, frame: CVPixelBuffer?, depth: DepthMap?, audio: URL?) {
        guard isEnabled else { return }
        queue.async {
            let base = self.turns.appendingPathComponent(turn.id)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try? encoder.encode(turn).write(to: base.appendingPathExtension("json"))
            if let frame {
                let w = CGFloat(CVPixelBufferGetWidth(frame)), h = CGFloat(CVPixelBufferGetHeight(frame))
                // A frame the text recogniser read is kept whole: a misreading can only be looked
                // into at the size it was read at.
                let scale = turn.route == "text" ? 1 : min(1, Self.frameSide / max(w, h))
                let small = PixelWarp.warp(frame, toSource: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale),
                                           width: Int(w * scale), height: Int(h * scale))
                try? small.flatMap(PixelWarp.jpeg)?.write(to: base.appendingPathExtension("jpg"))
            }
            if let depth, let picture = Self.picture(of: depth) {
                try? PixelWarp.jpeg(picture)?.write(to: self.turns.appendingPathComponent(turn.id + "-depth.jpg"))
            }
            if let audio {
                try? FileManager.default.moveItem(at: audio, to: base.appendingPathExtension("m4a"))
            }
            self.trim()
        }
    }

    /// The depth map as a grey picture: bright is near, black is at or beyond LiDAR range, blue is no reading.
    private static func picture(of depth: DepthMap) -> CVPixelBuffer? {
        var made: CVPixelBuffer?
        CVPixelBufferCreate(nil, depth.width, depth.height, kCVPixelFormatType_32BGRA, nil, &made)
        guard let made else { return nil }
        CVPixelBufferLockBaseAddress(made, [])
        defer { CVPixelBufferUnlockBaseAddress(made, []) }
        guard let out = CVPixelBufferGetBaseAddress(made)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let outRow = CVPixelBufferGetBytesPerRow(made)
        _ = depth.withMeters { base, rowBytes in
            for y in 0..<depth.height {
                for x in 0..<depth.width {
                    let meters = base.load(fromByteOffset: y * rowBytes + x * MemoryLayout<Float32>.size, as: Float32.self)
                    let pixel = out + y * outRow + x * 4
                    if meters.isFinite, meters > 0.05 {
                        let grey = UInt8(255 * (1 - min(meters / DepthMap.maxRange, 1)))
                        pixel[0] = grey; pixel[1] = grey; pixel[2] = grey
                    } else {
                        pixel[0] = 255; pixel[1] = 0; pixel[2] = 0
                    }
                    pixel[3] = 255
                }
            }
        }
        return made
    }

    private func trim() {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: turns.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
        for name in names.dropLast(Self.maxTurns) {
            let base = turns.appendingPathComponent(String(name.dropLast(5)))
            for file in [".json", ".jpg", "-depth.jpg", ".m4a"] {
                try? FileManager.default.removeItem(atPath: base.path + file)
            }
        }
    }
}
