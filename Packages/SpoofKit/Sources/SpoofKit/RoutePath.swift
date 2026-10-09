import Foundation

/// A route resampled to roughly even spacing, addressed by distance along it.
/// Tracking progress as "metres travelled" makes playback, scrubbing and
/// resuming exact, independent of how the original polyline was drawn.
public struct RoutePath: Sendable, Equatable {
    public let points: [Coordinate]
    /// `cumulative[i]` is the distance in metres from the start to `points[i]`.
    public let cumulative: [Double]

    public var length: Double { cumulative.last ?? 0 }
    public var start: Coordinate { points[0] }
    public var end: Coordinate { points[points.count - 1] }

    /// Builds a path from raw route coordinates. Returns nil when there are not at
    /// least two distinct, valid points.
    public init?(coordinates: [Coordinate], spacing: Double = 2) {
        let raw = coordinates.filter(\.isValid)
        var cleaned: [Coordinate] = []
        for c in raw where cleaned.last.map({ Geo.distance($0, c) > 0.01 }) ?? true {
            cleaned.append(c)
        }
        guard cleaned.count >= 2 else { return nil }

        var pts: [Coordinate] = [cleaned[0]]
        var cum: [Double] = [0]
        for (a, b) in zip(cleaned, cleaned.dropFirst()) {
            let d = Geo.distance(a, b)
            let n = max(1, Int((d / spacing).rounded(.up)))
            for k in 1...n {
                pts.append(Geo.interpolate(a, b, Double(k) / Double(n)))
                cum.append(cum[cum.count - 1] + d / Double(n))
            }
        }
        self.points = pts
        self.cumulative = cum
    }

    private init(points: [Coordinate], cumulative: [Double]) {
        self.points = points
        self.cumulative = cumulative
    }

    /// Index of the last point at or before distance `s`.
    public func index(at s: Double) -> Int {
        if s <= 0 { return 0 }
        if s >= length { return points.count - 1 }
        var lo = 0, hi = cumulative.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if cumulative[mid] <= s { lo = mid } else { hi = mid }
        }
        return lo
    }

    public func position(at s: Double) -> Coordinate {
        let i = index(at: s)
        guard i < points.count - 1 else { return end }
        let seg = cumulative[i + 1] - cumulative[i]
        let t = seg > 0 ? (s - cumulative[i]) / seg : 0
        return Geo.interpolate(points[i], points[i + 1], t)
    }

    /// Direction of travel at distance `s`, degrees clockwise from north.
    public func course(at s: Double) -> Double {
        let i = min(index(at: s), points.count - 2)
        return Geo.bearing(points[i], points[i + 1])
    }

    public func reversed() -> RoutePath {
        let total = length
        return RoutePath(points: points.reversed(), cumulative: cumulative.reversed().map { total - $0 })
    }

    /// Highest comfortable speed (m/s) at each point given the bend radius there:
    /// v = sqrt(lateralAccel × radius). Straight sections return `.infinity`.
    public func curvatureSpeedLimits(lateralAcceleration: Double, window: Double = 10) -> [Double] {
        var limits = [Double](repeating: .infinity, count: points.count)
        guard points.count >= 3 else { return limits }
        for i in 1..<(points.count - 1) {
            let a = index(at: cumulative[i] - window)
            let b = index(at: cumulative[i] + window) + 1
            guard a < i, b < points.count, b > i else { continue }
            let p0 = Geo.localXY(points[a], origin: points[i])
            let p2 = Geo.localXY(points[b], origin: points[i])
            let la = hypot(p0.x, p0.y), lb = hypot(p2.x, p2.y), lc = hypot(p2.x - p0.x, p2.y - p0.y)
            let cross = abs(p0.x * p2.y - p0.y * p2.x)
            guard cross > 1e-6 else { continue }
            let radius = la * lb * lc / (2 * cross)
            limits[i] = sqrt(lateralAcceleration * radius)
        }
        return limits
    }
}
