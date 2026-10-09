import Foundation

/// Deterministic RNG (SplitMix64) so a seeded route replays identically in tests.
public struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    public mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }

    /// Standard normal sample (Box–Muller).
    public mutating func gaussian() -> Double {
        let u1 = max(unit(), 1e-12), u2 = unit()
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
}

/// Smooth 1-D noise in 0...1. Congestion built from this thickens and clears
/// gradually along the road instead of flickering tick to tick.
struct ValueNoise1D: Sendable {
    let knots: [Double]
    let wavelength: Double

    init(length: Double, wavelength: Double, rng: inout SeededRandom) {
        self.wavelength = wavelength
        let n = Int(max(length, 0) / wavelength) + 3
        knots = (0..<n).map { _ in rng.unit() }
    }

    func value(at x: Double) -> Double {
        let k = max(x, 0) / wavelength
        let i = min(Int(k), knots.count - 2)
        var u = min(k - Double(i), 1)
        u = u * u * (3 - 2 * u)
        return knots[i] * (1 - u) + knots[i + 1] * u
    }
}

/// GPS-like position noise. Each tick's error is correlated with the last
/// (AR(1)); independent noise would make a parked phone look like it's driving.
/// While parked the error is held still.
struct CorrelatedJitter: Sendable {
    var sigma: Double
    var rho: Double = 0.95
    private(set) var east: Double = 0
    private(set) var north: Double = 0

    init(sigma: Double) { self.sigma = sigma }

    mutating func step(moving: Bool, rng: inout SeededRandom) -> (east: Double, north: Double) {
        guard sigma > 0 else { return (0, 0) }
        if moving {
            let sd = sigma * (1 - rho * rho).squareRoot()
            east = rho * east + rng.gaussian() * sd
            north = rho * north + rng.gaussian() * sd
        }
        return (east, north)
    }
}
