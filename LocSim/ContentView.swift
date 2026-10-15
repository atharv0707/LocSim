//
//  ContentView.swift
//  LocSim
//
//  Full-screen map with floating glass controls on top and a Find My-style
//  sheet at the bottom (drag between small, half and full height).
//  The blue dot is the iPhone's own reported location, so you can watch it
//  move to the simulated place.
//

import SwiftUI
import MapKit

extension PresentationDetent {
    /// Just the status row (title, detail and the Start / Off button).
    static let collapsed = PresentationDetent.height(100)
}

struct ContentView: View {
    @State private var model = LocSimModel()
    @State private var locationAccess = LocationAccess()
    @State private var camera: MapCameraPosition = .userLocation(fallback: .region(
        MKCoordinateRegion(center: .init(latitude: 51.5072, longitude: -0.1276),
                           latitudinalMeters: 20_000, longitudinalMeters: 20_000)))
    @State private var detent: PresentationDetent = .medium
    @State private var showSettings = false

    @Environment(\.scenePhase) private var scenePhase
    @Namespace private var mapScope

    var body: some View {
        ZStack(alignment: .top) {
            map
                .ignoresSafeArea()
            topBar
        }
        .mapScope(mapScope)
        .sheet(isPresented: .constant(true)) {
            PanelView(model: model, camera: $camera, detent: $detent, showSettings: $showSettings)
                .presentationDetents([.collapsed, .medium, .large], selection: $detent)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled()
        }
        // Keep the status up to date while the app is open.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            locationAccess.requestIfNeeded()
            while !Task.isCancelled {
                if !model.isSending { await model.refresh() }
                try? await Task.sleep(for: .seconds(8))
            }
        }
    }

    // MARK: Map

    private var map: some View {
        MapReader { proxy in
            Map(position: $camera, scope: mapScope) {
                // The iPhone's own (possibly simulated) location.
                UserAnnotation()

                ForEach(model.places.favourites) { favourite in
                    if favourite.coordinateText != model.selected?.coordinateText,
                       favourite.coordinateText != model.simulatedPlace?.coordinateText {
                        Marker(favourite.name, systemImage: "star.fill", coordinate: favourite.coordinate)
                            .tint(.yellow)
                    }
                }

                if let simulated = model.simulatedPlace {
                    Marker(simulated.name, systemImage: "location.fill", coordinate: simulated.coordinate)
                        .tint(model.server?.active == true ? Color.green : Color.orange)
                }

                if let selected = model.selected,
                   selected.coordinateText != model.simulatedPlace?.coordinateText {
                    Marker(selected.name, coordinate: selected.coordinate)
                        .tint(.red)
                }
            }
            // Hide the built-in compass (it sits under the status bar); ours is in the top-right column.
            .mapControls {
                MapCompass(scope: mapScope)
                    .mapControlVisibility(.hidden)
            }
            .onTapGesture { point in
                // Tap the map to drop a pin on the exact spot.
                guard let coordinate = proxy.convert(point, from: .local) else { return }
                withAnimation {
                    model.selected = Place(name: "Dropped pin", subtitle: "Picked on the map",
                                           latitude: coordinate.latitude, longitude: coordinate.longitude)
                    model.actionError = nil
                    if detent == .collapsed { detent = .medium }
                }
            }
        }
    }

    // MARK: Floating top controls

    private var topBar: some View {
        let state = model.state
        return HStack(alignment: .top) {
            HStack(spacing: 10) {
                Image(systemName: "location.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.white, state.color)
                VStack(alignment: .leading, spacing: 0) {
                    Text("LocSim")
                        .font(.headline)
                    Text(state.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(state.color)
                        .contentTransition(.opacity)
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 16)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: Capsule())
            .contentShape(Capsule())
            .onTapGesture {}  // swallow taps so they don't drop a pin underneath
            .animation(.default, value: state.title)

            Spacer()

            VStack(spacing: 10) {
                CircleButton(systemImage: "gearshape.fill", label: "Settings") {
                    showSettings = true
                }
                CircleButton(systemImage: "location.fill", label: "Show my location") {
                    withAnimation { camera = .userLocation(fallback: .automatic) }
                }
                // Only appears when the map is rotated; tap to point north again.
                MapCompass(scope: mapScope)
                    .mapControlVisibility(.automatic)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }
}

/// A round floating glass button used over the map.
struct CircleButton: View {
    var systemImage: String
    var label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 46, height: 46)
                // Make the whole circle tappable, not just the icon, so taps never fall through to the map.
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel(label)
    }
}

#Preview {
    ContentView()
}
