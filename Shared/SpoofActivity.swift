import ActivityKit
import AppIntents
import Foundation

/// Shared by the app and the widget extension.
struct SpoofActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Health: String, Codable, Hashable { case verified, connecting, lost }

        var health: Health
        var title: String
        var detail: String
        var speedText: String?
        /// 0...1 along a route, nil when teleported.
        var progress: Double?
    }

    var startedAt: Date
}

extension Notification.Name {
    static let elsewhereStopRequested = Notification.Name("elsewhere.stopRequested")
}

/// The Stop button on the lock screen / Dynamic Island. Live Activity intents
/// run inside the app's process, so this reaches the running session.
struct StopSpoofingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop changing location"
    static let description = IntentDescription("Returns your iPhone to its real location.")

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(name: .elsewhereStopRequested, object: nil)
        }
        return .result()
    }
}
