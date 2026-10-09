import CoreLocation
import SwiftUI
import UserNotifications

/// Setup wizard + diagnostics: a live checklist with a plain-language fix for
/// every item, and the session log.
struct SetupView: View {
    @Environment(SpoofController.self) private var controller
    @Environment(\.dismiss) private var dismiss
    @State private var items: [PreflightItem] = []
    @State private var checking = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if items.isEmpty && checking {
                        HStack { ProgressView(); Text("Checking…").foregroundStyle(.secondary) }
                    }
                    ForEach(items) { item in row(item) }
                } header: {
                    Text("Checklist")
                } footer: {
                    Text("Everything should be green before you start. Tap Fix for help with anything that isn't.")
                }

                #if !targetEnvironment(simulator)
                Section {
                    PairingImportButton { Task { await refresh() } }
                } header: {
                    Text("Pairing file")
                } footer: {
                    Text("Made once on a computer with iLoader. After every iOS update, make a new one.")
                }
                #endif

                Section("Status") {
                    LabeledContent("Session", value: StatusPill(status: controller.status).title)
                    if let readback = controller.lastReadback {
                        LabeledContent("iOS is reporting", value: readback.description)
                            .font(.footnote.monospacedDigit())
                    }
                    LabeledContent("Connection", value: controller.backendName)
                }

                Section("Log") {
                    if controller.log.isEmpty {
                        Text("Nothing yet").foregroundStyle(.secondary)
                    }
                    ForEach(controller.log.reversed()) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.text).font(.footnote)
                            Text(entry.date.formatted(date: .omitted, time: .standard))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Setup & diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { Task { await refresh() } } label: { Label("Re-check", systemImage: "arrow.clockwise") }
                        .disabled(checking)
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .task { await refresh() }
        }
    }

    private func row(_ item: PreflightItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon(item.state))
                .foregroundStyle(color(item.state))
                .font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.subheadline.weight(.semibold))
                Text(item.detail).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
            if item.state != .ok, let url = item.fixURL {
                Link("Fix", destination: url).font(.footnote.weight(.semibold))
            }
        }
        .padding(.vertical, 2)
    }

    private func refresh() async {
        checking = true
        var list = await controller.preflight()
        list.append(locationItem())
        list.append(await notificationItem())
        items = list
        checking = false
    }

    private func locationItem() -> PreflightItem {
        let status = CLAuthorizationStatus(rawValue: controller.locationAuthorization) ?? .notDetermined
        let settings = URL(string: UIApplication.openSettingsURLString)
        switch status {
        case .authorizedAlways:
            return .init(id: "location", title: "Location access", state: .ok,
                         detail: "Always — Elsewhere can verify your chosen location in the background.")
        case .authorizedWhenInUse:
            return .init(id: "location", title: "Location access", state: .warning,
                         detail: "While Using only. Choose 'Always' so verification keeps working when you switch apps.",
                         fixURL: settings)
        case .notDetermined:
            controller.requestLocationPermission()
            return .init(id: "location", title: "Location access", state: .warning,
                         detail: "Not asked yet. Elsewhere reads back your location to confirm the change really worked.")
        default:
            return .init(id: "location", title: "Location access", state: .failed,
                         detail: "Denied. Without it Elsewhere can't confirm the location change or warn you if it stops.",
                         fixURL: settings)
        }
    }

    private func notificationItem() async -> PreflightItem {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let ok = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        return .init(id: "notifications", title: "Notifications", state: ok ? .ok : .warning,
                     detail: ok ? "On — you'll be warned if your real location becomes visible."
                                : "Off. Turn on so you're warned if Elsewhere stops in the background.",
                     fixURL: ok ? nil : URL(string: UIApplication.openNotificationSettingsURLString))
    }

    private func icon(_ s: PreflightItem.State) -> String {
        switch s { case .ok: "checkmark.circle.fill"; case .warning: "exclamationmark.circle.fill"; case .failed: "xmark.circle.fill" }
    }

    private func color(_ s: PreflightItem.State) -> Color {
        switch s { case .ok: .green; case .warning: .orange; case .failed: .red }
    }
}
