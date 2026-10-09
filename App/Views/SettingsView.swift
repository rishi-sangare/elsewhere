import SwiftUI

struct SettingsView: View {
    @Environment(SpoofController.self) private var controller
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.units) private var unitsRaw = Units.metric.rawValue
    @AppStorage(SettingsKey.jitter) private var jitter = true
    @AppStorage(SettingsKey.keepAliveAudio) private var keepAliveAudio = true
    @AppStorage(SettingsKey.autoStopMinutes) private var autoStop = 0
    let openSetup: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { openSetup() }
                    } label: {
                        Label("Setup & diagnostics", systemImage: "stethoscope")
                    }
                } footer: {
                    Text("Connection: \(controller.backendName)")
                }

                Section("Movement") {
                    Picker("Units", selection: $unitsRaw) {
                        ForEach(Units.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Toggle("Realistic GPS wobble", isOn: $jitter)
                }

                Section {
                    Toggle("Keep running in background", isOn: $keepAliveAudio)
                    Picker("Auto-stop after", selection: $autoStop) {
                        Text("Never").tag(0)
                        Text("15 min").tag(15)
                        Text("30 min").tag(30)
                        Text("1 hour").tag(60)
                        Text("2 hours").tag(120)
                        Text("8 hours").tag(480)
                    }
                } header: {
                    Text("Safety")
                } footer: {
                    Text("Background mode plays silence (mixed with your music) so iOS doesn't pause Elsewhere while you use other apps. If Elsewhere is stopped anyway, you'll get a notification within seconds.")
                }

                Section {
                    Text("Elsewhere is for privacy, testing and development on your own device. Some apps forbid location spoofing in their terms — location-based games may ban accounts. Don't use it to deceive people in ways that harm them.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Link("Source code & guide", destination: URL(string: "https://github.com/rishi-sangare/elsewhere")!)
                } header: {
                    Text("About")
                } footer: {
                    Text("Elsewhere \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · MIT licence")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}
