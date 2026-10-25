//
//  LocSimClient.swift
//  LocSim
//
//  Talks to LocSimServer/locsim_server.py on your Mac, which sets the
//  iPhone's GPS with pymobiledevice3.
//

import Foundation

struct LocSimClient {
    var address: String

    struct ServerStatus: Decodable {
        var active: Bool
        var message: String
        var name: String?
        var lat: Double?
        var lon: Double?
        /// False when the Mac can't currently see the iPhone (e.g. you've left home).
        var linked: Bool?
        /// The place waiting to be set once the iPhone is reachable again.
        var pending: String?
    }

    private var baseURL: URL? {
        var host = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasPrefix("http://") { host.removeFirst(7) }
        while host.hasSuffix("/") { host.removeLast() }
        if host.isEmpty { return nil }
        // Add the default port unless one is given ("[...]" = IPv6 literal).
        let hostPart = host.split(separator: "]").last.map(String.init) ?? host
        if !hostPart.contains(":") { host += ":8765" }
        return URL(string: "http://\(host)")
    }

    func status() async throws -> ServerStatus {
        let data = try await send(path: "/status", body: nil)
        return try JSONDecoder().decode(ServerStatus.self, from: data)
    }

    func simulate(_ place: Place) async throws -> String {
        let data = try await send(path: "/set", body: [
            "lat": place.latitude, "lon": place.longitude, "name": place.name,
        ])
        return message(data)
    }

    func stop() async throws -> String {
        let data = try await send(path: "/clear", body: [:])
        return message(data)
    }

    private func message(_ data: Data) -> String {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return json?["message"] as? String ?? String(decoding: data, as: UTF8.self)
    }

    private func send(path: String, body: [String: Any]?) async throws -> Data {
        guard let url = baseURL?.appending(path: path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 30)
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ServerError(message: message(data),
                              isWaiting: (response as? HTTPURLResponse)?.statusCode == 503)
        }
        return data
    }

    struct ServerError: LocalizedError {
        var message: String
        /// 503: LocSimServer accepted the change but the iPhone is out of reach, so it's queued.
        var isWaiting = false
        var errorDescription: String? { message }
    }
}
