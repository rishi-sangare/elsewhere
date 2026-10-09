import MapKit
import SpoofKit

/// A route ready to drive: the road geometry plus where the junctions are.
struct PlannedRoute: Equatable, Identifiable {
    let id = UUID()
    let path: RoutePath
    /// Distances along the route of turn instructions (candidate traffic stops).
    let junctions: [Double]
    let source: Coordinate
    let destination: Coordinate
    let destinationName: String?
    /// True when directions were unavailable and we drew a straight line.
    let isStraightLine: Bool

    var distance: Double { path.length }

    func named(_ name: String?) -> PlannedRoute {
        guard let name, name != destinationName else { return self }
        return PlannedRoute(path: path, junctions: junctions, source: source, destination: destination,
                            destinationName: name, isStraightLine: isStraightLine)
    }

    static func == (a: PlannedRoute, b: PlannedRoute) -> Bool { a.id == b.id }
}

enum RoutePlanner {
    /// Road route from Apple Maps (free, on-device, no API key). Falls back to a
    /// straight line when directions aren't available (offline, ocean, etc.).
    static func plan(from: Coordinate, to: Coordinate, mode: TravelMode, destinationName: String?) async -> PlannedRoute? {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from.cl))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to.cl))
        request.transportType = mode == .walk || mode == .cycle ? .walking : .automobile
        request.requestsAlternateRoutes = false

        if let response = try? await MKDirections(request: request).calculate(),
           let route = response.routes.first {
            let coords = route.polyline.coordinates.map(Coordinate.init)
            if let path = RoutePath(coordinates: [from] + coords + [to]) {
                var junctions: [Double] = []
                var s = Geo.distance(from, coords.first ?? from)
                for step in route.steps.dropLast() {
                    s += step.distance
                    if s > 20 && s < path.length - 20 { junctions.append(s) }
                }
                return PlannedRoute(path: path, junctions: junctions, source: from, destination: to,
                                    destinationName: destinationName, isStraightLine: false)
            }
        }
        return straightLine(from: from, to: to, destinationName: destinationName)
    }

    static func straightLine(from: Coordinate, to: Coordinate, destinationName: String?) -> PlannedRoute? {
        guard let path = RoutePath(coordinates: [from, to]) else { return nil }
        return PlannedRoute(path: path, junctions: [], source: from, destination: to,
                            destinationName: destinationName, isStraightLine: true)
    }

    static func fromGPX(_ points: [Coordinate], name: String) -> PlannedRoute? {
        guard let path = RoutePath(coordinates: points) else { return nil }
        return PlannedRoute(path: path, junctions: [], source: path.start, destination: path.end,
                            destinationName: name, isStraightLine: false)
    }
}

extension MKPolyline {
    var coordinates: [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
        return coords
    }
}
