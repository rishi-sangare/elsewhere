import Foundation

/// Picks the real-iPhone backend. The DVT backend (M3) is compiled in only when
/// the idevice XCFramework is present (see scripts/fetch-idevice.sh).
enum DeviceBackendFactory {
    static func make() -> LocationBackend {
        #if canImport(IDevice)
        return DVTBackend()
        #else
        return UnavailableBackend(reason: "This build doesn't include the device connection library. Download the release build from GitHub.")
        #endif
    }
}
