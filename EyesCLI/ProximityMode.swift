import Foundation
import simd

// Tests for the proximity haptics logic: synthetic LiDAR frames of simple scenes are fed to
// `ProximityModel` at the app's rate, and the cues it hands out are checked.
//
// World axes: x to the user's right, y straight ahead, z up, in meters, origin on the floor under
// the phone.

// MARK: Scenes

private struct Box {
    var low: SIMD3<Float>, high: SIMD3<Float>

    init(x: ClosedRange<Float>, y: ClosedRange<Float>, z: ClosedRange<Float>) {
        low = SIMD3(x.lowerBound, y.lowerBound, z.lowerBound)
        high = SIMD3(x.upperBound, y.upperBound, z.upperBound)
    }

    /// Distance along `direction` to where a ray from `origin` enters the box.
    func hit(from origin: SIMD3<Float>, along direction: SIMD3<Float>) -> Float? {
        var near: Float = 0, far = Float.infinity
        for axis in 0..<3 {
            if abs(direction[axis]) < 1e-9 {
                if origin[axis] < low[axis] || origin[axis] > high[axis] { return nil }
                continue
            }
            let a = (low[axis] - origin[axis]) / direction[axis], b = (high[axis] - origin[axis]) / direction[axis]
            near = max(near, min(a, b))
            far = min(far, max(a, b))
            if near > far { return nil }
        }
        return near > 0 ? near : nil
    }
}

private struct Scene {
    var boxes: [Box] = []
    /// Height of the ground plane, nil for none.
    var ground: Float? = 0

    static let wide: ClosedRange<Float> = -5...5
    static let tall: ClosedRange<Float> = 0...3

    static func wall(at distance: Float) -> Scene {
        Scene(boxes: [Box(x: wide, y: distance...distance + 0.2, z: tall)])
    }
}

/// How the phone is held.
private struct Pose {
    var height: Float = 1.3
    /// Degrees the camera points below level, clockwise about its axis, and to the left of straight ahead.
    var pitch: Float = 15, roll: Float = 0, yaw: Float = 0
}

/// The sensor's imperfections.
private struct Flaws {
    /// Depth noise as a fraction of the depth (plus half a centimeter).
    var noise: Float = 0
    /// Fraction of pixels with no reading, and of pixels with a wild one.
    var holes: Float = 0, speckle: Float = 0
    /// Degrees by which the reported gravity is off in pitch.
    var gravityError: Float = 0
}

private struct Random {
    var state: UInt64

    mutating func unit() -> Float {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Float((z ^ (z >> 31)) >> 40) / Float(1 << 24)
    }

    mutating func normal() -> Float {
        sqrt(-2 * log(max(unit(), 1e-7))) * cos(2 * .pi * unit())
    }
}

// MARK: Depth camera

/// A pinhole LiDAR camera like the phone's in portrait: 240 x 320, 55 degrees across, 70 up and down,
/// depth measured along the optical axis, readings up to a little past 5 m.
private struct Camera {
    static let width = 240, height = 320
    static let focalX = Float(width) / 2 / tan(27.5 * .pi / 180)
    static let focalY = Float(height) / 2 / tan(35 * .pi / 180)

    let eye: SIMD3<Float>
    /// The device's right, the top of the phone, and the viewing direction, in world axes.
    let right: SIMD3<Float>, top: SIMD3<Float>, axis: SIMD3<Float>

    init(_ pose: Pose) {
        let pitch = pose.pitch * .pi / 180, roll = pose.roll * .pi / 180, yaw = pose.yaw * .pi / 180
        let level = SIMD3<Float>(1, 0, 0)
        let tipped = SIMD3<Float>(0, sin(pitch), cos(pitch))
        func turned(_ v: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3(v.x * cos(yaw) - v.y * sin(yaw), v.x * sin(yaw) + v.y * cos(yaw), v.z)
        }
        eye = SIMD3(0, 0, pose.height)
        axis = turned(SIMD3(0, cos(pitch), -sin(pitch)))
        right = turned(cos(roll) * level + sin(roll) * tipped)
        top = turned(cos(roll) * tipped - sin(roll) * level)
    }

    /// Gravity as CoreMotion reports it: in device axes, z out of the screen (against the view).
    var gravity: SIMD3<Float> { SIMD3(-right.z, -top.z, axis.z) }

    func depthMap(of scene: Scene, flaws: Flaws, random: inout Random) -> DepthMap? {
        var meters = [Float](repeating: .nan, count: Self.width * Self.height)
        for y in 0..<Self.height {
            let v = (Float(y) - Float(Self.height - 1) / 2) / Self.focalY
            for x in 0..<Self.width {
                let u = (Float(x) - Float(Self.width - 1) / 2) / Self.focalX
                // One unit along the axis per unit of `depth`, as in a depth map.
                let ray = axis + u * right - v * top
                var depth = Float.infinity
                if let ground = scene.ground, ray.z < 0 { depth = (ground - eye.z) / ray.z }
                for box in scene.boxes {
                    if let hit = box.hit(from: eye, along: ray), hit < depth { depth = hit }
                }
                if flaws.noise > 0 { depth += (depth * flaws.noise + 0.005) * random.normal() }
                if flaws.speckle > 0, random.unit() < flaws.speckle { depth = 0.2 + 3 * random.unit() }
                if flaws.holes > 0, random.unit() < flaws.holes { depth = random.unit() < 0.5 ? .nan : 0 }
                if depth < 5.5 { meters[y * Self.width + x] = depth }
            }
        }
        return DepthMap(width: Self.width, height: Self.height, meters: meters)
    }
}

// MARK: Running the model

private struct Moment {
    var time: TimeInterval
    var distance: Float?
    var floor: Float?
}

private struct Run {
    var ticks: [TimeInterval] = []
    var strengths: [Float] = []
    var buzzes: [TimeInterval] = []
    var moments: [Moment] = []

    var cues: [TimeInterval] { (ticks + buzzes).sorted() }
    var isSilent: Bool { ticks.isEmpty && buzzes.isEmpty }
    func ticks(after time: TimeInterval) -> [TimeInterval] { ticks.filter { $0 >= time } }
    func cues(from start: TimeInterval, to end: TimeInterval) -> Int { cues.filter { $0 >= start && $0 < end }.count }
    /// Mean time between taps from `time` on.
    func interval(after time: TimeInterval) -> Double? {
        let late = ticks(after: time)
        return late.count >= 2 ? (late.last! - late.first!) / Double(late.count - 1) : nil
    }
    /// Largest relative difference between a gap and the mean gap, from `time` on.
    func unevenness(after time: TimeInterval) -> Double {
        let late = ticks(after: time)
        guard let mean = interval(after: time) else { return 0 }
        return zip(late, late.dropFirst()).map { abs(($1 - $0) - mean) / mean }.max() ?? 0
    }
    /// The longest silence between the starts of consecutive buzz stretches.
    var buzzGap: Double { zip(buzzes, buzzes.dropFirst()).map { $1 - $0 }.max() ?? 0 }
}

private let rate = 15.0

/// Feeds the model the world as it is at each update for `seconds`. `world` returns nil when the
/// camera delivers no depth.
private func run(_ seconds: Double, flaws: Flaws = Flaws(), seed: UInt64 = 1,
                 world: (TimeInterval) -> (Scene, Pose)?) -> Run {
    var model = ProximityModel()
    var random = Random(state: seed)
    var result = Run()
    for frame in 0..<Int(seconds * rate) {
        let time = 100 + Double(frame) / rate
        var depth: DepthMap?
        var gravity: SIMD3<Float>?
        if let (scene, pose) = world(time - 100) {
            depth = Camera(pose).depthMap(of: scene, flaws: flaws, random: &random)
            var felt = pose
            felt.pitch += flaws.gravityError
            gravity = Camera(felt).gravity
        }
        switch model.update(depth: depth, gravity: gravity, time: time) {
        case .tick(let at, let intensity, let sharpness):
            result.ticks.append(at - 100)
            result.strengths.append(intensity + sharpness)
        case .buzz(let at, _): result.buzzes.append(at - 100)
        case nil: break
        }
        result.moments.append(Moment(time: time - 100, distance: model.distance, floor: model.floorDepth))
    }
    return result
}

// MARK: Checks

private var failures = 0

private func report(_ name: String, expected: String, got: String, pass: Bool) {
    if !pass { failures += 1 }
    func column(_ text: String, _ width: Int) -> String { text.padding(toLength: max(width, text.count), withPad: " ", startingAt: 0) }
    print(pass ? "PASS" : "FAIL", column(name, 52), column(expected, 34), got)
}

private func describe(_ run: Run) -> String {
    if run.isSilent { return "silent" }
    var parts: [String] = []
    if let gap = run.interval(after: 1) {
        parts.append(String(format: "tap every %.2f s (%.1f/s)", gap, 1 / gap))
    } else if !run.ticks.isEmpty {
        parts.append("\(run.ticks.count) taps")
    }
    if !run.buzzes.isEmpty { parts.append("buzz") }
    if let distance = run.moments.last?.distance { parts.append(String(format: "at %.2f m", distance)) }
    return parts.joined(separator: ", ")
}

/// No cues at all. With `floor`, the model must also have found the floor that far below the phone.
private func expectSilent(_ name: String, seconds: Double = 3, flaws: Flaws = Flaws(), floor: Float? = nil,
                          world: (TimeInterval) -> (Scene, Pose)?) {
    let result = run(seconds, flaws: flaws, world: world)
    guard let floor else { return report(name, expected: "silent", got: describe(result), pass: result.isSilent) }
    let found = result.moments.last?.floor ?? .nan
    report(name, expected: String(format: "silent, floor %.2f m below", floor),
           got: describe(result) + String(format: ", floor %.2f m below", found), pass: result.isSilent && abs(found - floor) < 0.05)
}

/// Steady taps for an obstacle `distance` ahead: the model must report it within a bin or two (it
/// rounds towards the user), tap at the rate that goes with what it reports, evenly, and not buzz.
private func expectTaps(_ name: String, at distance: Float, seconds: Double = 4, flaws: Flaws = Flaws(),
                        world: (TimeInterval) -> (Scene, Pose)?) {
    let result = run(seconds, flaws: flaws, world: world)
    let seen = result.moments.last?.distance ?? .nan
    let gap = result.interval(after: 1) ?? .nan
    let pass = seen > distance - 0.12 && seen < distance + 0.04
        && abs(gap - Double(seen * ProximityModel.secondsPerMeter)) < 0.03
        && result.unevenness(after: 1) < 0.15 && result.buzzes.isEmpty
        && (result.ticks.first ?? 9) < 0.3
    report(name, expected: String(format: "tap every %.2f s, %.2f m", distance * ProximityModel.secondsPerMeter, distance),
           got: describe(result), pass: pass)
}

private func expectBuzz(_ name: String, seconds: Double = 3, world: (TimeInterval) -> (Scene, Pose)?) {
    let result = run(seconds, world: world)
    let pass = result.ticks.isEmpty && result.buzzes.count > 5 && (result.buzzes.first ?? 9) < 0.3
        && result.buzzGap <= ProximityModel.buzzLength + 0.001
    report(name, expected: "continuous buzz", got: describe(result), pass: pass)
}

// MARK: Scenarios

func runProximityMode(_ args: [String]) {
    let level = Pose(pitch: 0)
    let open = Scene()
    func still(_ scene: Scene, _ pose: Pose = Pose()) -> (TimeInterval) -> (Scene, Pose)? { { _ in (scene, pose) } }

    print("     scenario".padding(toLength: 57, withPad: " ", startingAt: 0), "expected".padding(toLength: 34, withPad: " ", startingAt: 0), "got")

    print("-- a wall straight ahead")
    expectSilent("wall 3.0 m, phone level", world: still(.wall(at: 3.0), level))
    expectSilent("wall 2.3 m, phone level", world: still(.wall(at: 2.3), level))
    expectTaps("wall 1.5 m, phone level", at: 1.5, world: still(.wall(at: 1.5), level))
    expectTaps("wall 1.0 m, tilted down 20", at: 1.0, world: still(.wall(at: 1.0), Pose(pitch: 20)))
    expectTaps("wall 1.0 m, tilted down 20, rolled 10", at: 1.0, world: still(.wall(at: 1.0), Pose(pitch: 20, roll: 10)))
    expectTaps("wall 0.6 m, tilted down 40", at: 0.6, world: still(.wall(at: 0.6), Pose(pitch: 40)))
    expectTaps("wall 1.2 m, tilted up 20", at: 1.2, world: still(.wall(at: 1.2), Pose(pitch: -20)))
    expectTaps("wall 1.0 m, tilted down 60", at: 1.0, world: still(.wall(at: 1.0), Pose(pitch: 60)))
    expectTaps("wall 1.2 m, phone held sideways (rolled 90)", at: 1.2, world: still(.wall(at: 1.2), Pose(pitch: 10, roll: 90)))
    expectBuzz("wall 0.3 m, phone level", world: still(.wall(at: 0.3), level))
    expectBuzz("wall 0.35 m, tilted down 30", world: still(.wall(at: 0.35), Pose(pitch: 30)))

    print("-- open floor from 1.3 m: tilting the phone down must not fire")
    expectSilent("floor, tilted up 15 (no floor in reach)", world: still(open, Pose(pitch: -15)))
    for pitch: Float in [0, 15, 30, 45, 60, 75] {
        expectSilent("floor, tilted down \(Int(pitch))", floor: 1.3, world: still(open, Pose(pitch: pitch)))
    }
    expectSilent("floor, tilted down 30, rolled 12", floor: 1.3, world: still(open, Pose(pitch: 30, roll: 12)))
    expectSilent("floor, tilted down 20, held sideways (rolled 90)", floor: 1.3, world: still(open, Pose(pitch: 20, roll: 90)))
    expectSilent("floor, phone at 1.1 m (elbow), down 30", floor: 1.1, world: still(open, Pose(height: 1.1, pitch: 30)))
    expectSilent("floor, phone at 1.65 m (eye), down 30", floor: 1.65, world: still(open, Pose(height: 1.65, pitch: 30)))
    do {
        // Lower than the model's first guess: it has to find the floor, which it only does slowly upwards.
        let result = run(5) { _ in (open, Pose(height: 0.9, pitch: 30)) }
        report("floor, phone at 0.9 m (waist) from the start", expected: "silent within 1.5 s",
               got: result.isSilent ? "silent" : String(format: "%d taps, the last at %.2f s", result.cues.count, result.cues.last!),
               pass: (result.cues.last ?? 0) < 1.5)
    }
    expectSilent("floor, gravity off by +2.5 deg, down 30", flaws: Flaws(gravityError: 2.5), world: still(open, Pose(pitch: 30)))
    expectSilent("floor, gravity off by -2.5 deg, down 10", flaws: Flaws(gravityError: -2.5), world: still(open, Pose(pitch: 10)))
    expectSilent("floor rising 4 deg ahead (ramp), down 20",
                 world: still(Scene(boxes: (0..<40).map { Box(x: Scene.wide, y: Float($0) * 0.1...9, z: 0...Float($0) * 0.007) }), Pose(pitch: 20)))

    // A road 15 cm below the pavement, its kerb half a meter to the right.
    expectSilent("pavement, road 15 cm lower 0.5 m to the right", seconds: 6,
                 world: still(Scene(boxes: [Box(x: -5...0.5, y: -2...9, z: -0.15...0)], ground: -0.15), Pose(pitch: 20)))

    print("-- low things on the floor")
    let chair = Scene(boxes: [Box(x: -0.22...0.22, y: 1.2...1.65, z: 0...0.45)])
    expectTaps("chair seat 0.45 m high at 1.2 m, down 25", at: 1.2, world: still(chair, Pose(pitch: 25)))
    expectTaps("chair seat 0.45 m high at 1.2 m, phone level", at: 1.2, world: still(chair, level))
    let step = Scene(boxes: [Box(x: Scene.wide, y: 1.0...6, z: 0...0.17)])
    expectTaps("step up 17 cm at 1.0 m, down 30", at: 1.0, world: still(step, Pose(pitch: 30)))
    let stairs = Scene(boxes: (0..<8).map { Box(x: Scene.wide, y: 1.2 + 0.28 * Float($0)...6, z: 0...0.17 * Float($0 + 1)) })
    expectTaps("stairs up from 1.2 m, down 20", at: 1.2, world: still(stairs, Pose(pitch: 20)))
    // Legs outside the corridor: only the 3 cm edge of the top is in the way.
    let table = Scene(boxes: [Box(x: -0.7...0.7, y: 1.0...1.8, z: 0.72...0.75),
                              Box(x: -0.7 ... -0.65, y: 1.0...1.05, z: 0...0.72), Box(x: 0.65...0.7, y: 1.0...1.05, z: 0...0.72)])
    expectTaps("table edge 0.75 m high at 1.0 m, down 10", at: 1.0, world: still(table, Pose(pitch: 10)))
    expectTaps("table edge at 1.0 m, phone at 0.95 m, down 10", at: 1.0, world: still(table, Pose(height: 0.95, pitch: 10)))
    expectSilent("door sill 4 cm high at 1.0 m, down 30",
                 world: still(Scene(boxes: [Box(x: Scene.wide, y: 1.0...1.1, z: 0...0.04)]), Pose(pitch: 30)))

    do {
        // Standing in front of the chair for 12 s with the phone level, so the seat is all the corridor shows.
        let result = run(12) { _ in (chair, level) }
        report("chair at 1.2 m, phone level, standing 12 s", expected: "taps throughout",
               got: describe(result) + ", \(result.cues(from: 10, to: 12)) taps in the last 2 s",
               pass: result.cues(from: 10, to: 12) >= 3)
    }

    print("-- narrow and overhead things")
    expectTaps("pole 5 cm wide at 1.5 m, dead ahead", at: 1.5,
               world: still(Scene(boxes: [Box(x: -0.025...0.025, y: 1.5...1.55, z: Scene.tall)])))
    expectTaps("pole 3 cm wide at 1.7 m, 0.2 m to the right", at: 1.7,
               world: still(Scene(boxes: [Box(x: 0.2...0.23, y: 1.7...1.73, z: Scene.tall)])))
    expectSilent("pole 5 cm wide at 1.5 m, 0.6 m to the right",
                 world: still(Scene(boxes: [Box(x: 0.6...0.65, y: 1.5...1.55, z: Scene.tall)])))
    expectTaps("person 1.0 m ahead", at: 1.0,
               world: still(Scene(boxes: [Box(x: -0.22...0.22, y: 1.0...1.25, z: 0...1.75)])))
    expectTaps("shelf at head height (1.6 m) at 1.0 m", at: 1.0,
               world: still(Scene(boxes: [Box(x: Scene.wide, y: 1.0...1.3, z: 1.55...1.75)])))
    expectSilent("door lintel 2.0 m high at 1.0 m",
                 world: still(Scene(boxes: [Box(x: Scene.wide, y: 1.0...1.2, z: 2.0...3)])))
    expectSilent("door lintel 2.0 m at 1.7 m, gravity off by 2.5 deg, level", flaws: Flaws(noise: 0.01, gravityError: 2.5),
                 world: still(Scene(boxes: [Box(x: Scene.wide, y: 1.7...1.9, z: 2.0...3)]), level))
    expectTaps("beam at 1.7 m height at 1.2 m, phone at 1.0 m", at: 1.2,
               world: still(Scene(boxes: [Box(x: Scene.wide, y: 1.2...1.4, z: 1.65...1.8)]), Pose(height: 1.0, pitch: 0)))
    expectSilent("ceiling 2.3 m, tilted up 30",
                 world: still(Scene(boxes: [Box(x: Scene.wide, y: -5...9, z: 2.3...2.5)]), Pose(pitch: -30)))

    print("-- walls alongside")
    let leftWall = Box(x: -0.8 ... -0.6, y: -2...9, z: Scene.tall)
    expectSilent("wall 0.6 m to the left, walking along it", world: still(Scene(boxes: [leftWall])))
    expectSilent("corridor 1.2 m wide, end wall at 6 m", world: still(Scene(boxes: [
        leftWall, Box(x: 0.6...0.8, y: -2...9, z: Scene.tall), Box(x: Scene.wide, y: 6...6.2, z: Scene.tall)])))
    expectSilent("corridor 1.2 m wide, phone level", world: still(Scene(boxes: [
        leftWall, Box(x: 0.6...0.8, y: -2...9, z: Scene.tall)]), level))
    expectSilent("corridor 1.0 m wide, heading wavering 5 deg, 6 s", seconds: 6, world: {
        (Scene(boxes: [Box(x: -0.7 ... -0.5, y: -2...9, z: Scene.tall), Box(x: 0.5...0.7, y: -2...9, z: Scene.tall)]),
         Pose(yaw: 5 * Float(sin(3 * $0))))
    })
    let doorway = Scene(boxes: [Box(x: -5 ... -0.4, y: 1.0...1.15, z: Scene.tall), Box(x: 0.4...5, y: 1.0...1.15, z: Scene.tall),
                                Box(x: -0.4...0.4, y: 1.0...1.15, z: 2.0...3)])
    expectSilent("doorway 0.8 m wide at 1.0 m, centered", world: still(doorway))
    expectTaps("doorway 0.8 m wide at 1.0 m, 0.3 m off center", at: 1.0,
               world: still(Scene(boxes: doorway.boxes.map { Box(x: $0.low.x + 0.3...$0.high.x + 0.3, y: 1.0...1.15, z: $0.low.z...$0.high.z) })))
    // Heading 25 degrees into the wall: the corridor's left edge meets it (0.6 - 0.3 cos 25) / sin 25 ahead.
    expectTaps("wall 0.6 m to the left, heading 25 deg into it", at: 0.78, world: still(Scene(boxes: [leftWall]), Pose(yaw: 25)))

    print("-- a noisy sensor: 1.5% depth noise, 5% holes, 0.5% wild pixels")
    let noisy = Flaws(noise: 0.015, holes: 0.05, speckle: 0.005)
    expectSilent("noisy floor, tilted down 30, 8 s", seconds: 8, flaws: noisy, world: still(open, Pose(pitch: 30)))
    expectSilent("noisy floor, phone level, 8 s", seconds: 8, flaws: noisy, world: still(open, level))
    expectSilent("noisy corridor 1.2 m wide, 8 s", seconds: 8, flaws: noisy, world: still(Scene(boxes: [
        leftWall, Box(x: 0.6...0.8, y: -2...9, z: Scene.tall)])))
    expectTaps("noisy wall 1.2 m", at: 1.2, seconds: 6, flaws: noisy, world: still(.wall(at: 1.2)))
    expectTaps("noisy chair at 1.2 m, down 25", at: 1.2, seconds: 6, flaws: noisy, world: still(chair, Pose(pitch: 25)))
    expectTaps("noisy step up 17 cm at 1.0 m, down 30", at: 1.0, seconds: 6, flaws: noisy, world: still(step, Pose(pitch: 30)))
    expectTaps("noisy pole 5 cm at 1.5 m", at: 1.5, seconds: 6, flaws: noisy,
               world: still(Scene(boxes: [Box(x: -0.025...0.025, y: 1.5...1.55, z: Scene.tall)])))
    expectSilent("a wall at 1.0 m for one frame only", world: { abs($0 - 1) < 0.01 ? (.wall(at: 1.0), Pose()) : (open, Pose()) })
    expectTaps("wall 1.2 m, depth missing every third frame", at: 1.2,
               world: { Int(($0 * rate).rounded()) % 3 == 2 ? nil : (.wall(at: 1.2), Pose()) })
    expectSilent("no depth at all (no LiDAR)", world: { _ in nil })

    print("-- moving")
    // Walking: the phone bobs 6 cm and nods 6 degrees twice a second, and gravity is read 1.5 degrees off.
    expectSilent("walking bob over open floor, 8 s", seconds: 8, flaws: Flaws(noise: 0.01, gravityError: 1.5), world: {
        (open, Pose(height: 1.3 + 0.03 * Float(sin(4 * .pi * $0)), pitch: 20 + 3 * Float(cos(4 * .pi * $0))))
    })

    do {
        // Walking at 1 m/s up to a wall, starting 3.2 m away.
        let wallAt = { (time: TimeInterval) in Float(3.2 - time) }
        let result = run(2.95) { (.wall(at: wallAt($0)), Pose()) }
        let first = result.cues.first.map(wallAt) ?? .nan
        let buzz = result.buzzes.first.map(wallAt) ?? .nan
        let gaps = zip(result.ticks, result.ticks.dropFirst()).map { $1 - $0 }
        let quickening = zip(gaps, gaps.dropFirst()).allSatisfy { $1 < $0 }
        let strengthening = zip(result.strengths, result.strengths.dropFirst()).allSatisfy { $1 > $0 }
        report("walking up to a wall at 1 m/s", expected: "taps from 1.8-1.6 m, buzz 0.45-0.3",
               got: String(format: "first tap at %.2f m, gaps %@ s, buzz from %.2f m", first,
                           gaps.map { String(format: "%.2f", $0) }.joined(separator: " "), buzz),
               pass: first <= 1.8 && first >= 1.6 && gaps.count >= 3 && quickening && strengthening
                   && buzz <= 0.45 && buzz >= 0.3)
    }
    do {
        // Backing away at 0.5 m/s from 1.0 m.
        let wallAt = { (time: TimeInterval) in Float(1.0 + 0.5 * time) }
        let result = run(5) { (.wall(at: wallAt($0)), Pose()) }
        let last = result.cues.last.map(wallAt) ?? .nan
        let gaps = zip(result.ticks, result.ticks.dropFirst()).map { $1 - $0 }
        report("backing away from a wall at 0.5 m/s", expected: "taps slow, stop by 2.0-2.3 m",
               got: String(format: "last tap at %.2f m, gaps %@ s", last, gaps.map { String(format: "%.2f", $0) }.joined(separator: " ")),
               pass: last >= 1.8 && last <= 2.3 && zip(gaps, gaps.dropFirst()).allSatisfy { $1 > $0 - 0.02 })
    }
    do {
        // A wall wavering around the 1.8 m threshold must neither start nor stop the taps by itself.
        let waver = { (time: TimeInterval) in 0.06 * Float(sin(9 * time)) }
        let outside = run(6) { (.wall(at: 1.95 + waver($0)), Pose()) }
        let inside = run(6) { (.wall(at: ($0 < 1 ? 1.7 : 1.9) + waver($0)), Pose()) }
        report("wall wavering at 1.95 m, coming from far", expected: "silent", got: describe(outside), pass: outside.isSilent)
        report("wall wavering at 1.9 m, coming from near", expected: "taps go on, evenly",
               got: describe(inside) + String(format: ", unevenness %.0f%%", inside.unevenness(after: 2) * 100),
               pass: inside.ticks(after: 5).count >= 1 && inside.unevenness(after: 2) < 0.2)
    }
    do {
        // Up against a wall the LiDAR stops reading: the buzz must outlast the last reading, but not for ever.
        let covered = Scene(boxes: [], ground: nil)
        let result = run(5) { $0 < 1 ? (.wall(at: 0.3), Pose()) : (covered, Pose()) }
        let last = result.buzzes.last ?? .nan
        report("wall at 0.3 m, then no readings (too close)", expected: "buzz for 0.7-1.5 s more",
               got: String(format: "buzz until %.2f s after", last + ProximityModel.buzzLength - 1),
               pass: last + ProximityModel.buzzLength - 1 >= 0.7 && last + ProximityModel.buzzLength - 1 <= 1.5 && result.ticks.isEmpty)
    }
    for pitch: Float in [0, 25] {
        // A bed 0.5 m high and 2 m wide, walked up to at 0.8 m/s, then 6 s standing 0.4 m from it.
        // Close up its side and the floor drop out of view and its top looks like a floor seen
        // from lower down: it must go on firing all the way in, and for a while after.
        let bedAt = { (time: TimeInterval) in max(Float(3.0 - 0.8 * time), 0.4) }
        let result = run(9.25) { (Scene(boxes: [Box(x: -1...1, y: bedAt($0)...bedAt($0) + 2, z: 0...0.5)]), Pose(pitch: pitch)) }
        let arrival = (3.0 - 0.4) / 0.8
        let first = result.cues.first.map(bedAt) ?? .nan
        let before = result.cues.filter { $0 < arrival }
        let quiet = zip(before, before.dropFirst()).map { $1 - $0 }.max() ?? 9
        let reported = result.moments.last { $0.time < arrival }?.distance ?? .nan
        report("walking up to a bed, phone tilted down \(Int(pitch))", expected: "taps from 1.8-1.5 m in and 1 s on",
               got: String(format: "first tap at %.2f m, longest gap %.2f s, reads %.2f m on arrival, stops %.1f s after",
                           first, quiet, reported, (result.cues.last ?? 0) - arrival),
               pass: first <= 1.8 && first >= 1.5 && quiet < 0.95 && (result.cues.last ?? 0) - arrival >= 1)
    }
    do {
        // A drop ahead: the floor is believed at the lower level, so the ground before the edge stands out.
        let kerb = run(4) { _ in (Scene(boxes: [Box(x: Scene.wide, y: -2...1.5, z: -0.15...0)], ground: -0.15), Pose(pitch: 20)) }
        report("kerb down 15 cm, 1.5 m ahead", expected: "taps (a drop reads as a step)", got: describe(kerb), pass: kerb.ticks.count >= 3)
        let down = Scene(boxes: [Box(x: Scene.wide, y: -2...1.2, z: -2...0)]
                         + (1..<8).map { Box(x: Scene.wide, y: 1.2...1.2 + 0.28 * Float($0), z: -2 ... -0.17 * Float($0)) }, ground: -2)
        let stairs = run(4) { _ in (down, Pose(pitch: 20)) }
        report("stairs down, 1.2 m ahead", expected: "taps (a drop reads as a step)", got: describe(stairs), pass: stairs.ticks.count >= 3)
    }
    do {
        // Turning from a close wall (which hid the floor for 4 s) to a chair across open floor.
        let result = run(7) { $0 < 4 ? (.wall(at: 0.7), Pose()) : (chair, Pose(pitch: 25)) }
        let seen = result.moments.last?.distance ?? .nan
        let pause = (result.ticks(after: 4).first ?? 9) - 4
        report("4 s facing a wall at 0.7 m, then a chair at 1.2 m", expected: "chair taps within 0.7 s",
               got: String(format: "chair taps after %.2f s, at %.2f m", pause, seen),
               pass: pause < 0.7 && abs(seen - 1.17) < 0.08)
    }
    do {
        // Lowering the phone from chest to waist in 0.4 s lifts the floor 0.3 m in the model's eyes.
        let result = run(6) { (open, Pose(height: 1.3 - 0.3 * Float(min(max(($0 - 2) / 0.4, 0), 1)), pitch: 30)) }
        let last = result.cues.last ?? 0
        report("phone lowered 0.3 m in 0.4 s over open floor", expected: "false taps for at most 2.5 s",
               got: result.isSilent ? "silent" : String(format: "%d cues, the last %.2f s after", result.cues.count, last - 2.4),
               pass: last - 2.4 <= 2.5)
    }
    do {
        // Dropping the arm: too fast to follow, so the floor looks like a platform until it is believed.
        let result = run(8) { (open, Pose(height: $0 < 2 ? 1.3 : 1.0, pitch: 30)) }
        let last = result.cues.last ?? 0
        report("phone dropped 0.3 m at once over open floor", expected: "false taps for at most 2.5 s",
               got: result.isSilent ? "silent" : String(format: "%d cues, the last %.2f s after", result.cues.count, last - 2),
               pass: last - 2 <= 2.5)
    }
    do {
        let result = run(6) { (open, Pose(height: 1.3 + 0.3 * Float(min(max(($0 - 2) / 0.4, 0), 1)), pitch: 30)) }
        report("phone raised 0.3 m in 0.4 s over open floor", expected: "silent", got: describe(result), pass: result.isSilent)
    }

    print("-- many random cases")
    do {
        // Any way of holding the phone over open floor, with any mix of sensor flaws.
        var random = Random(state: 42)
        var failed: [String] = []
        for trial in 0..<150 {
            let pose = Pose(height: 0.95 + 0.75 * random.unit(), pitch: -5 + 70 * random.unit(), roll: -15 + 30 * random.unit())
            let flaws = Flaws(noise: 0.02 * random.unit(), holes: 0.1 * random.unit(), speckle: 0.01 * random.unit(),
                              gravityError: -3 + 6 * random.unit())
            let result = run(3.5, flaws: flaws, seed: UInt64(trial)) { _ in (open, pose) }
            if result.cues.contains(where: { $0 > 1.5 }) {
                failed.append(String(format: "height %.2f pitch %.0f roll %.0f gravity %+.1f noise %.1f%%",
                                     pose.height, pose.pitch, pose.roll, flaws.gravityError, flaws.noise * 100))
            }
        }
        report("150 random holds over open floor, flawed sensor", expected: "silent once settled (1.5 s)",
               got: failed.isEmpty ? "all silent" : "\(failed.count) tapped: " + failed.prefix(3).joined(separator: "; "), pass: failed.isEmpty)
    }
    do {
        // Any box in the path, from 6 cm wide and knee high, at least 15 cm of it inside the view.
        var random = Random(state: 43)
        var failed: [String] = []
        var trial = 0
        while trial < 150 {
            let distance = 0.6 + 1.1 * random.unit(), half = 0.03 + 0.25 * random.unit(), offset = 0.3 * (random.unit() - 0.5)
            let top = 0.35 + 1.5 * random.unit()
            let pose = Pose(height: 1.0 + 0.5 * random.unit(), pitch: 5 + 30 * random.unit(), roll: -10 + 20 * random.unit())
            guard top > pose.height - distance * tan((pose.pitch + 33) * .pi / 180) + 0.15 else { continue }
            trial += 1
            let flaws = Flaws(noise: 0.015 * random.unit(), holes: 0.05 * random.unit(), speckle: 0.005 * random.unit(),
                              gravityError: -2 + 4 * random.unit())
            let box = Box(x: offset - half...offset + half, y: distance...distance + 0.3, z: 0...top)
            let result = run(3.5, flaws: flaws, seed: UInt64(trial)) { _ in (Scene(boxes: [box]), pose) }
            let seen = result.moments.last?.distance ?? .nan
            if !(seen > distance - 0.15 && seen < distance + 0.05 && (result.cues.first ?? 9) < 0.5 && result.cues(from: 1.5, to: 3.5) >= 2) {
                failed.append(String(format: "box at %.2f m, %.0f cm wide, %.2f m high, phone %.2f m pitch %.0f: read %.2f m",
                                     distance, half * 200, top, pose.height, pose.pitch, seen))
            }
        }
        report("150 random boxes 0.6-1.7 m ahead, flawed sensor", expected: "taps, distance right to 15 cm",
               got: failed.isEmpty ? "all found" : "\(failed.count) wrong: " + failed.prefix(3).joined(separator: "; "), pass: failed.isEmpty)
    }

    // The cost of one update, on this Mac.
    var model = ProximityModel()
    var random = Random(state: 7)
    let camera = Camera(Pose(pitch: 20))
    if let depth = camera.depthMap(of: chair, flaws: noisy, random: &random) {
        let start = DispatchTime.now().uptimeNanoseconds
        for frame in 0..<2000 { _ = model.update(depth: depth, gravity: camera.gravity, time: Double(frame) / rate) }
        let micros = Double(DispatchTime.now().uptimeNanoseconds - start) / 2000 / 1000
        print(String(format: "\none update of a %dx%d map: %.0f microseconds", Camera.width, Camera.height, micros))
    }
    print(failures == 0 ? "all passed" : "\(failures) FAILED")
    if failures > 0 { exit(1) }
}
