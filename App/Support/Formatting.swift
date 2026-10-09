import CoreLocation
import SpoofKit
import SwiftUI

extension Coordinate {
    init(_ c: CLLocationCoordinate2D) {
        self.init(latitude: c.latitude, longitude: c.longitude)
    }

    var cl: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Parses "19.07, 72.87", "19.07 72.87", or a Google/Apple Maps link
    /// containing "@19.07,72.87" or "q=19.07,72.87" / "ll=19.07,72.87".
    static func parse(_ text: String) -> Coordinate? {
        let pattern = #"(-?\d{1,2}(?:\.\d+)?)\s*[, ]\s*(-?\d{1,3}(?:\.\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            guard let r1 = Range(match.range(at: 1), in: text),
                  let r2 = Range(match.range(at: 2), in: text),
                  let lat = Double(text[r1]), let lon = Double(text[r2]) else { continue }
            let c = Coordinate(latitude: lat, longitude: lon)
            if c.isValid && !(lat == 0 && lon == 0) { return c }
        }
        return nil
    }
}

enum Units: String, CaseIterable, Identifiable {
    case metric, imperial
    var id: String { rawValue }
    var title: String { self == .metric ? "km/h" : "mph" }
}

enum Format {
    static func speed(_ metersPerSecond: Double, units: Units) -> String {
        switch units {
        case .metric: String(format: "%.0f km/h", metersPerSecond * 3.6)
        case .imperial: String(format: "%.0f mph", metersPerSecond * 2.23694)
        }
    }

    static func speedValue(kmh: Double, units: Units) -> String {
        units == .metric ? String(format: "%.0f km/h", kmh) : String(format: "%.0f mph", kmh / 1.609344)
    }

    static func distance(_ meters: Double, units: Units) -> String {
        switch units {
        case .metric:
            return meters < 1000 ? String(format: "%.0f m", meters) : String(format: "%.1f km", meters / 1000)
        case .imperial:
            let miles = meters / 1609.344
            return miles < 0.2 ? String(format: "%.0f ft", meters * 3.28084) : String(format: "%.1f mi", miles)
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        let m = s / 60
        if m < 60 { return "\(m) min" }
        return "\(m / 60) h \(m % 60) min"
    }

    static func eta(_ seconds: TimeInterval) -> String {
        Date().addingTimeInterval(seconds).formatted(date: .omitted, time: .shortened)
    }
}

enum Haptics {
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
}
