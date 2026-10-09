import Foundation

/// A WGS-84 coordinate. SpoofKit stays free of CoreLocation so it builds and
/// tests anywhere; the app converts to and from `CLLocationCoordinate2D`.
public struct Coordinate: Codable, Hashable, Sendable, CustomStringConvertible {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public var isValid: Bool {
        latitude.isFinite && longitude.isFinite
            && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }

    public var description: String {
        String(format: "%.6f, %.6f", latitude, longitude)
    }
}

public enum Geo {
    public static let earthRadius = 6_371_008.8

    @inline(__always) static func rad(_ d: Double) -> Double { d * .pi / 180 }
    @inline(__always) static func deg(_ r: Double) -> Double { r * 180 / .pi }

    /// Wraps a longitude into -180...180.
    public static func normalizeLongitude(_ lon: Double) -> Double {
        var l = lon.truncatingRemainder(dividingBy: 360)
        if l > 180 { l -= 360 }
        if l < -180 { l += 360 }
        return l
    }

    /// Great-circle distance in metres (haversine).
    public static func distance(_ a: Coordinate, _ b: Coordinate) -> Double {
        let dLat = rad(b.latitude - a.latitude)
        let dLon = rad(b.longitude - a.longitude)
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(rad(a.latitude)) * cos(rad(b.latitude)) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    /// Initial bearing from `a` to `b`, degrees clockwise from north, 0..<360.
    public static func bearing(_ a: Coordinate, _ b: Coordinate) -> Double {
        let φ1 = rad(a.latitude), φ2 = rad(b.latitude)
        let Δλ = rad(b.longitude - a.longitude)
        let y = sin(Δλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        let θ = deg(atan2(y, x))
        return (θ + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Point reached by travelling `distance` metres from `origin` on `bearing`.
    public static func destination(from origin: Coordinate, bearing: Double, distance: Double) -> Coordinate {
        let δ = distance / earthRadius
        let θ = rad(bearing)
        let φ1 = rad(origin.latitude), λ1 = rad(origin.longitude)
        let φ2 = asin(sin(φ1) * cos(δ) + cos(φ1) * sin(δ) * cos(θ))
        let λ2 = λ1 + atan2(sin(θ) * sin(δ) * cos(φ1), cos(δ) - sin(φ1) * sin(φ2))
        return Coordinate(latitude: deg(φ2), longitude: normalizeLongitude(deg(λ2)))
    }

    /// Linear interpolation; accurate for the short (metre-scale) segments we use.
    public static func interpolate(_ a: Coordinate, _ b: Coordinate, _ t: Double) -> Coordinate {
        var dLon = b.longitude - a.longitude
        if dLon > 180 { dLon -= 360 }
        if dLon < -180 { dLon += 360 }
        return Coordinate(
            latitude: a.latitude + (b.latitude - a.latitude) * t,
            longitude: normalizeLongitude(a.longitude + dLon * t)
        )
    }

    /// Shifts a coordinate by a local east/north offset in metres.
    public static func offset(_ c: Coordinate, east: Double, north: Double) -> Coordinate {
        let dLat = deg(north / earthRadius)
        let dLon = deg(east / (earthRadius * max(cos(rad(c.latitude)), 1e-6)))
        return Coordinate(latitude: c.latitude + dLat, longitude: normalizeLongitude(c.longitude + dLon))
    }

    /// Local east/north metres of `p` relative to `origin` (equirectangular).
    static func localXY(_ p: Coordinate, origin: Coordinate) -> (x: Double, y: Double) {
        var dLon = p.longitude - origin.longitude
        if dLon > 180 { dLon -= 360 }
        if dLon < -180 { dLon += 360 }
        let x = rad(dLon) * earthRadius * cos(rad(origin.latitude))
        let y = rad(p.latitude - origin.latitude) * earthRadius
        return (x, y)
    }
}
