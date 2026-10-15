//
//  LocationSearch.swift
//  LocSim
//
//  Type-ahead place search (Apple Maps – no API key needed).
//

import Foundation
import MapKit
import Observation

@Observable
final class LocationSearch: NSObject, MKLocalSearchCompleterDelegate {
    var suggestions: [MKLocalSearchCompletion] = []
    var isSearching = false
    var errorMessage: String?

    @ObservationIgnored private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
        // Bias results towards the UK; anywhere in the world still works.
        completer.region = MKCoordinateRegion(
            center: .init(latitude: 52.5, longitude: -1.5),
            span: .init(latitudeDelta: 12, longitudeDelta: 12))
    }

    func update(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        errorMessage = nil
        if trimmed.count < 2 || Coordinates.parse(trimmed) != nil {
            suggestions = []
            completer.cancel()
            return
        }
        completer.queryFragment = trimmed
    }

    /// Looks up the exact coordinates for a suggestion the user tapped.
    func resolve(_ completion: MKLocalSearchCompletion) async throws -> Place {
        isSearching = true
        defer { isSearching = false }
        let response = try await MKLocalSearch(request: .init(completion: completion)).start()
        guard let item = response.mapItems.first else {
            throw URLError(.cannotFindHost)
        }
        let coordinate = item.placemark.coordinate
        return Place(
            name: item.name ?? completion.title,
            subtitle: completion.subtitle,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude)
    }

    // MARK: MKLocalSearchCompleterDelegate (called on the main thread)

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated {
            suggestions = Array(completer.results.prefix(12))
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        let message = error.localizedDescription
        MainActor.assumeIsolated {
            suggestions = []
            errorMessage = message
        }
    }
}
