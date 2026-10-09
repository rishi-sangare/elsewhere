import XCTest
@testable import SpoofKit

/// Fault-injection over the real `SessionSupervisor`, mirroring
/// tools/design_sim.py. The fake "iPhone" keeps a simulated fix only while the
/// session is alive and refreshed within 4 s (assumption A1).
final class SessionSafetyTests: XCTestCase {

    // MARK: Scenario tests

    func testHappyPathBecomesVerifiedOnlyAfterReadback() {
        var s = SessionSupervisor()
        let c = Coordinate(latitude: 19.0, longitude: 72.8)
        XCTAssertEqual(s.handle(.start(c), now: 0), [.connect, .scheduleDeadMan(after: 10)])
        XCTAssertEqual(s.status, .connecting)
        XCTAssertEqual(s.handle(.connected, now: 0.5), [.send(c)])
        XCTAssertEqual(s.status, .active(verified: false), "must not claim verified before read-back")
        _ = s.handle(.readback(c), now: 1.5)
        XCTAssertEqual(s.status, .active(verified: true))
    }

    func testReadbackOfRealLocationNeverVerifies() {
        var s = SessionSupervisor()
        let c = Coordinate(latitude: 19.0, longitude: 72.8)
        let real = Coordinate(latitude: 28.6, longitude: 77.2)
        _ = s.handle(.start(c), now: 0)
        _ = s.handle(.connected, now: 0)
        for t in stride(from: 0.5, through: 4.5, by: 0.5) {
            _ = s.handle(.readback(real), now: t)
            _ = s.handle(.tick, now: t)
            XCTAssertFalse(s.status.isVerified)
        }
    }

    /// iOS goes quiet when the location doesn't change. Holding still must
    /// stay verified on the strength of the last report.
    func testStaticTeleportStaysVerifiedWhenIOSGoesQuiet() {
        var s = SessionSupervisor()
        let c = Coordinate(latitude: 19.0, longitude: 72.8)
        _ = s.handle(.start(c), now: 0)
        _ = s.handle(.connected, now: 0)
        _ = s.handle(.readback(c), now: 1)          // one report, then silence
        for t in stride(from: 1.5, through: 120, by: 0.5) {
            let effects = s.handle(.tick, now: t)
            XCTAssertFalse(effects.contains { if case .raiseAlert = $0 { true } else { false } }, "false alarm at \(t)s")
        }
        XCTAssertEqual(s.status, .active(verified: true))
    }

    /// …but a report of anywhere else (iOS fell back to real GPS) must alarm.
    func testFallbackToRealLocationAlarmsEvenAfterSilence() {
        var s = SessionSupervisor()
        let c = Coordinate(latitude: 19.0, longitude: 72.8)
        let real = Coordinate(latitude: 18.52, longitude: 73.85)
        _ = s.handle(.start(c), now: 0)
        _ = s.handle(.connected, now: 0)
        _ = s.handle(.readback(c), now: 1)
        for t in stride(from: 1.5, through: 60, by: 0.5) { _ = s.handle(.tick, now: t) }
        _ = s.handle(.readback(real), now: 60)       // the one report that matters
        var alertAt: Double?
        for t in stride(from: 60.5, through: 70, by: 0.5) {
            if s.handle(.tick, now: t).contains(where: { if case .raiseAlert = $0 { true } else { false } }) { alertAt = alertAt ?? t }
            if t >= 61.5 { XCTAssertFalse(s.status.isVerified, "still green at \(t)s after real location appeared") }
        }
        XCTAssertNotNil(alertAt)
        XCTAssertLessThanOrEqual(alertAt!, 66)
    }

    func testExposureAlarmFiresWithinFiveSecondsEvenWhileReconnecting() {
        var s = SessionSupervisor()
        let c = Coordinate(latitude: 19.0, longitude: 72.8)
        _ = s.handle(.start(c), now: 0)
        _ = s.handle(.connected, now: 0)
        _ = s.handle(.readback(c), now: 1)
        _ = s.handle(.sendFailed("tunnel closed"), now: 2)
        var alertAt: Double?
        var t = 2.0
        while t < 30 {
            for e in s.handle(.tick, now: t) {
                if case .raiseAlert = e, alertAt == nil { alertAt = t }
                if e == .connect { _ = s.handle(.connectFailed("VPN off"), now: t) }
            }
            t += 0.5
        }
        XCTAssertNotNil(alertAt)
        XCTAssertLessThanOrEqual(alertAt!, 1 + 5 + 0.5, "alarm must not wait for retries to run out")
        if case .lost = s.status {} else { XCTFail("expected .lost, got \(s.status)") }
    }

    func testRecoveryDismissesAlert() {
        var s = SessionSupervisor()
        let c = Coordinate(latitude: 19.0, longitude: 72.8)
        _ = s.handle(.start(c), now: 0)
        for t in stride(from: 0.0, through: 7, by: 0.5) { _ = s.handle(.tick, now: t) }
        XCTAssertTrue(s.isAlerting)
        _ = s.handle(.connected, now: 7)
        let effects = s.handle(.readback(c), now: 8)
        XCTAssertTrue(effects.contains(.dismissAlert))
        XCTAssertEqual(s.status, .active(verified: true))
    }

    func testStopClearsAndNeverClaimsSpoofingAfterwards() {
        var s = SessionSupervisor()
        let c = Coordinate(latitude: 19.0, longitude: 72.8)
        _ = s.handle(.start(c), now: 0)
        _ = s.handle(.connected, now: 0)
        _ = s.handle(.readback(c), now: 1)
        XCTAssertEqual(s.handle(.stop, now: 2), [.clearAndDisconnect, .cancelDeadMan])
        _ = s.handle(.readback(c), now: 2.5)      // stale read-back must not revive it
        XCTAssertEqual(s.handle(.tick, now: 3), [])
        _ = s.handle(.stopCompleted, now: 3)
        XCTAssertEqual(s.status, .idle)
        XCTAssertNil(s.target)
    }

    func testMotionFrozenWhileNotActive() {
        var s = SessionSupervisor()
        _ = s.handle(.start(Coordinate(latitude: 1, longitude: 1)), now: 0)
        XCTAssertFalse(s.shouldAdvanceMotion)
        _ = s.handle(.connected, now: 0)
        XCTAssertTrue(s.shouldAdvanceMotion)
        _ = s.handle(.sendFailed("x"), now: 1)
        XCTAssertFalse(s.shouldAdvanceMotion)
    }

    func testDeadManIsPushedBackEverySecond() {
        var s = SessionSupervisor()
        _ = s.handle(.start(Coordinate(latitude: 1, longitude: 1)), now: 0)
        _ = s.handle(.connected, now: 0)
        var schedules = 0
        for t in stride(from: 0.5, through: 10, by: 0.5) {
            schedules += s.handle(.tick, now: t).filter { if case .scheduleDeadMan = $0 { true } else { false } }.count
        }
        XCTAssertGreaterThanOrEqual(schedules, 9)
    }

    // MARK: Randomized fault injection (I1–I3)

    struct Outcome { var staleGreen = 0.0; var unalerted = 0.0; var greenAfterStop = 0.0 }

    func testInvariantsUnderRandomFaults() {
        var worst = Outcome()
        for seed in 0..<400 {
            let o = runEpisode(seed: UInt64(seed))
            worst.staleGreen = max(worst.staleGreen, o.staleGreen)
            worst.unalerted = max(worst.unalerted, o.unalerted)
            worst.greenAfterStop = max(worst.greenAfterStop, o.greenAfterStop)
        }
        // I1: "verified" can lag reality by at most read-back lag + verify window.
        XCTAssertLessThanOrEqual(worst.staleGreen, 4.0)
        // I2: user told within dead-man lead (10 s) + one step.
        XCTAssertLessThanOrEqual(worst.unalerted, 11.0)
        // I3: never "verified" after Stop.
        XCTAssertEqual(worst.greenAfterStop, 0)
    }

    private func runEpisode(seed: UInt64) -> Outcome {
        var rng = SeededRandom(seed: seed &+ 1)
        var s = SessionSupervisor()
        let dt = 0.5
        let startAt = 5.0
        let stopAt = 600 + rng.unit() * 250
        let killAt: Double? = rng.unit() < 0.25 ? 100 + rng.unit() * 700 : nil
        let vpnOutage: (Double, Double)? = rng.unit() < 0.4 ? (50 + rng.unit() * 650, 5 + rng.unit() * 115) : nil

        var sessionAlive = false
        var lastSet = -Double.infinity
        var shown = Coordinate(latitude: 0, longitude: 0)
        let realLocation = Coordinate(latitude: 18.5, longitude: 73.8)
        var appAlive = true
        var alerted = false
        var deadManAt: Double?
        var reported: [Coordinate] = []
        var lastDelivered: Coordinate?
        var out = Outcome()
        var staleRun = 0.0
        var exposedSince: Double?
        var target = Coordinate(latitude: 19.0, longitude: 72.8)

        func spoofing(_ t: Double) -> Bool { sessionAlive && t - lastSet <= 4 }

        var t = 0.0
        while t < 900 {
            let vpnUp = vpnOutage.map { !(t >= $0.0 && t < $0.0 + $0.1) } ?? true
            if !vpnUp { sessionAlive = false }
            if sessionAlive && rng.unit() < dt / 180 { sessionAlive = false }
            if let k = killAt, appAlive, t >= k { appAlive = false; sessionAlive = false }

            var queue: [SessionEffect] = []
            if appAlive {
                if abs(t - startAt) < dt / 2 { queue += s.handle(.start(target), now: t) }
                if abs(t - stopAt) < dt / 2 { queue += s.handle(.stop, now: t) }
                // moving target (~10 m/s north)
                if s.shouldAdvanceMotion {
                    target = Geo.offset(target, east: 0, north: 10 * dt)
                    s.setTarget(target)
                }
                reported.append(spoofing(t) ? shown : realLocation)
                let lagged = reported.count >= 3 ? reported[reported.count - 3] : realLocation
                // Like iOS: only report when the location changes.
                if lagged != lastDelivered {
                    lastDelivered = lagged
                    queue += s.handle(.readback(lagged), now: t)
                }
                queue += s.handle(.tick, now: t)
                while !queue.isEmpty {
                    let e = queue.removeFirst()
                    switch e {
                    case .connect:
                        if vpnUp { sessionAlive = true; lastSet = t; queue += s.handle(.connected, now: t) }
                        else { queue += s.handle(.connectFailed("VPN off"), now: t) }
                    case .send(let c):
                        if sessionAlive { lastSet = t; shown = c }
                        else { queue += s.handle(.sendFailed("closed"), now: t) }
                    case .clearAndDisconnect:
                        sessionAlive = false
                        queue += s.handle(.stopCompleted, now: t)
                    case .raiseAlert: alerted = true
                    case .dismissAlert: alerted = false
                    case .scheduleDeadMan(let after): deadManAt = t + after
                    case .cancelDeadMan: deadManAt = nil
                    }
                }
            } else if let d = deadManAt, t >= d {
                alerted = true
                deadManAt = nil
            }

            // While the app lives, intent is whatever the supervisor holds; once
            // killed, the user still expects spoofing until they'd have stopped.
            let wanted = t > startAt && (appAlive ? s.wantsSpoofing : t < stopAt)
            let green = appAlive && s.status.isVerified
            if green && !spoofing(t) { staleRun += dt; out.staleGreen = max(out.staleGreen, staleRun) } else { staleRun = 0 }
            if wanted && !spoofing(t) {
                if exposedSince == nil { exposedSince = t }
                if !alerted { out.unalerted = max(out.unalerted, t - exposedSince!) }
            } else {
                exposedSince = nil
            }
            if t > stopAt + dt && green { out.greenAfterStop += dt }
            t += dt
        }
        return out
    }
}
