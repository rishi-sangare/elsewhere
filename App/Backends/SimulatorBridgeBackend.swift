import Foundation
import SpoofKit

/// Development stand-in for a real iPhone: posts fixes to tools/sim-bridge.py,
/// which runs `xcrun simctl location`. The Simulator's own location then
/// changes for every app inside it, just like the real thing.
struct SimulatorBridgeBackend: LocationBackend {
    let name = "iOS Simulator bridge"
    private let base = URL(string: "http://127.0.0.1:47800")!
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 3
        return URLSession(configuration: config)
    }()

    func preflight() async -> [PreflightItem] {
        let running = (try? await health()) == true
        return [PreflightItem(
            id: "bridge",
            title: "Simulator bridge",
            state: running ? .ok : .failed,
            detail: running
                ? "Running on your Mac — the Simulator's location can be changed."
                : "Not running. In Terminal, from the project folder, run: python3 tools/sim-bridge.py"
        )]
    }

    func connect() async throws {
        guard (try? await health()) == true else {
            throw BackendError("Simulator bridge isn't running. Start it with: python3 tools/sim-bridge.py")
        }
    }

    func send(_ c: Coordinate) async throws {
        try await post("set", query: [
            URLQueryItem(name: "lat", value: String(format: "%.7f", c.latitude)),
            URLQueryItem(name: "lon", value: String(format: "%.7f", c.longitude)),
        ])
    }

    func clear() async throws { try await post("clear") }
    func disconnect() async {}

    private func health() async throws -> Bool {
        let (_, response) = try await session.data(from: base.appending(path: "health"))
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    private func post(_ path: String, query: [URLQueryItem] = []) async throws {
        var url = base.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                let msg = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
                throw BackendError(msg ?? "Bridge rejected the request")
            }
        } catch let e as BackendError {
            throw e
        } catch {
            throw BackendError("Lost connection to the simulator bridge")
        }
    }
}

/// Used on a real device until the DVT backend is available in the build.
struct UnavailableBackend: LocationBackend {
    let name = "Unavailable"
    let reason: String

    func preflight() async -> [PreflightItem] {
        [PreflightItem(id: "backend", title: "Device connection", state: .failed, detail: reason)]
    }
    func connect() async throws { throw BackendError(reason) }
    func send(_ coordinate: Coordinate) async throws { throw BackendError(reason) }
    func clear() async throws {}
    func disconnect() async {}
}
