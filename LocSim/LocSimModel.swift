//
//  LocSimModel.swift
//  LocSim
//
//  App state shared by the map and the bottom sheet: what LocSimServer is
//  doing, the selected place, and saved places (recents + favourites).
//

import SwiftUI

/// What the status row and top bar show.
struct ConnectionState {
    var title: String
    var detail: String
    var icon: String
    var color: Color
}

@Observable
final class LocSimModel {
    static let defaultAddress = "Atharvs-MacBook-Air.local:8765"

    var server: LocSimClient.ServerStatus?
    var serverError: String?
    var actionError: String?
    var isSending = false
    var selected: Place?
    let places = PlaceStore()

    var address: String {
        UserDefaults.standard.string(forKey: "serverAddress") ?? Self.defaultAddress
    }

    private var client: LocSimClient { LocSimClient(address: address) }

    // MARK: Derived state

    /// True while LocSimServer is holding (or trying to hold) a simulated location.
    var isSimulating: Bool {
        guard let server else { return false }
        return server.active || server.name != nil
    }

    var simulatedPlace: Place? {
        guard let server, isSimulating, let lat = server.lat, let lon = server.lon else { return nil }
        return Place(name: server.name ?? "Simulated", subtitle: "", latitude: lat, longitude: lon)
    }

    func isActive(_ place: Place) -> Bool {
        server?.active == true && simulatedPlace?.coordinateText == place.coordinateText
    }

    var state: ConnectionState {
        if let serverError {
            return .init(title: "Mac not reachable", detail: serverError,
                         icon: "wifi.exclamationmark", color: .red)
        }
        guard let server else {
            return .init(title: "Checking…", detail: "Contacting LocSimServer",
                         icon: "ellipsis", color: .secondary)
        }
        if server.active, let place = simulatedPlace {
            return .init(title: "Simulating", detail: place.name,
                         icon: "location.fill", color: .green)
        }
        if let name = server.name {
            return .init(title: "Connecting to iPhone…", detail: "Setting \(name)",
                         icon: "arrow.triangle.2.circlepath", color: .orange)
        }
        if let last = places.last {
            return .init(title: "Real location", detail: "Start resumes \(last.name)",
                         icon: "location", color: .blue)
        }
        return .init(title: "Real location", detail: "Pick a place to start simulating",
                     icon: "location", color: .blue)
    }

    // MARK: Actions

    /// Turns simulation on at `place`. Returns true if LocSimServer applied it.
    @discardableResult
    func simulate(_ place: Place) async -> Bool {
        isSending = true
        actionError = nil
        var ok = false
        do {
            _ = try await client.simulate(place)
            places.record(place)
            ok = true
        } catch {
            actionError = friendly(error)
        }
        await refresh()
        isSending = false
        return ok
    }

    /// Turns simulation off (back to the real GPS).
    func stop() async {
        isSending = true
        actionError = nil
        do {
            _ = try await client.stop()
        } catch {
            actionError = friendly(error)
        }
        await refresh()
        isSending = false
    }

    func refresh() async {
        do {
            let status = try await client.status()
            withAnimation {
                server = status
                serverError = nil
            }
        } catch {
            withAnimation { serverError = friendly(error) }
        }
    }

    private func friendly(_ error: Error) -> String {
        if let urlError = error as? URLError,
           [.cannotFindHost, .cannotConnectToHost, .timedOut, .networkConnectionLost,
            .notConnectedToInternet, .dnsLookupFailed, .badURL].contains(urlError.code) {
            return "Can't reach LocSimServer at \(address). Check it's running and the address in Settings."
        }
        return error.localizedDescription
    }
}

// MARK: - Saved places

@Observable
final class PlaceStore {
    private(set) var recents: [Place] = []
    private(set) var favourites: [Place] = []
    /// The last place that was simulated – what "Start" resumes.
    private(set) var last: Place?

    init() {
        let savedRecents: [Place]? = Self.load("recentPlaces")
        let savedFavourites: [Place]? = Self.load("favouritePlaces")
        let savedLast: Place? = Self.load("lastPlace")
        recents = savedRecents ?? []
        favourites = savedFavourites ?? []
        last = savedLast ?? recents.first
    }

    func record(_ place: Place) {
        recents.removeAll { $0.coordinateText == place.coordinateText }
        recents.insert(place, at: 0)
        recents = Array(recents.prefix(12))
        last = place
        save()
    }

    func removeRecent(_ place: Place) {
        recents.removeAll { $0.id == place.id }
        save()
    }

    func clearRecents() {
        recents = []
        save()
    }

    func isFavourite(_ place: Place) -> Bool {
        favourites.contains { $0.coordinateText == place.coordinateText }
    }

    func toggleFavourite(_ place: Place) {
        if isFavourite(place) {
            favourites.removeAll { $0.coordinateText == place.coordinateText }
        } else {
            favourites.insert(place, at: 0)
        }
        save()
    }

    func removeFavourite(_ place: Place) {
        favourites.removeAll { $0.id == place.id }
        save()
    }

    func renameFavourite(_ place: Place, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = favourites.firstIndex(where: { $0.id == place.id }) else { return }
        favourites[index].name = trimmed
        save()
    }

    func moveFavourites(from source: IndexSet, to destination: Int) {
        favourites.move(fromOffsets: source, toOffset: destination)
        save()
    }

    // MARK: Persistence (UserDefaults, JSON)

    private func save() {
        let encoder = JSONEncoder()
        let defaults = UserDefaults.standard
        defaults.set(try? encoder.encode(recents), forKey: "recentPlaces")
        defaults.set(try? encoder.encode(favourites), forKey: "favouritePlaces")
        if let last {
            defaults.set(try? encoder.encode(last), forKey: "lastPlace")
        }
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
