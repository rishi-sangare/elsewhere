import Foundation

public struct SessionConfig: Sendable, Equatable {
    /// Re-send the current fix this often, even when standing still; iOS falls
    /// back to real GPS if the simulated fix isn't refreshed.
    public var heartbeat: TimeInterval = 1
    /// "Verified" only if the location iOS reports matched what we sent this recently.
    public var verifyWindow: TimeInterval = 3
    /// Real location visible for this long while spoofing is wanted → alarm.
    public var exposureAlarmAfter: TimeInterval = 5
    /// Read-back within this many metres of a recently sent fix counts as a match.
    public var matchTolerance: Double = 30
    /// How long sent fixes are remembered for matching (read-back arrives late).
    public var sentHistory: TimeInterval = 6
    public var backoff: [TimeInterval] = [0.5, 1, 2, 4, 8]
    /// The dead-man notification is pushed this far into the future on every
    /// heartbeat. If the app is killed it stops being pushed back and fires.
    public var deadManLead: TimeInterval = 10

    public init() {}
}

public enum SessionStatus: Equatable, Sendable {
    /// Phone shows its real location.
    case idle
    case connecting
    /// Connected and sending. `verified` = iOS is confirmed to be showing our fix.
    case active(verified: Bool)
    case reconnecting(attempt: Int, reason: String)
    /// Spoofing is wanted but not working; the user has been alerted. Still retrying.
    case lost(reason: String)
    case stopping

    public var isVerified: Bool { self == .active(verified: true) }
}

public enum SessionEvent: Equatable, Sendable {
    case start(Coordinate)
    case connected
    case connectFailed(String)
    case sendFailed(String)
    /// The location iOS is currently reporting, from our own CLLocationManager.
    case readback(Coordinate)
    case tick
    case stop
    case stopCompleted
}

public enum SessionEffect: Equatable, Sendable {
    case connect
    case send(Coordinate)
    case clearAndDisconnect
    case raiseAlert(String)
    case dismissAlert
    case scheduleDeadMan(after: TimeInterval)
    case cancelDeadMan
}

/// The session state machine. Pure logic: events in, effects out, no I/O, no
/// clock of its own. This is what keeps the app's promise:
///
///   * never show "verified" unless iOS really reports our fix;
///   * tell the user within seconds whenever their real location is showing;
///   * after Stop, never claim to be spoofing.
///
/// `tools/design_sim.py` and `SessionSafetyTests` fault-inject this logic.
public struct SessionSupervisor: Sendable {
    public let config: SessionConfig
    public private(set) var status: SessionStatus = .idle
    public private(set) var target: Coordinate?
    public private(set) var isAlerting = false

    private var wants = false
    private var connectInFlight = false
    private var lastSend: TimeInterval = -.infinity
    private var lastMatch: TimeInterval = -.infinity
    private var lastDeadMan: TimeInterval = -.infinity
    private var connectedAt: TimeInterval = -.infinity
    private var nextRetry: TimeInterval = 0
    private var failures = 0
    private var sent: [(time: TimeInterval, coordinate: Coordinate)] = []

    public init(config: SessionConfig = SessionConfig()) {
        self.config = config
    }

    public var wantsSpoofing: Bool { wants }

    /// Motion (routes, joystick) only advances while connected, so a reconnect
    /// never produces a jump that looks like 900 km/h.
    public var shouldAdvanceMotion: Bool {
        if case .active = status { return true }
        return false
    }

    /// Engine updates where we want iOS to be; sent on the next heartbeat.
    public mutating func setTarget(_ c: Coordinate) {
        guard wants, c.isValid else { return }
        target = c
    }

    public mutating func handle(_ event: SessionEvent, now: TimeInterval) -> [SessionEffect] {
        switch event {
        case .start(let c):
            guard c.isValid else { return [] }
            target = c
            guard !wants else { return [] }   // already running: just a new target
            wants = true
            status = .connecting
            lastMatch = now
            failures = 0
            sent = []
            hasMatchedSinceStart = false
            isAlerting = false
            connectInFlight = true
            lastDeadMan = now
            return [.connect, .scheduleDeadMan(after: config.deadManLead)]

        case .connected:
            guard wants else { return [] }
            connectInFlight = false
            failures = 0
            connectedAt = now
            status = .active(verified: now - lastMatch <= config.verifyWindow && hasMatchedSinceStart)
            return sendNow(now)

        case .connectFailed(let reason):
            guard wants else { return [] }
            connectInFlight = false
            failures += 1
            nextRetry = now + config.backoff[min(failures - 1, config.backoff.count - 1)]
            status = failures >= config.backoff.count || isAlerting
                ? .lost(reason: reason)
                : .reconnecting(attempt: failures, reason: reason)
            return exposureCheck(now, reason: reason)

        case .sendFailed(let reason):
            guard wants, case .active = status else { return [] }
            failures = 0
            nextRetry = now + config.backoff[0]
            status = .reconnecting(attempt: 1, reason: reason)
            return exposureCheck(now, reason: reason)

        case .readback(let c):
            latestReadback = c
            guard wants else { return [] }
            return checkReadback(now)

        case .tick:
            guard wants else { return [] }
            var effects: [SessionEffect] = []
            switch status {
            case .active:
                if now - lastSend >= config.heartbeat { effects += sendNow(now) }
                status = .active(verified: hasMatchedSinceStart && now - lastMatch <= config.verifyWindow)
            case .reconnecting, .lost:
                if !connectInFlight && now >= nextRetry {
                    connectInFlight = true
                    effects.append(.connect)
                }
            case .connecting, .idle, .stopping:
                break
            }
            // iOS only reports a location when it changes. While we hold still,
            // silence is expected: what counts is whether the LATEST location
            // iOS reported is the one we're sending. A fall-back to real GPS
            // shows up as a new, different report.
            if case .active = status { effects += checkReadback(now) }
            effects += exposureCheck(now, reason: "iOS isn't showing the fake location")
            if now - lastDeadMan >= config.heartbeat {
                lastDeadMan = now
                effects.append(.scheduleDeadMan(after: config.deadManLead))
            }
            return effects

        case .stop:
            guard wants || status != .idle else { return [] }
            wants = false
            connectInFlight = false
            target = nil
            status = .stopping
            var effects: [SessionEffect] = [.clearAndDisconnect, .cancelDeadMan]
            if isAlerting {
                isAlerting = false
                effects.append(.dismissAlert)
            }
            return effects

        case .stopCompleted:
            if status == .stopping { status = .idle }
            return []
        }
    }

    // MARK: - Private

    private var hasMatchedSinceStart = false
    /// Most recent location iOS reported, kept across ticks.
    private var latestReadback: Coordinate?

    private mutating func checkReadback(_ now: TimeInterval) -> [SessionEffect] {
        guard let r = latestReadback else { return [] }
        let matchesTarget = target.map { Geo.distance($0, r) <= config.matchTolerance } ?? false
        guard matchesSent(r, now: now) || (matchesTarget && sent.contains { Geo.distance($0.coordinate, r) <= config.matchTolerance })
        else {
            // iOS is reporting somewhere else: never green, not even briefly.
            if case .active = status { status = .active(verified: false) }
            return []
        }
        lastMatch = now
        hasMatchedSinceStart = true
        var effects: [SessionEffect] = []
        if isAlerting {
            isAlerting = false
            effects.append(.dismissAlert)
        }
        if case .active = status { status = .active(verified: true) }
        return effects
    }

    private mutating func sendNow(_ now: TimeInterval) -> [SessionEffect] {
        guard let target else { return [] }
        lastSend = now
        sent.append((now, target))
        sent.removeAll { now - $0.time > config.sentHistory }
        return [.send(target)]
    }

    private func matchesSent(_ c: Coordinate, now: TimeInterval) -> Bool {
        sent.contains { now - $0.time <= config.sentHistory && Geo.distance($0.coordinate, c) <= config.matchTolerance }
    }

    /// Runs in EVERY state while spoofing is wanted. (The first design paused
    /// this while reconnecting; the simulation showed an 18 s silent exposure.)
    private mutating func exposureCheck(_ now: TimeInterval, reason: String) -> [SessionEffect] {
        guard wants, now - lastMatch > config.exposureAlarmAfter else { return [] }
        var effects: [SessionEffect] = []
        if !isAlerting {
            isAlerting = true
            effects.append(.raiseAlert(reason))
        }
        // Sends "succeed" but iOS ignores them: start a fresh session.
        if case .active = status, now - connectedAt > config.exposureAlarmAfter, !connectInFlight {
            status = .lost(reason: reason)
            nextRetry = now
            failures = 0
            connectInFlight = true
            effects.append(.connect)
        } else if case .reconnecting(_, let r) = status {
            status = .lost(reason: r)
        }
        return effects
    }
}
