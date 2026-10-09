import CoreLocation
import SwiftUI
import UserNotifications

/// First launch: what Elsewhere does, and the three things it needs.
struct OnboardingView: View {
    @Environment(SpoofController.self) private var controller
    let onDone: () -> Void

    @State private var notificationsOK = false
    @State private var connection: [PreflightItem] = []
    @State private var checkingConnection = false

    private var locationOK: Bool {
        controller.locationAuth == .authorizedAlways || controller.locationAuth == .authorizedWhenInUse
    }

    private var locationStep: (detail: String, action: StepAction?) {
        switch controller.locationAuth {
        case .authorizedAlways:
            return ("Always — Elsewhere keeps confirming your location while you use other apps.", nil)
        case .authorizedWhenInUse:
            return ("Now choose \"Always\" so checks keep running while you're in Maps or WhatsApp.",
                    StepAction(title: "Always", run: { controller.requestAlwaysLocation() }))
        case .denied, .restricted:
            return ("Turned off. Enable it in Settings → Elsewhere → Location.",
                    StepAction(title: "Settings", run: { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }))
        default:
            return ("So Elsewhere can confirm the change really worked — it reads back what other apps see.",
                    StepAction(title: "Allow", run: allowLocation))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "location.north.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(Color.accentColor.gradient)
                    Text("Be anywhere.")
                        .font(.largeTitle.weight(.bold))
                    Text("Elsewhere changes the location every app on this iPhone sees — Maps, WhatsApp, everything. Tap the map to teleport, or drive a route at your own speed with realistic traffic.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 40)

                VStack(spacing: 12) {
                    StepRow(done: controller.locationAuth == .authorizedAlways, icon: "location.fill", title: "Location",
                            detail: locationStep.detail, action: locationStep.action)
                    StepRow(done: notificationsOK, icon: "bell.badge.fill", title: "Notifications",
                            detail: "So you're warned within seconds if your real location ever becomes visible.",
                            action: notificationsOK ? nil : StepAction(title: "Allow", run: allowNotifications))
                    connectionStep
                    #if !targetEnvironment(simulator)
                    PairingImportButton { recheck() }
                        .padding(.horizontal, 16)
                    #endif
                }

                Text("Use it on your own device, for privacy and testing. Some apps forbid location spoofing in their terms.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button(action: onDone) {
                    Text(locationOK ? "Start" : "Continue anyway").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(24)
        }
        .task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            notificationsOK = settings.authorizationStatus == .authorized
            await checkConnection()
        }
    }

    private var connectionStep: some View {
        let failed = connection.first { $0.state == .failed }
        let ok = !connection.isEmpty && failed == nil
        let detail: String = failed?.detail ?? (ok ? (connection.first?.detail ?? "") : "Checking…")
        let action: StepAction? = ok || checkingConnection ? nil : StepAction(title: "Re-check", run: recheck)
        return StepRow(done: ok, icon: "cable.connector", title: "Connection", detail: detail, action: action)
    }

    private func allowLocation() { controller.requestLocationPermission() }
    private func allowNotifications() { Task { notificationsOK = await controller.requestNotificationPermission() } }
    private func recheck() { Task { await checkConnection() } }

    private func checkConnection() async {
        checkingConnection = true
        connection = await controller.preflight()
        checkingConnection = false
    }

}

struct StepAction {
    let title: String
    let run: () -> Void
}

private struct StepRow: View {
    let done: Bool
    let icon: String
    let title: String
    let detail: String
    let action: StepAction?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: done ? "checkmark.circle.fill" : icon)
                .font(.title2)
                .foregroundStyle(done ? Color.green : Color.accentColor)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let action {
                Button(action.title, action: action.run)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .animation(.snappy, value: done)
    }
}
