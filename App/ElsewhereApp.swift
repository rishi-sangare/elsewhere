import SwiftData
import SwiftUI

@main
struct ElsewhereApp: App {
    @State private var controller = SpoofController(backend: Backends.make())

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(controller)
        }
        .modelContainer(for: [Place.self, SavedRoute.self])
    }
}

enum Backends {
    static func make() -> LocationBackend {
        #if targetEnvironment(simulator)
        return SimulatorBridgeBackend()
        #else
        return DeviceBackendFactory.make()
        #endif
    }
}
