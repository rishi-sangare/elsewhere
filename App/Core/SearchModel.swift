import MapKit
import Observation
import SpoofKit

/// Place search with live suggestions. Also accepts pasted coordinates or a
/// Google/Apple Maps link.
@MainActor
@Observable
final class SearchModel: NSObject, MKLocalSearchCompleterDelegate {
    var query = "" {
        didSet { update() }
    }
    private(set) var suggestions: [MKLocalSearchCompletion] = []
    private(set) var pastedCoordinate: Coordinate?

    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func bias(to region: MKCoordinateRegion) {
        completer.region = region
    }

    func resolve(_ completion: MKLocalSearchCompletion) async -> (Coordinate, String)? {
        let request = MKLocalSearch.Request(completion: completion)
        guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else { return nil }
        let c = Coordinate(item.placemark.coordinate)
        return (c, item.name ?? completion.title)
    }

    func clear() {
        query = ""
        suggestions = []
        pastedCoordinate = nil
    }

    private func update() {
        pastedCoordinate = Coordinate.parse(query)
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.count >= 2 && pastedCoordinate == nil {
            completer.queryFragment = q
        } else {
            suggestions = []
        }
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = Array(completer.results.prefix(8))
        Task { @MainActor in self.suggestions = results }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {}
}

enum Geocoder {
    /// Short human name for a coordinate ("Gateway of India", "Colaba, Mumbai").
    static func name(for c: Coordinate) async -> String? {
        let location = CLLocation(latitude: c.latitude, longitude: c.longitude)
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }
        if let poi = placemark.areasOfInterest?.first { return poi }
        let parts = [placemark.name, placemark.locality].compactMap { $0 }
        var unique: [String] = []
        for p in parts where !unique.contains(p) { unique.append(p) }
        return unique.isEmpty ? nil : unique.joined(separator: ", ")
    }
}
