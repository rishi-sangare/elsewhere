import Foundation

public enum TravelMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case walk, cycle, drive, custom

    public var id: String { rawValue }

    public var defaultSpeedKmh: Double {
        switch self {
        case .walk: 5
        case .cycle: 15
        case .drive: 40
        case .custom: 40
        }
    }

    public var title: String {
        switch self {
        case .walk: "Walk"
        case .cycle: "Cycle"
        case .drive: "Drive"
        case .custom: "Custom"
        }
    }
}

/// How a mover accelerates, brakes and corners. All values SI (m, m/s, m/s²).
public struct MotionProfile: Codable, Hashable, Sendable {
    public var cruiseSpeed: Double
    public var acceleration: Double
    public var braking: Double
    public var lateralAcceleration: Double
    /// Standard deviation of simulated GPS noise while moving. Frozen when parked.
    public var jitterMeters: Double

    public init(cruiseSpeed: Double, acceleration: Double, braking: Double,
                lateralAcceleration: Double, jitterMeters: Double) {
        self.cruiseSpeed = cruiseSpeed
        self.acceleration = acceleration
        self.braking = braking
        self.lateralAcceleration = lateralAcceleration
        self.jitterMeters = jitterMeters
    }

    public var cruiseSpeedKmh: Double { cruiseSpeed * 3.6 }

    public static func preset(_ mode: TravelMode, speedKmh: Double? = nil, jitter: Bool = true) -> MotionProfile {
        let kmh = min(max(speedKmh ?? mode.defaultSpeedKmh, 1), 250)
        let v = kmh / 3.6
        let j = jitter ? 1.0 : 0.0
        switch mode {
        case .walk:
            return .init(cruiseSpeed: v, acceleration: 0.8, braking: 1.0, lateralAcceleration: 3.0, jitterMeters: 2.5 * j)
        case .cycle:
            return .init(cruiseSpeed: v, acceleration: 1.0, braking: 1.5, lateralAcceleration: 2.0, jitterMeters: 2.5 * j)
        case .drive, .custom:
            return .init(cruiseSpeed: v, acceleration: 2.0, braking: 2.0, lateralAcceleration: 2.0, jitterMeters: 3.0 * j)
        }
    }
}

public enum TrafficLevel: String, Codable, CaseIterable, Sendable, Identifiable {
    case none, light, moderate, heavy

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }

    /// Fraction by which congestion can cut cruise speed at its worst.
    public var congestionDepth: Double {
        switch self { case .none: 0; case .light: 0.20; case .moderate: 0.45; case .heavy: 0.70 }
    }

    /// Chance of being stopped (red light, queue) at each intersection.
    public var stopProbability: Double {
        switch self { case .none: 0; case .light: 0.15; case .moderate: 0.35; case .heavy: 0.55 }
    }

    /// How long a stop lasts, seconds.
    public var stopDuration: ClosedRange<Double> {
        switch self { case .none: 0...0; case .light: 5...20; case .moderate: 10...45; case .heavy: 20...75 }
    }
}
