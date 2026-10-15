//
//  Place.swift
//  LocSim
//
//  A chosen location, plus helpers for reading coordinates pasted from Google Maps.
//

import Foundation
import CoreLocation

struct Place: Codable, Hashable, Identifiable {
    var name: String
    var subtitle: String
    var latitude: Double
    var longitude: Double

    var id: String { "\(latitude),\(longitude),\(name)" }
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    var coordinateText: String { String(format: "%.6f, %.6f", latitude, longitude) }
}

enum Coordinates {
    /// Accepts "51.4897, -0.1461", "51.4897 -0.1461" or a Google Maps link containing "@51.4897,-0.1461".
    static func parse(_ text: String) -> CLLocationCoordinate2D? {
        let pattern = #"(-?\d{1,3}(?:\.\d+)?)\s*[, ]\s*(-?\d{1,3}(?:\.\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            guard let latRange = Range(match.range(at: 1), in: text),
                  let lonRange = Range(match.range(at: 2), in: text),
                  let lat = Double(text[latRange]),
                  let lon = Double(text[lonRange]),
                  (-90...90).contains(lat), (-180...180).contains(lon),
                  // ignore plain integers like "1 Sutherland" – real coordinates have decimals
                  text[latRange].contains(".") || text[lonRange].contains(".")
            else { continue }
            return .init(latitude: lat, longitude: lon)
        }
        return nil
    }
}
