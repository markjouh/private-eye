#if os(iOS)
import CoreHaptics
import CoreMotion
import Foundation

/// Parking sensor in the hand: taps on the Taptic Engine that quicken as something in the user's
/// path gets closer, a buzz within arm's reach, nothing when the way ahead is clear.
///
/// `ProximityModel` decides what to play. This class feeds it depth frames and the direction of
/// gravity (CoreMotion: the model needs it to tell the floor from an obstacle) and plays its cues.
final class ProximityHaptics: @unchecked Sendable {
    /// The overall switch. Off also stops the motion sensors.
    var isEnabled: Bool {
        get { lock.withLock { enabled } }
        set {
            lock.withLock { enabled = newValue }
            queue.async {
                if newValue {
                    self.motion.startDeviceMotionUpdates()
                } else {
                    self.motion.stopDeviceMotionUpdates()
                    self.silence()
                }
            }
        }
    }

    /// Set while the microphone is listening for a question: the Taptic Engine is loud enough to
    /// be recorded. Cuts off anything already playing.
    var isPaused: Bool {
        get { lock.withLock { paused } }
        set {
            lock.withLock { paused = newValue }
            if newValue { queue.async { self.silence() } }
        }
    }

    private let lock = NSLock()
    private var enabled = true
    private var paused = false
    private var isActive: Bool { lock.withLock { enabled && !paused } }

    private let motion = CMMotionManager()

    // Used on the camera's video queue only.
    private var model = ProximityModel()
    private var lastUpdate: TimeInterval = 0
    private var wasSignalling = false
    /// The distance the obstacle has been sitting at, and since when (see `settled`).
    private var restingAt: Float?
    private var restingSince: TimeInterval = 0
    private var wasSettled = false
    /// An obstacle that stays within `restBand` meters for `restTime` seconds stops tapping.
    private static let restBand: Float = 0.12
    private static let restTime: TimeInterval = 3
    /// The camera delivers 30 frames a second; every second one is plenty at walking pace.
    private static let updateInterval: TimeInterval = 0.06

    // Used on `queue` only, so a slow haptic server can never hold up the camera.
    private let queue = DispatchQueue(label: "eyes.haptics", qos: .userInitiated)
    private lazy var engine = makeEngine()
    private var engineRunning = false
    /// The cues still playing or about to: kept alive until they have played, and to cut them off.
    private var players: [CHHapticPatternPlayer] = []

    init() {
        // Read (not delivered) at each update; fresh enough that gravity matches the depth frame
        // while the phone is being swung about.
        motion.deviceMotionUpdateInterval = 1.0 / 30
        motion.startDeviceMotionUpdates()
    }

    /// Call with every camera frame, on the camera's video queue. Returns at once for most frames;
    /// about 15 times a second it reads a quarter of the depth map in place (tens of microseconds).
    func update(_ depth: DepthMap?) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastUpdate >= Self.updateInterval, isActive else { return }
        lastUpdate = now
        let gravity = motion.deviceMotion.map { SIMD3(Float($0.gravity.x), Float($0.gravity.y), Float($0.gravity.z)) }
        let cue = model.update(depth: depth, gravity: gravity, time: now)

        let signalling = model.distance != nil
        if signalling != wasSignalling {
            wasSignalling = signalling
            print(String(format: "[eyes] proximity: %@, floor %.2f m below the phone",
                         model.distance.map { String(format: "obstacle at %.2f m", $0) } ?? "clear", model.floorDepth))
        }
        let quiet = settled(at: model.distance, time: now)
        if quiet != wasSettled {
            wasSettled = quiet
            if quiet { queue.async { self.silence() } }
        }
        if let cue, !quiet { queue.async { self.play(cue) } }
    }

    /// True once the obstacle has stayed where it is for a few seconds. A warning is for something
    /// the user is closing in on; sitting at a desk or waiting at a counter would otherwise tap or buzz
    /// without end. The moment the distance changes, in either direction, the cues come back.
    private func settled(at distance: Float?, time: TimeInterval) -> Bool {
        guard let distance else {
            restingAt = nil
            return false
        }
        if let rest = restingAt, abs(distance - rest) <= Self.restBand {
            return time - restingSince >= Self.restTime
        }
        restingAt = distance
        restingSince = time
        return false
    }

    // MARK: Taptic Engine (on `queue`)

    private func makeEngine() -> CHHapticEngine? {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics, let engine = try? CHHapticEngine() else { return nil }
        engine.playsHapticsOnly = true
        // Most of the time the way is clear and nothing plays; let the hardware sleep meanwhile.
        engine.isAutoShutdownEnabled = true
        // The engine stops when the app is suspended, when audio is interrupted and when idle, and
        // resets if the haptic server dies. Either way the next cue starts it again.
        engine.stoppedHandler = { [weak self] _ in self?.queue.async { self?.engineRunning = false } }
        engine.resetHandler = { [weak self] in
            self?.queue.async {
                self?.engineRunning = false
                self?.players.removeAll()
            }
        }
        return engine
    }

    private func play(_ cue: ProximityCue) {
        guard isActive, let engine else { return }
        let event: CHHapticEvent
        let time: TimeInterval
        switch cue {
        case .tick(let at, let intensity, let sharpness):
            time = at
            event = CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ], relativeTime: 0)
        case .buzz(let at, let duration):
            time = at
            event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5),
            ], relativeTime: 0, duration: duration)
        }
        do {
            if !engineRunning {
                try engine.start()
                engineRunning = true
            }
            // Cues queue up behind a slow engine start. The first is still worth playing late; the
            // stale ones behind it would only blur the rhythm that carries the distance.
            let wait = time - ProcessInfo.processInfo.systemUptime
            guard wait > -0.3 else { return }
            let player = try engine.makePlayer(with: CHHapticPattern(events: [event], parameters: []))
            try player.start(atTime: wait > 0 ? engine.currentTime + wait : CHHapticTimeImmediate)
            if players.count == 2 { players.removeFirst() }
            players.append(player)
        } catch {
            // Most likely the engine stopped and its handler has not run yet; start afresh next cue.
            engineRunning = false
        }
    }

    private func silence() {
        for player in players { try? player.cancel() }
        players.removeAll()
    }
}
#endif
