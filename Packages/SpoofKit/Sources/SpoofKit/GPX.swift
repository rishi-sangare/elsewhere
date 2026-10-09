import Foundation

/// Minimal GPX reader/writer. Reads track points, then route points, then
/// waypoints (first non-empty kind wins), which covers files exported by
/// Google Earth, Strava, gpx.studio, Xcode, etc.
public enum GPX {
    public enum ParseError: Error, Equatable {
        case invalidXML(String)
        case noPoints
    }

    public static func parse(_ data: Data) throws -> [Coordinate] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw ParseError.invalidXML(parser.parserError?.localizedDescription ?? "unknown error")
        }
        let points = [delegate.track, delegate.route, delegate.waypoints].first { !$0.isEmpty } ?? []
        guard !points.isEmpty else { throw ParseError.noPoints }
        return points
    }

    public static func export(_ points: [Coordinate], name: String) -> Data {
        var s = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Elsewhere" xmlns="http://www.topografix.com/GPX/1/1">
          <trk><name>\(escape(name))</name><trkseg>

        """
        for p in points {
            s += String(format: "    <trkpt lat=\"%.7f\" lon=\"%.7f\"/>\n", p.latitude, p.longitude)
        }
        s += "  </trkseg></trk>\n</gpx>\n"
        return Data(s.utf8)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var track: [Coordinate] = []
        var route: [Coordinate] = []
        var waypoints: [Coordinate] = []

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            let local = name.split(separator: ":").last.map(String.init) ?? name
            guard ["trkpt", "rtept", "wpt"].contains(local),
                  let lat = attributes["lat"].flatMap(Double.init),
                  let lon = attributes["lon"].flatMap(Double.init) else { return }
            let c = Coordinate(latitude: lat, longitude: lon)
            guard c.isValid else { return }
            switch local {
            case "trkpt": track.append(c)
            case "rtept": route.append(c)
            default: waypoints.append(c)
            }
        }
    }
}
