import Foundation
import SpoofKit

/// Something that can make iOS report a location system-wide.
///
/// * `SimulatorBridgeBackend` drives the iOS Simulator through tools/sim-bridge.py.
/// * `DVTBackend` (M3) drives a real iPhone through Apple's developer
///   location-simulation service, over LocalDevVPN.
protocol LocationBackend: Sendable {
    /// Human-readable name for diagnostics.
    var name: String { get }
    /// Problems that would stop a session from starting. Empty = ready.
    func preflight() async -> [PreflightItem]
    func connect() async throws
    func send(_ coordinate: Coordinate) async throws
    /// Return iOS to the real location.
    func clear() async throws
    func disconnect() async
}

struct PreflightItem: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable { case ok, warning, failed }

    let id: String
    let title: String
    let state: State
    let detail: String
    /// Optional URL the "Fix" button opens (Settings, App Store, docs).
    var fixURL: URL?
}

struct BackendError: LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Runs every device call strictly one after another, in the order requested.
/// Sends must never overtake a clear (that would re-spoof after Stop), and the
/// underlying C library is not thread-safe.
actor DeviceCommandQueue {
    private let backend: LocationBackend
    private var tail: Task<Void, Never> = Task {}
    /// True after a clear until the next connect: sends in between are dropped.
    private var closed = true

    init(backend: LocationBackend) { self.backend = backend }

    func connect() async throws {
        closed = false
        let backend = backend
        try await serial { try await backend.connect() }
    }

    func send(_ c: Coordinate) async throws {
        guard !closed else { return }
        let backend = backend
        try await serial { try await backend.send(c) }
    }

    func clearAndDisconnect() async {
        closed = true
        let backend = backend
        try? await serial {
            try? await backend.clear()
            await backend.disconnect()
        }
    }

    private func serial(_ op: @escaping @Sendable () async throws -> Void) async throws {
        let previous = tail
        let task = Task<Void, Error> {
            await previous.value
            try await op()
        }
        tail = Task { _ = try? await task.value }
        try await task.value
    }
}
