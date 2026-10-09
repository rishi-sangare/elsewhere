import CoreLocation
import SpoofKit

/// Reads back the location iOS is reporting. Because the spoof is system-wide,
/// what this sees is exactly what WhatsApp or Google Maps see — so it's how we
/// verify the spoof is really active instead of trusting "the call succeeded".
///
/// Running background location updates also keeps the app alive while the user
/// is in other apps.
@MainActor
final class TruthMonitor: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var onLocation: ((Coordinate) -> Void)?
    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)?
    private(set) var isRunning = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .otherNavigation
    }

    var authorization: CLAuthorizationStatus { manager.authorizationStatus }

    func requestPermission() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    /// Asked from onboarding/setup only. Never mid-session: while iOS shows its
    /// permission prompt it pauses location updates, which looks exactly like
    /// a lost spoof and raises a (false) alarm.
    func requestAlways() {
        if manager.authorizationStatus == .authorizedWhenInUse { manager.requestAlwaysAuthorization() }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        requestPermission()
        // Start straight away: right after launch iOS may not have reported the
        // permission yet, and waiting for it delays verification by seconds.
        if manager.authorizationStatus != .denied && manager.authorizationStatus != .restricted {
            enableBackgroundIfPossible()
            manager.startUpdatingLocation()
        }
    }

    func stop() {
        isRunning = false
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
    }

    private func enableBackgroundIfPossible() {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        if modes.contains("location") {
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        let c = Coordinate(latitude: last.coordinate.latitude, longitude: last.coordinate.longitude)
        Task { @MainActor in self.onLocation?(c) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // No fix (e.g. simulator location cleared) — the supervisor treats silence
        // as "not verified", which is the safe interpretation.
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.onAuthorizationChange?(status)
            if self.isRunning, status == .authorizedAlways || status == .authorizedWhenInUse {
                self.enableBackgroundIfPossible()
                self.manager.startUpdatingLocation()
            }
        }
    }
}
