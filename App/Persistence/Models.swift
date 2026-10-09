import Foundation
import SpoofKit
import SwiftData

@Model
final class Place {
    var name: String
    var latitude: Double
    var longitude: Double
    var isFavorite: Bool
    var lastUsed: Date

    init(name: String, coordinate: Coordinate, isFavorite: Bool = false) {
        self.name = name
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
        self.isFavorite = isFavorite
        self.lastUsed = .now
    }

    var coordinate: Coordinate { Coordinate(latitude: latitude, longitude: longitude) }
}

@Model
final class SavedRoute {
    var name: String
    var pointsData: Data
    var junctions: [Double]
    var modeRaw: String
    var speedKmh: Double
    var trafficRaw: String
    var createdAt: Date

    init(name: String, route: PlannedRoute, settings: RouteSettings) {
        self.name = name
        self.pointsData = (try? JSONEncoder().encode(route.path.points.enumerated()
            .filter { $0.offset % 5 == 0 || $0.offset == route.path.points.count - 1 }.map(\.element))) ?? Data()
        self.junctions = route.junctions
        self.modeRaw = settings.mode.rawValue
        self.speedKmh = settings.speedKmh
        self.trafficRaw = settings.traffic.rawValue
        self.createdAt = .now
    }

    var points: [Coordinate] { (try? JSONDecoder().decode([Coordinate].self, from: pointsData)) ?? [] }

    var settings: RouteSettings {
        RouteSettings(mode: TravelMode(rawValue: modeRaw) ?? .drive, speedKmh: speedKmh,
                      traffic: TrafficLevel(rawValue: trafficRaw) ?? .none, repeatMode: .once)
    }

    var plannedRoute: PlannedRoute? {
        guard let path = RoutePath(coordinates: points) else { return nil }
        return PlannedRoute(path: path, junctions: junctions, source: path.start, destination: path.end,
                            destinationName: name, isStraightLine: false)
    }
}

/// Written to disk while spoofing so a relaunch after a crash or kill can tell
/// the user what happened and offer to resume.
struct SessionIntent: Codable, Equatable {
    var active: Bool
    var coordinate: Coordinate
    var placeName: String?
    var savedAt: Date
}

enum SessionStore {
    private static let key = "sessionIntent"

    static func save(_ intent: SessionIntent) {
        UserDefaults.standard.set(try? JSONEncoder().encode(intent), forKey: key)
    }

    static func load() -> SessionIntent? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(SessionIntent.self, from: $0) }
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}
