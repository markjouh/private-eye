import Foundation
import simd

/// What the Taptic Engine should play. Times are on the clock passed to `ProximityModel.update`.
enum ProximityCue: Equatable {
    /// One tap. Taps come faster, stronger and crisper as the obstacle gets closer.
    case tick(at: TimeInterval, intensity: Float, sharpness: Float)
    /// A stretch of continuous buzz: the obstacle is within arm's reach.
    case buzz(at: TimeInterval, duration: TimeInterval)
}

/// The parking-sensor logic: LiDAR depth and the direction of gravity in, haptic cues out. Feed it
/// 10 to 15 times a second.
///
/// An obstacle is whatever stands in the walking corridor: the box of space straight ahead of the
/// phone, as wide as the user's body, from just above the floor up to head height. The box is laid
/// out in the world, using gravity, not in the picture. That is what keeps the floor quiet when the
/// phone is tilted down (floor pixels are close, but they are at floor height), lets a chair or a
/// step count (it stands above floor height), and leaves out a wall alongside (it is off to the
/// side, however much of the picture it fills).
struct ProximityModel {
    // MARK: The corridor

    /// Half the corridor's width: shoulders plus a hand's breadth. Much wider and doorways fire.
    static let halfWidth: Float = 0.3
    /// The corridor's top, above the floor: over a tall user's head, under a door's lintel (2 m).
    static let headHeight: Float = 1.85
    /// How far ahead obstacles are looked for, a little past `releaseDistance`.
    static let reach: Float = 2.2
    /// The least frontal area, in square meters within a 10 cm slice of distance, that makes an
    /// obstacle. A 3 cm pole or table edge has several times this; a speckle of bad pixels does not.
    static let minObstacleArea: Float = 0.005

    /// How far above the floor something must stand to count. The allowance grows with distance
    /// because an error in the gravity direction lifts far floor more than near floor (0.05 per
    /// meter is 3 degrees), so a 17 cm step is picked up from about 1.5 m and a door sill never.
    static func clearance(at ahead: Float) -> Float { 0.08 + 0.05 * ahead }

    // MARK: The floor

    /// The floor's depth below the phone is measured, not assumed: people hold the phone anywhere
    /// from waist to eye height, and the clearance above is far smaller than that spread.
    static let floorRange: ClosedRange<Float> = 0.8...1.8
    /// Where the floor is taken to be before it has been seen: the phone at elbow height. A low
    /// guess, because a deeper floor is believed quickly and a higher one only slowly.
    static let firstFloor: Float = 1.1
    /// Floor farther ahead than this is too sensitive to gravity error to measure the depth from.
    static let floorReach: Float = 2.5
    /// The corridor's floor is measured on the nearest stretch of it in sight, this long. That puts
    /// the measurement at the user's end, with any gravity error growing from there, which is the
    /// error `clearance` allows for.
    static let floorSpan: Float = 1.2
    /// The corridor's floor is only looked for this far short of the nearest obstacle. At the
    /// obstacle and behind it the lowest thing in sight is the obstacle's own foot, and taking that
    /// for floor would let the floor climb a bed's side as the bed comes closer.
    static let floorMargin: Float = 0.15
    /// The least frontal area that makes a floor: about a 60 cm wide, 30 cm long patch seen from
    /// chest height.
    static let minFloorArea: Float = 0.02
    /// The floor is the layer of surface this thick above the deepest level seen. It takes in what
    /// a few degrees of gravity error do to a flat floor, and is also how far the floor may jump up
    /// between updates: enough for the bob of walking, less than any obstacle worth a warning.
    static let floorBand: Float = 0.1
    /// Meters per second at which the believed floor moves down, and up by more than the band; see
    /// `settleFloor`.
    static let floorSinkRate: Float = 1.0, floorRiseRate: Float = 0.1

    // MARK: From distance to cues

    /// Taps start here. At 1 m/s that leaves 1.8 s: two taps to notice (0.6 s), a quarter second to
    /// react and a step to stop, with a little to spare. Farther out, any room would tap all the time.
    static let alarmDistance: Float = 1.8
    /// Taps stop here; the gap keeps an obstacle hovering at the edge from stuttering.
    static let releaseDistance: Float = 2.0
    /// Seconds between taps per meter of distance: 0.9 s apart at 1.8 m, two a second at 1 m, five
    /// a second at 0.4 m. At walking pace the next tap always comes before half the way is gone.
    static let secondsPerMeter: Float = 0.5
    /// Closer than this the taps give way to a continuous buzz: contact is under half a second
    /// away at walking pace, less than it takes to react and stop. The buzz ends at `urgentExit`.
    static let urgentEnter: Float = 0.4, urgentExit: Float = 0.5
    static let buzzLength: TimeInterval = 0.25
    /// Cues are handed out this long before they play, so the engine can place them exactly
    /// instead of on the camera's frame times. Must exceed the time between updates.
    static let lookahead: TimeInterval = 0.1

    /// An obstacle must show in this many updates running before the first tap.
    static let confirmUpdates = 2
    /// How long the way must look clear before the taps stop.
    static let releaseTime: TimeInterval = 0.3
    /// How long the last reading is kept when the sensor cannot see (covered, or closer than it
    /// can range): walking right up to a wall must not end the warning.
    static let blindTime: TimeInterval = 1.0
    /// Seconds over which a reading farther than the last is taken up. A closer one is believed at
    /// once: a late warning is worse than a long one.
    static let retreatTime: Float = 0.2

    // MARK: Reading the depth map

    /// Every second pixel each way: 19 200 samples, and a 3 cm pole at 2 m still covers a column.
    static let step = 2
    /// Vertical field of view of the depth camera in portrait, radians.
    static let fieldOfView: Float = 70 * .pi / 180
    static let nearestReading: Float = 0.05
    static let binSize: Float = 0.05, floorBinSize: Float = 0.025

    // MARK: State

    /// Distance ahead in meters to the obstacle being signalled; nil while the way is clear.
    private(set) var distance: Float?
    /// How far below the phone the floor is believed to be, in meters.
    private(set) var floorDepth = firstFloor
    /// How far ahead the last update's nearest obstacle leaves room to look for the corridor's floor.
    private var floorLimit = floorReach
    private var urgent = false
    private var sightings = 0
    private var lastSeen = -TimeInterval.infinity
    private var lastUpdate = -TimeInterval.infinity
    private var lastTick = -TimeInterval.infinity
    private var buzzEnd = -TimeInterval.infinity
    /// Frontal area of obstacle per slice of distance ahead, and of any surface per slice of depth
    /// below the phone, in the corridor and in the whole view. Kept so that no update allocates.
    private var obstacleArea = [Float](repeating: 0, count: Int((reach / binSize).rounded()))
    private var corridorFloor = [Float](repeating: 0, count: floorBins)
    private var viewFloor = [Float](repeating: 0, count: floorBins)
    private static let floorBins = Int(((floorRange.upperBound - floorRange.lowerBound) / floorBinSize).rounded())

    /// `gravity` is CoreMotion's: in device axes (x to the right of the screen, y to its top, z out
    /// of it towards the user), any length. `time` is in seconds on any steady clock.
    mutating func update(depth: DepthMap?, gravity: SIMD3<Float>?, time: TimeInterval) -> ProximityCue? {
        let elapsed = Float(min(time - lastUpdate, 0.5))
        lastUpdate = time
        var sighting = Sighting.unknown
        if let depth, let gravity { sighting = look(at: depth, gravity: gravity, elapsed: elapsed) }
        track(sighting, time: time, elapsed: elapsed)
        return cue(at: time)
    }

    // MARK: Depth map to nearest obstacle

    private enum Sighting: Equatable {
        case obstacle(Float), clear
        /// Too little of the view has a reading to call the way clear.
        case unknown
    }

    private mutating func look(at depth: DepthMap, gravity: SIMD3<Float>, elapsed: Float) -> Sighting {
        // The camera looks along -z. "Ahead" is that direction with its vertical part removed, so
        // distances are along the ground however the phone is tilted.
        let down = simd_normalize(gravity)
        var ahead = SIMD3<Float>(0, 0, -1) + down.z * down
        let level = simd_length(ahead)
        guard level > 0.2 else { return .unknown }   // pointing at the floor or the ceiling
        ahead /= level
        let side = simd_cross(ahead, down)

        for bin in obstacleArea.indices { obstacleArea[bin] = 0 }
        for bin in corridorFloor.indices { corridorFloor[bin] = 0 }
        for bin in viewFloor.indices { viewFloor[bin] = 0 }
        let width = depth.width, height = depth.height
        let focal = Float(height) / 2 / tan(Self.fieldOfView / 2)
        let centerX = Float(width - 1) / 2, centerY = Float(height - 1) / 2
        // The nearest floor in sight is where the bottom edge of the picture meets it.
        let edge = Float(height) / 2 / focal
        let edgeBelow = -down.y * edge - down.z, edgeAhead = -ahead.y * edge - ahead.z
        let nearestFloor = edgeBelow > 0 ? max(floorDepth * edgeAhead / edgeBelow, 0) : 0
        let floorEnd = min(nearestFloor + Self.floorSpan, Self.floorReach, floorLimit)

        let seen: Bool? = depth.withMeters { base, rowBytes in
            var usable = 0, total = 0
            for y in stride(from: Self.step / 2, to: height, by: Self.step) {
                // The pixel (u, v) at depth z is the point z * (u, -v, -1) in device axes.
                let v = (Float(y) - centerY) / focal
                let rowBelow = -down.y * v - down.z
                let rowAhead = -ahead.y * v - ahead.z
                let rowSide = -side.y * v - side.z
                let row = base + y * rowBytes
                for x in stride(from: Self.step / 2, to: width, by: Self.step) {
                    total += 1
                    let z = row.load(fromByteOffset: x * MemoryLayout<Float32>.size, as: Float32.self)
                    guard z > Self.nearestReading, z <= DepthMap.maxRange else { continue }   // NaN fails too
                    usable += 1
                    let u = (Float(x) - centerX) / focal
                    let forward = z * (ahead.x * u + rowAhead)
                    guard forward > 0, forward < Self.floorReach else { continue }
                    let below = z * (down.x * u + rowBelow)
                    // Pixels cover more the farther they see; weighting by z squared counts area.
                    let area = z * z
                    let inCorridor = abs(z * (side.x * u + rowSide)) <= Self.halfWidth
                    if Self.floorRange.contains(below) {
                        let bin = min(Int((below - Self.floorRange.lowerBound) / Self.floorBinSize), Self.floorBins - 1)
                        viewFloor[bin] += area
                        if inCorridor, forward < floorEnd { corridorFloor[bin] += area }
                    }
                    let above = floorDepth - below   // height above the floor
                    if inCorridor, forward < Self.reach, above > Self.clearance(at: forward), above < Self.headHeight {
                        obstacleArea[min(Int(forward / Self.binSize), obstacleArea.count - 1)] += area
                    }
                }
            }
            return usable * 4 >= total
        }
        guard let seen else { return .unknown }
        // A sample stands for step x step pixels, which at depth z span (step * z / focal) squared.
        let patch = (Float(Self.step) / focal) * (Float(Self.step) / focal)

        // The obstacles above were sorted with the floor as it was believed before this update:
        // one update late, but one pass over the map.
        settleFloor(patch: patch, elapsed: elapsed)

        // The nearest 10 cm slice (two bins, so a surface on a bin edge is not split) with enough in it.
        for bin in 0..<obstacleArea.count - 1
        where (obstacleArea[bin] + obstacleArea[bin + 1]) * patch >= Self.minObstacleArea {
            let nearest = Float(bin + 1) * Self.binSize
            floorLimit = nearest - Self.floorMargin
            return .obstacle(nearest)
        }
        floorLimit = Self.floorReach
        return seen ? .clear : .unknown
    }

    /// Moves the believed floor towards where this update's depth map shows it.
    ///
    /// Deeper, or up to `floorBand` higher, when the corridor shows its floor there: the phone was
    /// raised, or bobs as the user walks. Only the corridor counts, or the road beside a pavement
    /// would turn the pavement into an obstacle.
    ///
    /// Higher than that only slowly, and only when nothing in the whole view is as deep as the
    /// floor was believed to be: the phone was lowered. A chair seat looks just like a floor seen
    /// from lower down, but floor shows beside it, so it never becomes the floor. A bed that fills
    /// the view is told apart only by the slowness, which keeps it an obstacle for the seconds it
    /// takes to walk up to it. The price is a second or two of taps after the phone is lowered a lot.
    private mutating func settleFloor(patch: Float, elapsed: Float) {
        if let found = Self.surface(in: corridorFloor, patch: patch)?.middle, found > floorDepth - Self.floorBand {
            floorDepth = min(found, floorDepth + Self.floorSinkRate * elapsed)
        } else if let found = Self.surface(in: viewFloor, patch: patch)?.deepest, found < floorDepth {
            floorDepth = max(found, floorDepth - Self.floorRiseRate * elapsed)
        }
    }

    /// The deepest level below the phone with a real patch of surface at or under it, and the
    /// middle (half the area above, half below) of the `floorBand` of surface that ends there:
    /// noise and gravity error smear a floor over several levels, and its deepest edge is not it.
    private static func surface(in areas: [Float], patch: Float) -> (deepest: Float, middle: Float)? {
        func depth(_ bin: Int) -> Float { floorRange.lowerBound + (Float(bin) + 0.5) * floorBinSize }
        var deepest = areas.count
        var area: Float = 0
        while area < minFloorArea {
            guard deepest > 0 else { return nil }
            deepest -= 1
            area += areas[deepest] * patch
        }
        let top = max(deepest - Int((floorBand / floorBinSize).rounded()), 0)
        var half: Float = 0
        for bin in top..<areas.count { half += areas[bin] / 2 }
        var middle = areas.count
        area = 0
        while area < half, middle > top {
            middle -= 1
            area += areas[middle]
        }
        return (depth(deepest), depth(middle))
    }

    // MARK: Steadying

    private mutating func track(_ sighting: Sighting, time: TimeInterval, elapsed: Float) {
        switch sighting {
        case .obstacle(let seen) where seen <= (distance == nil ? Self.alarmDistance : Self.releaseDistance):
            lastSeen = time
            if let current = distance {
                distance = seen < current ? seen : current + (seen - current) * (1 - exp(-elapsed / Self.retreatTime))
            } else {
                sightings += 1
                if sightings >= Self.confirmUpdates { distance = seen }
            }
        default:
            sightings = 0
            if time - lastSeen >= (sighting == .unknown ? Self.blindTime : Self.releaseTime) { distance = nil }
        }
        urgent = distance.map { $0 < (urgent ? Self.urgentExit : Self.urgentEnter) } ?? false
    }

    // MARK: Cues

    private mutating func cue(at time: TimeInterval) -> ProximityCue? {
        guard let distance else { return nil }
        if urgent {
            guard buzzEnd <= time + Self.lookahead else { return nil }
            let start = max(buzzEnd, time)
            buzzEnd = start + Self.buzzLength
            return .buzz(at: start, duration: Self.buzzLength)
        }
        // Measured from the last tap with the distance as it is now, so the rhythm follows an
        // approach at once and does not wait out an interval chosen farther away.
        let due = max(lastTick + TimeInterval(distance * Self.secondsPerMeter), buzzEnd)
        guard due <= time + Self.lookahead else { return nil }
        lastTick = max(due, time)
        let closeness = min(max((Self.alarmDistance - distance) / (Self.alarmDistance - Self.urgentEnter), 0), 1)
        return .tick(at: lastTick, intensity: 0.6 + 0.4 * closeness, sharpness: 0.3 + 0.4 * closeness)
    }
}
