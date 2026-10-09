import XCTest
@testable import SpoofKit

final class GeoTests: XCTestCase {
    func testDistanceMumbaiToPune() {
        let mumbai = Coordinate(latitude: 19.0760, longitude: 72.8777)
        let pune = Coordinate(latitude: 18.5204, longitude: 73.8567)
        XCTAssertEqual(Geo.distance(mumbai, pune), 120_000, accuracy: 3_000)
    }

    func testDestinationRoundTrip() {
        let a = Coordinate(latitude: 51.5, longitude: -0.12)
        let b = Geo.destination(from: a, bearing: 73, distance: 1234)
        XCTAssertEqual(Geo.distance(a, b), 1234, accuracy: 0.5)
        XCTAssertEqual(Geo.bearing(a, b), 73, accuracy: 0.1)
    }

    func testAntimeridian() {
        let a = Coordinate(latitude: 0, longitude: 179.9999)
        let b = Geo.destination(from: a, bearing: 90, distance: 100)
        XCTAssertTrue(b.isValid)
        XCTAssertLessThan(b.longitude, 0)
        XCTAssertEqual(Geo.distance(a, b), 100, accuracy: 0.5)
    }

    func testInvalidCoordinates() {
        XCTAssertFalse(Coordinate(latitude: 91, longitude: 0).isValid)
        XCTAssertFalse(Coordinate(latitude: .nan, longitude: 0).isValid)
    }
}

/// Helpers for synthetic routes.
enum Routes {
    static let origin = Coordinate(latitude: 19.0, longitude: 72.85)

    static func straight(_ meters: Double, bearing: Double = 0) -> RoutePath {
        RoutePath(coordinates: [origin, Geo.destination(from: origin, bearing: bearing, distance: meters)])!
    }

    /// City grid: blocks of 150–450 m with right-angle turns. Returns path + junctions.
    static func city(length: Double = 8000, seed: UInt64 = 7) -> (RoutePath, [Double]) {
        var rng = SeededRandom(seed: seed)
        var pts = [origin]
        var heading = 0.0
        var s = 0.0
        var junctions: [Double] = []
        while s < length {
            let block = 150 + rng.unit() * 300
            pts.append(Geo.destination(from: pts.last!, bearing: heading, distance: block))
            s += block
            junctions.append(s)
            let turns = [0.0, 0, 90, -90, 30, -30]
            let turn = turns[Int(rng.unit() * Double(turns.count))]
            if turn != 0 {
                // round the corner over a few points so curvature is finite
                let r = abs(turn) > 45 ? 12.0 : 60.0
                let arc = abs(turn) * .pi / 180 * r
                for k in 1...6 {
                    heading += turn / 6
                    pts.append(Geo.destination(from: pts.last!, bearing: heading, distance: arc / 6))
                }
                s += arc
            }
        }
        return (RoutePath(coordinates: pts)!, junctions)
    }
}

final class RoutePathTests: XCTestCase {
    func testDensifyKeepsLength() {
        let p = Routes.straight(1000)
        XCTAssertEqual(p.length, 1000, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(p.points.count, 500)
        XCTAssertEqual(Geo.distance(p.position(at: 500), p.start), 500, accuracy: 0.5)
        XCTAssertEqual(p.position(at: 5000), p.end)
    }

    func testRejectsDegenerate() {
        XCTAssertNil(RoutePath(coordinates: [Routes.origin]))
        XCTAssertNil(RoutePath(coordinates: [Routes.origin, Routes.origin]))
    }

    func testReversed() {
        let p = Routes.straight(300, bearing: 45)
        let r = p.reversed()
        XCTAssertEqual(r.start, p.end)
        XCTAssertEqual(r.length, p.length, accuracy: 0.001)
        XCTAssertEqual(r.course(at: 10), 225, accuracy: 0.5)
    }

    func testTightCornerHasLowSpeedLimit() {
        let (p, _) = Routes.city(length: 2000)
        let limits = p.curvatureSpeedLimits(lateralAcceleration: 2)
        let finite = limits.filter(\.isFinite)
        XCTAssertFalse(finite.isEmpty)
        XCTAssertLessThan(finite.min()!, 7) // 12 m radius → ~4.9 m/s ≈ 18 km/h
    }
}

final class RoutePlayerTests: XCTestCase {
    /// Drives to completion at 1 Hz, returning per-tick fixes.
    func drive(_ player: inout RoutePlayer, maxSeconds: Int = 20_000) -> [MotionFix] {
        var fixes: [MotionFix] = []
        for _ in 0..<maxSeconds {
            let f = player.advance(by: 1)
            fixes.append(f)
            if f.phase == .finished { break }
        }
        return fixes
    }

    func testStraightDriveRespectsSpeedAndFinishes() {
        var p = RoutePlayer(path: Routes.straight(2000), profile: .preset(.drive, speedKmh: 40, jitter: false), seed: 1)
        let fixes = drive(&p)
        XCTAssertTrue(p.isFinished)
        XCTAssertEqual(Geo.distance(fixes.last!.coordinate, Routes.straight(2000).end), 0, accuracy: 1)
        let maxKmh = fixes.map(\.speed).max()! * 3.6
        XCTAssertLessThanOrEqual(maxKmh, 40.01)
        XCTAssertGreaterThan(maxKmh, 39.9)
        // 2 km at 40 km/h = 180 s, plus accelerate/brake
        XCTAssertEqual(Double(fixes.count), 186, accuracy: 6)
    }

    /// What iOS derives (distance between successive fixes) must also be sane.
    func testDerivedSpeedAndAccelerationAreBounded() {
        let (path, junctions) = Routes.city()
        var p = RoutePlayer(path: path, intersections: junctions,
                            profile: .preset(.drive, speedKmh: 40, jitter: false), traffic: .heavy, seed: 3)
        let start = p.currentFix
        let fixes = [start] + drive(&p)
        var prevV = 0.0
        for (a, b) in zip(fixes, fixes.dropFirst()) {
            let v = Geo.distance(a.coordinate, b.coordinate)       // m per 1 s tick
            XCTAssertLessThanOrEqual(v * 3.6, 40.5)
            // ≤ 2 m/s² braking plus the chord-vs-arc effect when stopping on a corner
            XCTAssertLessThanOrEqual(abs(v - prevV), 2.6, "unrealistic jump in derived speed")
            prevV = v
        }
    }

    func testTrafficMakesTripsLongerAndAddsStops() {
        let (path, junctions) = Routes.city()
        func minutes(_ level: TrafficLevel) -> (Double, Int) {
            var p = RoutePlayer(path: path, intersections: junctions,
                                profile: .preset(.drive, speedKmh: 40), traffic: level, seed: 11)
            let fixes = drive(&p)
            var stops = 0
            var wasStopped = false
            for f in fixes {
                let stopped = f.phase == .stopped
                if stopped && !wasStopped { stops += 1 }
                wasStopped = stopped
            }
            return (Double(fixes.count) / 60, stops)
        }
        let none = minutes(.none), light = minutes(.light), heavy = minutes(.heavy)
        XCTAssertEqual(none.0, 12.7, accuracy: 1.5)
        XCTAssertGreaterThan(light.0, none.0)
        XCTAssertGreaterThan(heavy.0, light.0 * 1.4)
        XCTAssertGreaterThan(heavy.1, 5)
    }

    func testSlowsDownForCorners() {
        let a = Routes.origin
        let b = Geo.destination(from: a, bearing: 0, distance: 500)
        var pts = [a, b]
        var heading = 0.0
        for _ in 1...6 { heading += 15; pts.append(Geo.destination(from: pts.last!, bearing: heading, distance: 12 * .pi / 2 / 6)) }
        pts.append(Geo.destination(from: pts.last!, bearing: 90, distance: 500))
        let path = RoutePath(coordinates: pts)!
        var p = RoutePlayer(path: path, profile: .preset(.drive, speedKmh: 60, jitter: false), seed: 2)
        let fixes = drive(&p)
        let apex = pts[4]
        let atApex = fixes.filter { Geo.distance($0.onRoute, apex) < 8 }
        XCTAssertFalse(atApex.isEmpty)
        XCTAssertLessThan(atApex.map(\.speed).max()! * 3.6, 25, "should take a 12 m-radius turn slowly")
        XCTAssertGreaterThan(fixes.map(\.speed).max()! * 3.6, 55, "and speed back up afterwards")
    }

    func testParkedPhoneHasNoPhantomMovement() {
        let (path, junctions) = Routes.city()
        var p = RoutePlayer(path: path, intersections: junctions,
                            profile: .preset(.drive, speedKmh: 40), traffic: .heavy, seed: 5)
        let fixes = drive(&p)
        for (a, b) in zip(fixes, fixes.dropFirst()) where a.phase == .stopped && b.phase == .stopped {
            // ≤ 5 cm/s creeping up to a stop line; no GPS-noise "phantom driving"
            XCTAssertLessThan(Geo.distance(a.coordinate, b.coordinate), 0.05)
        }
    }

    func testDeterministicWithSeed() {
        let (path, junctions) = Routes.city(length: 3000)
        var a = RoutePlayer(path: path, intersections: junctions, profile: .preset(.drive), traffic: .moderate, seed: 99)
        var b = RoutePlayer(path: path, intersections: junctions, profile: .preset(.drive), traffic: .moderate, seed: 99)
        XCTAssertEqual(drive(&a), drive(&b))
    }

    func testBackAndForthReturnsToStart() {
        let path = Routes.straight(300)
        var p = RoutePlayer(path: path, profile: .preset(.walk, jitter: false), repeatMode: .backAndForth, seed: 1)
        var reachedReturn = false
        for _ in 0..<1000 {
            let f = p.advance(by: 1)
            if p.isReturnLeg { reachedReturn = true }
            if reachedReturn && Geo.distance(f.coordinate, path.start) < 1 { return }
        }
        XCTFail("never came back")
    }

    func testSeekAndEstimate() {
        var p = RoutePlayer(path: Routes.straight(4000), profile: .preset(.drive, speedKmh: 40, jitter: false), seed: 1)
        let full = p.estimatedRemainingTime()
        XCTAssertEqual(full, 366, accuracy: 10)
        p.seek(toProgress: 0.5)
        XCTAssertEqual(p.remainingDistance, 2000, accuracy: 1)
        XCTAssertLessThan(p.estimatedRemainingTime(), full * 0.6)
    }

    func testChangingSpeedMidDrive() {
        var p = RoutePlayer(path: Routes.straight(3000), profile: .preset(.drive, speedKmh: 40, jitter: false), seed: 1)
        for _ in 0..<30 { _ = p.advance(by: 1) }
        p.update(profile: .preset(.drive, speedKmh: 80, jitter: false))
        for _ in 0..<30 { _ = p.advance(by: 1) }
        XCTAssertEqual(p.speed * 3.6, 80, accuracy: 0.5)
    }
}

final class JoystickTests: XCTestCase {
    func testPushNorthMovesNorthAndRampsSpeed() {
        var j = JoystickMover(start: Routes.origin, profile: .preset(.walk))
        var last = Routes.origin
        for _ in 0..<10 { last = j.advance(by: 1, x: 0, y: 1) }
        XCTAssertGreaterThan(last.latitude, Routes.origin.latitude)
        XCTAssertEqual(j.speed * 3.6, 5, accuracy: 0.1)
        for _ in 0..<10 { _ = j.advance(by: 1, x: 0, y: 0) }
        XCTAssertEqual(j.speed, 0)
    }
}

final class GPXTests: XCTestCase {
    func testRoundTrip() throws {
        let pts = [Routes.origin, Geo.destination(from: Routes.origin, bearing: 10, distance: 100)]
        let data = GPX.export(pts, name: "Test & <route>")
        let parsed = try GPX.parse(data)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(Geo.distance(parsed[1], pts[1]), 0, accuracy: 0.05)
    }

    func testPrefersTrackOverWaypoints() throws {
        let xml = """
        <gpx><wpt lat="1" lon="1"/><trk><trkseg><trkpt lat="2" lon="2"/><trkpt lat="3" lon="3"/></trkseg></trk></gpx>
        """
        XCTAssertEqual(try GPX.parse(Data(xml.utf8)).count, 2)
    }

    func testErrors() {
        XCTAssertThrowsError(try GPX.parse(Data("<gpx></gpx>".utf8)))
        XCTAssertThrowsError(try GPX.parse(Data("not xml <".utf8)))
    }
}
