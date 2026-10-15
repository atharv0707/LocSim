//
//  LocationAccess.swift
//  LocSim
//
//  Asks for location permission so the map can show the iPhone's own
//  (simulated) location as the blue dot.
//

import CoreLocation

final class LocationAccess {
    private let manager = CLLocationManager()

    func requestIfNeeded() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }
}
