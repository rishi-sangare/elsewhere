import Foundation

/// One output sample of a mover.
public struct MotionFix: Sendable, Equatable {
    public enum Phase: Sendable, Equatable { case moving, stopped, finished }

    /// What we send to iOS (route position + GPS-like jitter).
    public var coordinate: Coordinate
    /// The exact position on the route, without jitter (for drawing the map).
    public var onRoute: Coordinate
    /// m/s
    public var speed: Double
    /// degrees clockwise from north
    public var course: Double
    public var phase: Phase
}

public enum RepeatMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case once, loop, backAndForth
    public var id: String { rawValue }
    public var title: String {
        switch self { case .once: "Once"; case .loop: "Loop"; case .backAndForth: "Back & forth" }
    }
}

/// Drives along a `RoutePath` like a real vehicle: accelerates, slows before
/// bends, stops at red lights, and crawls through congestion.
///
/// The only thing iOS accepts is latitude/longitude; it derives speed and
/// course from how successive fixes move. So realism here is entirely about
/// *where* each fix lands at each tick.
public struct RoutePlayer: Sendable {
    public let path: RoutePath
    /// Distances (m) along `path` where junctions are; candidate traffic stops.
    public let intersections: [Double]
    public private(set) var profile: MotionProfile
    public private(set) var traffic: TrafficLevel
    public var repeatMode: RepeatMode

    public private(set) var distance: Double = 0
    public private(set) var speed: Double = 0
    public private(set) var isFinished = false
    public private(set) var legsCompleted = 0
    public private(set) var isReturnLeg = false
    /// Seconds left at the current stop, 0 when not stopped.
    public private(set) var dwellRemaining: Double = 0

    private var leg: RoutePath
    private var envelope: [Double] = []
    private var congestion: ValueNoise1D
    private var stops: [(at: Double, dwell: Double)] = []
    private var rng: SeededRandom
    private var jitter: CorrelatedJitter

    static let substep = 0.05

    public init(path: RoutePath,
                intersections: [Double] = [],
                profile: MotionProfile,
                traffic: TrafficLevel = .none,
                repeatMode: RepeatMode = .once,
                seed: UInt64 = UInt64.random(in: 0...UInt64.max)) {
        self.path = path
        self.intersections = intersections.filter { $0 > 0 && $0 < path.length }.sorted()
        self.profile = profile
        self.traffic = traffic
        self.repeatMode = repeatMode
        self.leg = path
        var rng = SeededRandom(seed: seed)
        self.congestion = ValueNoise1D(length: path.length, wavelength: 600, rng: &rng)
        self.rng = rng
        self.jitter = CorrelatedJitter(sigma: profile.jitterMeters)
        rebuildEnvelope()
        planStops(from: 0)
    }

    // MARK: - Public API

    public var legLength: Double { leg.length }
    public var progress: Double { leg.length > 0 ? min(distance / leg.length, 1) : 1 }
    public var remainingDistance: Double { max(leg.length - distance, 0) }

    /// Changing speed or traffic mid-drive takes effect smoothly from here on.
    public mutating func update(profile: MotionProfile) {
        self.profile = profile
        jitter.sigma = profile.jitterMeters
        rebuildEnvelope()
    }

    public mutating func update(traffic: TrafficLevel) {
        self.traffic = traffic
        planStops(from: distance + 5)
    }

    /// Jumps to a fraction of the current leg (scrubbing).
    public mutating func seek(toProgress p: Double) {
        distance = min(max(p, 0), 1) * leg.length
        dwellRemaining = 0
        isFinished = false
        speed = min(speed, envelope[leg.index(at: distance)])
        planStops(from: distance + 5)
    }

    /// Advances simulated time by `dt` seconds and returns the fix to send.
    public mutating func advance(by dt: Double) -> MotionFix {
        if !isFinished, dt > 0 {
            let n = max(1, Int((dt / Self.substep).rounded(.up)))
            let h = dt / Double(n)
            for _ in 0..<n {
                step(h)
                if isFinished { break }
            }
        }
        let moving = speed > 0.2
        let (e, nOff) = jitter.step(moving: moving, rng: &rng)
        let onRoute = leg.position(at: distance)
        return MotionFix(
            coordinate: Geo.offset(onRoute, east: e, north: nOff),
            onRoute: onRoute,
            speed: speed,
            course: leg.course(at: distance),
            phase: isFinished ? .finished : (moving ? .moving : .stopped)
        )
    }

    /// Current fix without advancing time (no new jitter sample).
    public var currentFix: MotionFix {
        let onRoute = leg.position(at: distance)
        return MotionFix(
            coordinate: Geo.offset(onRoute, east: jitter.east, north: jitter.north),
            onRoute: onRoute, speed: speed, course: leg.course(at: distance),
            phase: isFinished ? .finished : (speed > 0.2 ? .moving : .stopped)
        )
    }

    /// Seconds to finish the current leg, by dry-running a copy of this player
    /// (same planned stops, same congestion), capped at 48 h.
    public func estimatedRemainingTime() -> TimeInterval {
        var copy = self
        copy.repeatMode = .once
        copy.jitter.sigma = 0
        var t: TimeInterval = 0
        while !copy.isFinished && t < 48 * 3600 {
            copy.stepMany(1)
            t += 1
        }
        return t
    }

    // MARK: - Simulation

    private mutating func stepMany(_ dt: Double) {
        let n = max(1, Int((dt / Self.substep).rounded(.up)))
        for _ in 0..<n where !isFinished { step(dt / Double(n)) }
    }

    private mutating func step(_ h: Double) {
        if dwellRemaining > 0 {
            dwellRemaining = max(0, dwellRemaining - h)
            speed = 0
            return
        }
        let nextStop = stops.first?.at ?? leg.length
        let toStop = nextStop - distance

        if toStop <= 0.5 && speed <= 0.5 {
            if !stops.isEmpty {
                dwellRemaining = stops.removeFirst().dwell
                speed = 0
            } else {
                endOfLeg()
            }
            return
        }

        let i = leg.index(at: distance)
        let congestionFactor = 1 - traffic.congestionDepth * congestion.value(at: distance)
        let target = min(
            envelope[i],
            profile.cruiseSpeed * congestionFactor,
            // Plan stops on 75% of max braking so there's headroom: real drivers
            // ease to a stop rather than braking flat out to the line.
            (2 * 0.75 * profile.braking * max(toStop, 0)).squareRoot() + 0.4
        )
        if speed < target {
            speed = min(target, speed + profile.acceleration * h)
        } else {
            speed = max(target, speed - profile.braking * h)
        }
        distance = min(distance + speed * h, nextStop)
    }

    private mutating func endOfLeg() {
        speed = 0
        legsCompleted += 1
        switch repeatMode {
        case .once:
            distance = leg.length
            isFinished = true
        case .loop:
            distance = 0
            planStops(from: 0)
        case .backAndForth:
            isReturnLeg.toggle()
            leg = isReturnLeg ? path.reversed() : path
            distance = 0
            rebuildEnvelope()
            planStops(from: 0)
        }
    }

    private mutating func rebuildEnvelope() {
        let limits = leg.curvatureSpeedLimits(lateralAcceleration: profile.lateralAcceleration)
        var env = limits.map { min(profile.cruiseSpeed, $0) }
        // Backward pass: never arrive at a bend faster than braking allows.
        if env.count >= 2 {
            for i in stride(from: env.count - 2, through: 0, by: -1) {
                let ds = leg.cumulative[i + 1] - leg.cumulative[i]
                env[i] = min(env[i], (env[i + 1] * env[i + 1] + 2 * profile.braking * ds).squareRoot())
            }
        }
        envelope = env
    }

    private mutating func planStops(from minDistance: Double) {
        let legIntersections = isReturnLeg
            ? intersections.map { path.length - $0 }.sorted()
            : intersections
        stops = []
        guard traffic.stopProbability > 0 else { return }
        let range = traffic.stopDuration
        for d in legIntersections where d > minDistance {
            if rng.unit() < traffic.stopProbability {
                let dwell = range.lowerBound + rng.unit() * (range.upperBound - range.lowerBound)
                stops.append((d, dwell))
            }
        }
    }
}
