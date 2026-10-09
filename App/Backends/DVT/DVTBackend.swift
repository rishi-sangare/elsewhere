#if canImport(IDevice)
import Darwin
import Foundation
import IDevice
import Network
import SpoofKit

/// Real iPhone: talks to the phone's own developer services, the same ones
/// Xcode uses, over LocalDevVPN's loopback network.
///
///   pairing file → RemotePairing tunnel (10.7.0.1:49152) → RSD handshake
///   → mount personalized Developer Disk Image (once per boot)
///   → DVT remote server → LocationSimulation.set(lat, lon)
///
/// Written against idevice's C API (MIT). All calls block, so they run on one
/// private serial queue; the library is not thread-safe.
final class DVTBackend: LocationBackend, @unchecked Sendable {
    let name = "iPhone developer service"

    static let deviceAddress = "10.7.0.1"
    static let remotePairingPort: UInt16 = 49152
    static let localDevVPN = URL(string: "https://apps.apple.com/app/id6755608044")!
    static let pairingGuide = URL(string: "https://github.com/StikDebug/StikDebug-Guide/blob/main/pairing_file.md")!

    private let queue = DispatchQueue(label: "elsewhere.dvt", qos: .userInitiated)
    // Owned exclusively by `queue`.
    private var adapter: OpaquePointer?
    private var handshake: OpaquePointer?
    private var simulation: OpaquePointer?

    // MARK: LocationBackend

    func preflight() async -> [PreflightItem] {
        var items: [PreflightItem] = []
        if PairingStore.exists {
            items.append(.init(id: "pairing", title: "Pairing file", state: .ok, detail: "Imported."))
        } else {
            items.append(.init(id: "pairing", title: "Pairing file", state: .failed,
                               detail: "Not imported yet. Make one on a computer with iLoader (one time, ~10 min), then import it here.",
                               fixURL: Self.pairingGuide))
        }
        let vpnUp = await Self.probe(host: Self.deviceAddress, port: Self.remotePairingPort)
        items.append(vpnUp
            ? .init(id: "vpn", title: "LocalDevVPN", state: .ok, detail: "Connected — Elsewhere can reach this iPhone's developer service.")
            : .init(id: "vpn", title: "LocalDevVPN", state: .failed,
                    detail: "Not connected. Open LocalDevVPN and tap Connect. Keep Wi-Fi turned on.",
                    fixURL: Self.localDevVPN))
        items.append(DDIManager.isCached
            ? .init(id: "ddi", title: "Apple developer files", state: .ok, detail: "Downloaded and verified.")
            : .init(id: "ddi", title: "Apple developer files", state: .warning,
                    detail: "Will download once (~16 MB) when you first start. Needs internet."))
        return items
    }

    func connect() async throws {
        guard PairingStore.exists else { throw BackendError("Import your pairing file first (Setup → Pairing file).") }
        try await DDIManager.ensureDownloaded()
        try await run { try self.openSession() }
    }

    func send(_ c: Coordinate) async throws {
        try await run {
            guard let simulation = self.simulation else { throw BackendError("Not connected") }
            if let err = location_simulation_set(simulation, c.latitude, c.longitude) {
                let e = Self.error(err, "Location update was rejected")
                self.closeSession()
                throw e
            }
        }
    }

    func clear() async throws {
        try await run {
            guard let simulation = self.simulation else { return }
            if let err = location_simulation_clear(simulation) { throw Self.error(err, "Couldn't clear") }
        }
    }

    func disconnect() async {
        try? await run { self.closeSession() }
    }

    // MARK: Session (queue only)

    private func openSession() throws {
        closeSession()
        try createTunnel()
        if try mountedImageCount() == 0 {
            try mountDeveloperImage()
        }
        var server: OpaquePointer?
        if let err = remote_server_connect_rsd(adapter, handshake, &server) {
            closeSession()
            throw Self.error(err, "Couldn't open the developer service. Is Developer Mode on?")
        }
        var sim: OpaquePointer?
        if let err = location_simulation_new(server, &sim) {
            remote_server_free(server)
            closeSession()
            throw Self.error(err, "Location simulation isn't available on this iOS version yet.")
        }
        // Ownership of `server` moved into `sim`.
        simulation = sim
    }

    private func closeSession() {
        if let simulation { location_simulation_free(simulation) }
        if let handshake { rsd_handshake_free(handshake) }
        if let adapter { adapter_free(adapter) }
        simulation = nil
        handshake = nil
        adapter = nil
    }

    private func createTunnel() throws {
        var pairing: OpaquePointer?
        if let err = PairingStore.url.path.withCString({ rp_pairing_file_read($0, &pairing) }) {
            throw Self.error(err, "Couldn't read the pairing file. Import it again.")
        }
        defer { rp_pairing_file_free(pairing) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = Self.remotePairingPort.bigEndian
        inet_pton(AF_INET, Self.deviceAddress, &addr.sin_addr)

        let err = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                tunnel_create_rppairing($0, socklen_t(MemoryLayout<sockaddr_in>.size), "Elsewhere",
                                        pairing, nil, nil, &adapter, &handshake)
            }
        }
        if let err {
            closeSession()
            throw Self.error(err, "Couldn't reach this iPhone's developer service. Is LocalDevVPN connected? If iOS was updated, make a new pairing file.")
        }
    }

    private func mountedImageCount() throws -> Int {
        var mounter: OpaquePointer?
        if let err = image_mounter_connect_rsd(adapter, handshake, &mounter) {
            throw Self.error(err, "Couldn't check developer files")
        }
        defer { image_mounter_free(mounter) }
        var devices: UnsafeMutablePointer<plist_t?>?
        var count = 0
        if let err = image_mounter_copy_devices(mounter, &devices, &count) {
            throw Self.error(err, "Couldn't check developer files")
        }
        if let devices {
            for i in 0..<count { if let p = devices[i] { plist_free(p) } }
            idevice_data_free(UnsafeMutableRawPointer(devices).assumingMemoryBound(to: UInt8.self),
                              UInt(count * MemoryLayout<plist_t?>.stride))
        }
        return count
    }

    private func mountDeveloperImage() throws {
        let image = try Data(contentsOf: DDIManager.file("Image.dmg"), options: .mappedIfSafe)
        let trustCache = try Data(contentsOf: DDIManager.file("Image.dmg.trustcache"))
        let manifest = try Data(contentsOf: DDIManager.file("BuildManifest.plist"))
        let chipID = try uniqueChipID()

        var mounter: OpaquePointer?
        if let err = image_mounter_connect_rsd(adapter, handshake, &mounter) {
            throw Self.error(err, "Couldn't start mounting developer files")
        }
        defer { image_mounter_free(mounter) }
        let err = image.withUnsafeBytes { img in
            trustCache.withUnsafeBytes { tc in
                manifest.withUnsafeBytes { mf in
                    image_mounter_mount_personalized_with_callback_rsd(
                        mounter, adapter, handshake,
                        img.bindMemory(to: UInt8.self).baseAddress, image.count,
                        tc.bindMemory(to: UInt8.self).baseAddress, trustCache.count,
                        mf.bindMemory(to: UInt8.self).baseAddress, manifest.count,
                        nil, chipID, { _, _, _ in }, nil)
                }
            }
        }
        if let err {
            throw Self.error(err, "Couldn't mount Apple's developer files. Check Developer Mode is on and you have internet.")
        }
    }

    private func uniqueChipID() throws -> UInt64 {
        var lockdown: OpaquePointer?
        if let err = lockdownd_connect_rsd(adapter, handshake, &lockdown) {
            throw Self.error(err, "Couldn't read device info")
        }
        defer { lockdownd_client_free(lockdown) }
        var value: plist_t?
        if let err = lockdownd_get_value(lockdown, "UniqueChipID", nil, &value) {
            throw Self.error(err, "Couldn't read device info")
        }
        defer { if let value { plist_free(value) } }
        var id: UInt64 = 0
        if let value { plist_get_uint_val(value, &id) }
        guard id != 0 else { throw BackendError("Couldn't read device info") }
        return id
    }

    // MARK: Helpers

    private func run(_ work: @escaping () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                do { try work(); cont.resume() } catch { cont.resume(throwing: error) }
            }
        }
    }

    private static func error(_ ptr: UnsafeMutablePointer<IdeviceFfiError>, _ fallback: String) -> BackendError {
        let detail = ptr.pointee.message.map { String(cString: $0) }
        idevice_error_free(ptr)
        // Plain-language message first; library detail kept for diagnostics.
        return BackendError(detail.map { "\(fallback) (\($0))" } ?? fallback)
    }

    /// TCP reachability check with a short timeout (is LocalDevVPN up?).
    static func probe(host: String, port: UInt16, timeout: TimeInterval = 2) async -> Bool {
        await withCheckedContinuation { cont in
            let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let once = ResumeOnce(cont, connection: conn)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: once.finish(true)
                case .failed, .cancelled: once.finish(false)
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.finish(false) }
        }
    }
}

/// Resumes a continuation exactly once, from whichever callback wins.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<Bool, Never>?
    private let connection: NWConnection

    init(_ cont: CheckedContinuation<Bool, Never>, connection: NWConnection) {
        self.cont = cont
        self.connection = connection
    }

    func finish(_ ok: Bool) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        guard let c else { return }
        connection.cancel()
        c.resume(returning: ok)
    }
}
#endif
