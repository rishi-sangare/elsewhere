import Foundation

/// Free movement driven by an on-screen stick. Speed ramps up and down so the
/// derived speed iOS sees stays believable.
public struct JoystickMover: Sendable {
    public private(set) var position: Coordinate
    public private(set) var speed: Double = 0
    public private(set) var course: Double = 0
    public var profile: MotionProfile

    public init(start: Coordinate, profile: MotionProfile) {
        self.position = start
        self.profile = profile
    }

    /// `x`/`y` in -1...1 (right/up). Magnitude scales the target speed.
    public mutating func advance(by dt: Double, x: Double, y: Double) -> Coordinate {
        let mag = min(hypot(x, y), 1)
        let target = mag < 0.05 ? 0 : profile.cruiseSpeed * mag
        if speed < target {
            speed = min(target, speed + profile.acceleration * dt)
        } else {
            speed = max(target, speed - profile.braking * dt)
        }
        if mag >= 0.05 {
            course = (atan2(x, y) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        }
        if speed > 0 {
            position = Geo.destination(from: position, bearing: course, distance: speed * dt)
        }
        return position
    }

    public mutating func teleport(to c: Coordinate) {
        position = c
        speed = 0
    }
}
