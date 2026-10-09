import CoreLocation
import Foundation
import Observation
import SpoofKit
import UIKit

/// Orchestrates a spoofing session: motion engine → SessionSupervisor →
/// device backend, with TruthMonitor read-back, dead-man notifications,
/// background keep-alive and crash recovery.
///
/// All decisions about status, retries and alarms are made by the pure
/// `SessionSupervisor` (unit- and fault-tested in SpoofKit). This class only
/// carries out its effects.
@MainActor
@Observable
final class SpoofController {
    enum Mode: Equatable { case idle, teleport, route, joystick }

    struct LogEntry: Identifiable {
        let id = UUID()
        let date = Date()
        let text: String
    }

    // MARK: Observable state

    private(set) var status: SessionStatus = .idle
    private(set) var mode: Mode = .idle
    /// Where we're placing the phone (on-route, without GPS jitter) — for the map.
    private(set) var position: Coordinate?
    /// What iOS is actually reporting right now.
    private(set) var lastReadback: Coordinate?
    private(set) var speed: Double = 0
    private(set) var course: Double = 0
    private(set) var placeName: String?
    private(set) var route: PlannedRoute?
    private(set) var routeSettings: RouteSettings?
    private(set) var progress: Double = 0
    private(set) var remainingDistance: Double = 0
    private(set) var remainingTime: TimeInterval?
    private(set) var dwellRemaining: Double = 0
    private(set) var arrived = false
    private(set) var alertMessage: String?
    private(set) var startedAt: Date?
    private(set) var log: [LogEntry] = []
    /// Set when the app launches and finds a session that died with the app.
    var pendingRecovery: SessionIntent?

    private(set) var locationAuth: CLAuthorizationStatus = .notDetermined
    var isPaused = false
    var playbackRate: Double = 1
    var joystickVector: CGVector = .zero

    var isSpoofing: Bool { supervisor.wantsSpoofing }

    /// What the UI shows. Once the alarm is raised it stays red until iOS
    /// really shows our location again — no flicker through retry states.
    var displayStatus: SessionStatus {
        if supervisor.isAlerting, supervisor.wantsSpoofing {
            return .lost(reason: alertMessage ?? "Not confirmed")
        }
        return status
    }
    var backendName: String { backend.name }

    // MARK: Dependencies

    private let backend: LocationBackend
    private let queue: DeviceCommandQueue
    private let truth = TruthMonitor()
    private let deadMan = DeadManSwitch()
    private let keepAlive = KeepAlive()
    private let liveActivity = LiveActivityController()
    private var stopObserver: NSObjectProtocol?
    private var supervisor = SessionSupervisor()
    private var player: RoutePlayer?
    private var joystick: JoystickMover?
    private var loopTask: Task<Void, Never>?
    private var lastTick: TimeInterval = 0
    private var lastEtaUpdate: TimeInterval = -.infinity
    private var lastIntentSave: TimeInterval = -.infinity
    private var notificationsRequested = false

    init(backend: LocationBackend) {
        self.backend = backend
        self.queue = DeviceCommandQueue(backend: backend)
        truth.onLocation = { [weak self] c in
            guard let self else { return }
            self.lastReadback = c
            self.apply(.readback(c))
        }
        stopObserver = NotificationCenter.default.addObserver(
            forName: .elsewhereStopRequested, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
        locationAuth = truth.authorization
        truth.onAuthorizationChange = { [weak self] status in self?.locationAuth = status }
        if let intent = SessionStore.load(), intent.active {
            pendingRecovery = intent
            SessionStore.clear()
            record("Found a session that ended while the app was closed")
        }
    }

    // MARK: - Actions

    func teleport(to c: Coordinate, name: String?) {
        guard c.isValid else { return }
        player = nil
        joystick = nil
        route = nil
        routeSettings = nil
        arrived = false
        mode = .teleport
        position = c
        speed = 0
        placeName = name
        record("Teleport → \(name ?? c.description)")
        begin(at: c)
        Haptics.tap()
    }

    func startRoute(_ planned: PlannedRoute, settings: RouteSettings) {
        let jitter = UserDefaults.standard.object(forKey: SettingsKey.jitter) as? Bool ?? true
        player = RoutePlayer(
            path: planned.path,
            intersections: planned.junctions,
            profile: .preset(settings.mode, speedKmh: settings.speedKmh, jitter: jitter),
            traffic: settings.traffic,
            repeatMode: settings.repeatMode
        )
        joystick = nil
        route = planned
        routeSettings = settings
        arrived = false
        isPaused = false
        mode = .route
        position = planned.path.start
        placeName = planned.destinationName
        lastEtaUpdate = -.infinity
        record("Route \(Int(planned.distance)) m at \(Int(settings.speedKmh)) km/h, traffic \(settings.traffic.rawValue)")
        begin(at: planned.path.start)
    }

    func startJoystick(at c: Coordinate, mode travel: TravelMode) {
        player = nil
        route = nil
        routeSettings = nil
        arrived = false
        joystick = JoystickMover(start: c, profile: .preset(travel, jitter: false))
        mode = .joystick
        position = c
        placeName = nil
        record("Joystick at \(c.description)")
        begin(at: c)
    }

    func stop() {
        record("Stop requested")
        apply(.stop)
    }

    func togglePause() {
        isPaused.toggle()
        Haptics.tap()
    }

    func seek(to fraction: Double) {
        guard player != nil else { return }
        player!.seek(toProgress: fraction)
        arrived = false
        lastEtaUpdate = -.infinity
        let fix = player!.currentFix
        position = fix.onRoute
        progress = player!.progress
        supervisor.setTarget(fix.coordinate)
    }

    func updateRoute(speedKmh: Double? = nil, traffic: TrafficLevel? = nil) {
        guard var settings = routeSettings, player != nil else { return }
        if let speedKmh {
            settings.speedKmh = speedKmh
            let jitter = UserDefaults.standard.object(forKey: SettingsKey.jitter) as? Bool ?? true
            player!.update(profile: .preset(settings.mode, speedKmh: speedKmh, jitter: jitter))
        }
        if let traffic {
            settings.traffic = traffic
            player!.update(traffic: traffic)
        }
        routeSettings = settings
        lastEtaUpdate = -.infinity
    }

    func resume(_ intent: SessionIntent) {
        pendingRecovery = nil
        teleport(to: intent.coordinate, name: intent.placeName)
    }

    func preflight() async -> [PreflightItem] {
        await backend.preflight()
    }

    func requestLocationPermission() { truth.requestPermission() }
    func requestAlwaysLocation() { truth.requestAlways() }
    var locationAuthorization: Int32 { truth.authorization.rawValue }

    func requestNotificationPermission() async -> Bool {
        notificationsRequested = true
        return await deadMan.requestPermission()
    }

    // MARK: - Session plumbing

    private func begin(at c: Coordinate) {
        if !supervisor.wantsSpoofing {
            startedAt = Date()
            truth.start()
            if UserDefaults.standard.object(forKey: SettingsKey.keepAliveAudio) as? Bool ?? true {
                keepAlive.start()
            }
            if !notificationsRequested {
                notificationsRequested = true
                Task { _ = await deadMan.requestPermission() }
            }
        }
        apply(.start(c))
        saveIntent(force: true)
        startLoop()
        liveActivity.start(startedAt: startedAt ?? Date(), state: activityState)
    }

    private var activityState: SpoofActivityAttributes.ContentState {
        let units = Units(rawValue: UserDefaults.standard.string(forKey: SettingsKey.units) ?? "") ?? .metric
        let health: SpoofActivityAttributes.ContentState.Health
        switch displayStatus {
        case .active(verified: true): health = .verified
        case .lost: health = .lost
        default: health = .connecting
        }
        var title = placeName ?? position?.description ?? "Location changed"
        var detail = health == .lost ? "Real location may be visible — open Elsewhere"
                                     : (health == .verified ? "Every app sees this location" : "Connecting…")
        var speedText: String?
        var progress: Double?
        switch mode {
        case .route:
            title = arrived ? "Arrived · \(placeName ?? "destination")" : "To \(placeName ?? "destination")"
            speedText = Format.speed(speed, units: units)
            progress = self.progress
            if health != .lost, !arrived {
                detail = Format.distance(remainingDistance, units: units) + " left"
                    + (remainingTime.map { " · ETA \(Format.eta($0))" } ?? "")
            }
        case .joystick:
            title = "Joystick"
            speedText = Format.speed(speed, units: units)
        default:
            break
        }
        return .init(health: health, title: title, detail: detail, speedText: speedText, progress: progress)
    }

    private func startLoop() {
        guard loopTask == nil else { return }
        lastTick = now()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        let t = now()
        let dt = min(t - lastTick, 2)   // after a suspension, don't teleport ahead
        lastTick = t

        if supervisor.shouldAdvanceMotion && !isPaused {
            switch mode {
            case .route:
                if var p = player {
                    let fix = p.advance(by: dt * playbackRate)
                    player = p
                    position = fix.onRoute
                    speed = fix.speed
                    course = fix.course
                    progress = p.progress
                    remainingDistance = p.remainingDistance
                    dwellRemaining = p.dwellRemaining
                    supervisor.setTarget(fix.coordinate)
                    if fix.phase == .finished && !arrived {
                        arrived = true
                        remainingTime = 0
                        record("Arrived — holding position")
                        Haptics.success()
                    }
                    if t - lastEtaUpdate > 5 && !arrived {
                        lastEtaUpdate = t
                        remainingTime = p.estimatedRemainingTime() / max(playbackRate, 0.1)
                    }
                }
            case .joystick:
                if var j = joystick {
                    let c = j.advance(by: dt, x: joystickVector.dx, y: joystickVector.dy)
                    joystick = j
                    position = c
                    speed = j.speed
                    course = j.course
                    supervisor.setTarget(c)
                }
            case .teleport, .idle:
                break
            }
        } else if mode == .route {
            speed = 0
        }

        checkAutoStop()
        apply(.tick)
        saveIntent(force: false)
        if supervisor.wantsSpoofing { liveActivity.update(activityState) }
    }

    private func apply(_ event: SessionEvent) {
        let before = status
        let effects = supervisor.handle(event, now: now())
        status = supervisor.status
        if status != before { statusChanged(from: before) }
        for effect in effects { perform(effect) }
    }

    private func perform(_ effect: SessionEffect) {
        switch effect {
        case .connect:
            record("Connecting via \(backend.name)…")
            Task {
                do {
                    try await queue.connect()
                    apply(.connected)
                } catch {
                    record("Connect failed: \(error.localizedDescription)")
                    apply(.connectFailed(error.localizedDescription))
                }
            }
        case .send(let c):
            Task {
                do {
                    try await queue.send(c)
                } catch {
                    record("Send failed: \(error.localizedDescription)")
                    apply(.sendFailed(error.localizedDescription))
                }
            }
        case .clearAndDisconnect:
            Task {
                await queue.clearAndDisconnect()
                apply(.stopCompleted)
                finishStop()
            }
        case .raiseAlert(let message):
            alertMessage = message
            record("ALERT: \(message)")
            Haptics.error()
            if UIApplication.shared.applicationState != .active {
                deadMan.alertNow(message)
            }
        case .dismissAlert:
            alertMessage = nil
            deadMan.clearAlert()
            record("Recovered")
        case .scheduleDeadMan(let after):
            deadMan.schedule(after: after, place: placeName)
        case .cancelDeadMan:
            deadMan.cancel()
        }
    }

    private func statusChanged(from old: SessionStatus) {
        if status.isVerified && !old.isVerified {
            record("Verified: iOS reports the chosen location")
            Haptics.success()
        }
        if case .reconnecting(_, let reason) = status, case .active = old {
            record("Reconnecting: \(reason)")
            Haptics.warning()
        }
    }

    private func finishStop() {
        loopTask?.cancel()
        loopTask = nil
        truth.stop()
        keepAlive.stop()
        liveActivity.end()
        mode = .idle
        player = nil
        joystick = nil
        route = nil
        routeSettings = nil
        position = nil
        speed = 0
        progress = 0
        remainingTime = nil
        arrived = false
        alertMessage = nil
        startedAt = nil
        placeName = nil
        SessionStore.clear()
        record("Stopped — real location restored")
        Haptics.success()
    }

    private func checkAutoStop() {
        let minutes = UserDefaults.standard.integer(forKey: SettingsKey.autoStopMinutes)
        guard minutes > 0, let startedAt, supervisor.wantsSpoofing,
              Date().timeIntervalSince(startedAt) > Double(minutes) * 60 else { return }
        record("Auto-stop after \(minutes) min")
        stop()
    }

    private func saveIntent(force: Bool) {
        let t = now()
        guard force || t - lastIntentSave > 5 else { return }
        lastIntentSave = t
        guard supervisor.wantsSpoofing, let c = position else { return }
        SessionStore.save(SessionIntent(active: true, coordinate: c, placeName: placeName, savedAt: Date()))
    }

    private func record(_ text: String) {
        log.append(LogEntry(text: text))
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }

    private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}

struct RouteSettings: Equatable {
    var mode: TravelMode = .drive
    var speedKmh: Double = 40
    var traffic: TrafficLevel = .light
    var repeatMode: RepeatMode = .once
}

enum SettingsKey {
    static let jitter = "jitter"
    static let keepAliveAudio = "keepAliveAudio"
    static let autoStopMinutes = "autoStopMinutes"
    static let units = "units"
}
