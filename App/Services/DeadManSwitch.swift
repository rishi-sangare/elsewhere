import UserNotifications

/// A killed app can't warn anyone. So while spoofing, we keep a local
/// notification scheduled a few seconds in the future and push it back on every
/// heartbeat. If iOS kills the app, it stops being pushed back — and fires.
@MainActor
final class DeadManSwitch {
    private let center = UNUserNotificationCenter.current()
    private let deadManID = "elsewhere.deadman"
    private let alertID = "elsewhere.alert"

    func requestPermission() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func schedule(after seconds: TimeInterval, place: String?) {
        let content = UNMutableNotificationContent()
        content.title = "Elsewhere stopped"
        content.body = "Your real location may be visible to other apps. Open Elsewhere to resume"
            + (place.map { " at \($0)." } ?? ".")
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(seconds, 1), repeats: false)
        // Same identifier replaces the previous request: that's the "push back".
        center.add(UNNotificationRequest(identifier: deadManID, content: content, trigger: trigger))
    }

    func cancel() {
        center.removePendingNotificationRequests(withIdentifiers: [deadManID])
        center.removeDeliveredNotifications(withIdentifiers: [deadManID])
    }

    /// Immediate alert, used when the app is alive but backgrounded.
    func alertNow(_ message: String) {
        let content = UNMutableNotificationContent()
        content.title = "Real location may be visible"
        content.body = message
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        center.add(UNNotificationRequest(identifier: alertID, content: content, trigger: nil))
    }

    func clearAlert() {
        center.removeDeliveredNotifications(withIdentifiers: [alertID])
    }
}
