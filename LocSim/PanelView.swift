//
//  PanelView.swift
//  LocSim
//
//  The Find My-style bottom sheet: status + Off/Start, search, the selected
//  place, favourites and recents.
//

import SwiftUI
import MapKit

struct PanelView: View {
    var model: LocSimModel
    @Binding var camera: MapCameraPosition
    @Binding var detent: PresentationDetent
    @Binding var showSettings: Bool

    @State private var search = LocationSearch()
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var renaming: Place?
    @State private var newName = ""

    private var places: PlaceStore { model.places }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)

            // At the smallest size only the status row shows; pull the sheet up for the rest.
            if detent != .collapsed {
                searchField
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .transition(.opacity)

                if query.isEmpty {
                    mainList
                } else {
                    suggestionList
                }
            } else {
                Spacer(minLength: 0)
            }
        }
        .animation(.default, value: detent)
        .onChange(of: query) { _, newValue in search.update(query: newValue) }
        .onChange(of: searchFocused) { _, focused in
            if focused { withAnimation { detent = .large } }
        }
        .sheet(isPresented: $showSettings, onDismiss: { Task { await model.refresh() } }) {
            SettingsSheet()
        }
        .alert("Rename favourite", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("Name", text: $newName)
            Button("Save") {
                if let renaming { places.renameFavourite(renaming, to: newName) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Header: status + Off / Start

    private var header: some View {
        let state = model.state
        return HStack(spacing: 12) {
            Image(systemName: state.icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(state.color)
                .frame(width: 42, height: 42)
                .background(state.color.opacity(0.15), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(state.title)
                    .font(.headline)
                Text(state.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            if model.isSending {
                ProgressView()
                    .frame(width: 70)
            } else if model.isSimulating {
                Button {
                    Task { await model.stop() }
                } label: {
                    Label("Off", systemImage: "location.slash.fill")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(.red)
                .accessibilityHint("Go back to the iPhone's real location")
            } else {
                Button {
                    if let last = places.last { Task { await simulate(last) } }
                } label: {
                    Label("Start", systemImage: "play.fill")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .disabled(places.last == nil || model.serverError != nil)
                .accessibilityHint(places.last.map { "Simulate \($0.name) again" } ?? "No previous location yet")
            }
        }
        .animation(.default, value: state.title)
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search a place or paste coordinates", text: $query)
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(.tertiarySystemFill), in: Capsule())

            if searchFocused {
                Button("Cancel") {
                    query = ""
                    searchFocused = false
                    withAnimation { detent = .medium }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.default, value: searchFocused)
    }

    private var suggestionList: some View {
        List {
            if let coordinate = Coordinates.parse(query) {
                Section("Coordinates") {
                    Button {
                        choose(Place(name: "Dropped pin", subtitle: "Pasted coordinates",
                                     latitude: coordinate.latitude, longitude: coordinate.longitude))
                    } label: {
                        Label {
                            Text(String(format: "Use %.6f, %.6f", coordinate.latitude, coordinate.longitude))
                                .foregroundStyle(.primary)
                        } icon: {
                            PlaceIcon(systemImage: "mappin", color: .red)
                        }
                    }
                }
            }
            if !search.suggestions.isEmpty {
                Section("Did you mean…") {
                    ForEach(search.suggestions, id: \.self) { suggestion in
                        Button {
                            Task { await pick(suggestion) }
                        } label: {
                            HStack(spacing: 12) {
                                PlaceIcon(systemImage: "mappin", color: .red)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(suggestion.title).foregroundStyle(.primary)
                                    if !suggestion.subtitle.isEmpty {
                                        Text(suggestion.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if let error = search.errorMessage {
                MessageLabel(text: error, kind: .error)
            }
        }
        .scrollContentBackground(.hidden)
        .overlay {
            if search.isSearching { ProgressView() }
        }
    }

    // MARK: Selected place, favourites, recents

    private var mainList: some View {
        List {
            if let actionError = model.actionError {
                Section {
                    MessageLabel(text: actionError, kind: model.actionIsWaiting ? .waiting : .error)
                }
            } else if model.isSimulating {
                Section {
                    Label("Simulation only works while the iPhone is on the Mac's Wi-Fi (or plugged in). "
                          + "Away from it, the iPhone uses its real GPS until it's back.",
                          systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let selected = model.selected {
                Section {
                    selectedCard(selected)
                }
            }

            Section {
                if places.favourites.isEmpty {
                    Label("Tap the star on a place to save it here.", systemImage: "star")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(places.favourites) { place in
                        placeButton(place, icon: "star.fill", color: .yellow)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    withAnimation { places.removeFavourite(place) }
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                                Button {
                                    newName = place.name
                                    renaming = place
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                            .contextMenu {
                                Button {
                                    Task { await simulate(place) }
                                } label: {
                                    Label("Simulate here", systemImage: "location.fill")
                                }
                                Button {
                                    newName = place.name
                                    renaming = place
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    withAnimation { places.removeFavourite(place) }
                                } label: {
                                    Label("Remove from Favourites", systemImage: "star.slash")
                                }
                            }
                    }
                }
            } header: {
                Text("Favourites")
            }

            if !places.recents.isEmpty {
                Section {
                    ForEach(places.recents) { place in
                        placeButton(place, icon: "clock.arrow.circlepath", color: .gray)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    withAnimation { places.removeRecent(place) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    withAnimation { places.toggleFavourite(place) }
                                } label: {
                                    Label(places.isFavourite(place) ? "Unfavourite" : "Favourite",
                                          systemImage: places.isFavourite(place) ? "star.slash" : "star.fill")
                                }
                                .tint(.yellow)
                            }
                            .contextMenu {
                                Button {
                                    Task { await simulate(place) }
                                } label: {
                                    Label("Simulate here", systemImage: "location.fill")
                                }
                                Button {
                                    withAnimation { places.toggleFavourite(place) }
                                } label: {
                                    Label(places.isFavourite(place) ? "Remove from Favourites" : "Add to Favourites",
                                          systemImage: places.isFavourite(place) ? "star.slash" : "star")
                                }
                                Button(role: .destructive) {
                                    withAnimation { places.removeRecent(place) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                } header: {
                    HStack {
                        Text("Recent")
                        Spacer()
                        Button("Clear") {
                            withAnimation { places.clearRecents() }
                        }
                        .font(.subheadline)
                        .textCase(nil)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func selectedCard(_ place: Place) -> some View {
        let favourite = places.isFavourite(place)
        let active = model.isActive(place)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                PlaceIcon(systemImage: "mappin", color: .red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name).font(.headline)
                    if !place.subtitle.isEmpty {
                        Text(place.subtitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text(place.coordinateText)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
                Button {
                    withAnimation { places.toggleFavourite(place) }
                } label: {
                    Image(systemName: favourite ? "star.fill" : "star")
                        .font(.title3)
                        .foregroundStyle(favourite ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(favourite ? "Remove from Favourites" : "Add to Favourites")
                Button {
                    withAnimation { model.selected = nil }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Clear selection")
            }

            Button {
                Task { await simulate(place) }
            } label: {
                Label(active ? "Simulating here" : "Simulate here",
                      systemImage: active ? "checkmark" : "location.fill")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isSending || active)
        }
        .padding(.vertical, 6)
    }

    private func placeButton(_ place: Place, icon: String, color: Color) -> some View {
        Button {
            choose(place)
        } label: {
            HStack(spacing: 12) {
                PlaceIcon(systemImage: icon, color: color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name)
                        .foregroundStyle(.primary)
                    Text(place.subtitle.isEmpty ? place.coordinateText : place.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if model.isActive(place) {
                    Text("Active")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.green.opacity(0.15), in: Capsule())
                }
            }
        }
    }

    // MARK: Actions

    private func pick(_ suggestion: MKLocalSearchCompletion) async {
        do {
            choose(try await search.resolve(suggestion))
        } catch {
            search.errorMessage = "Couldn't find coordinates for that place: \(error.localizedDescription)"
        }
    }

    private func choose(_ place: Place) {
        withAnimation {
            model.selected = place
            model.actionError = nil
            camera = .region(MKCoordinateRegion(center: place.coordinate,
                                                latitudinalMeters: 500, longitudinalMeters: 500))
            detent = .medium
        }
        query = ""
        searchFocused = false
    }

    private func simulate(_ place: Place) async {
        withAnimation {
            camera = .region(MKCoordinateRegion(center: place.coordinate,
                                                latitudinalMeters: 500, longitudinalMeters: 500))
        }
        if await model.simulate(place) {
            withAnimation { detent = .collapsed }
        }
    }
}

// MARK: - Small building blocks

/// Coloured round icon used for places (like Find My's list icons).
struct PlaceIcon: View {
    var systemImage: String
    var color: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(color.gradient, in: Circle())
    }
}

/// Status / error message: SF Symbol + colour, no emoji.
struct MessageLabel: View {
    enum Kind { case success, error, waiting }
    var text: String
    var kind: Kind

    var body: some View {
        Label(text, systemImage: icon)
            .font(.footnote)
            .foregroundStyle(color)
    }

    private var icon: String {
        switch kind {
        case .success: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        case .waiting: "clock.fill"
        }
    }

    private var color: Color {
        switch kind {
        case .success: .green
        case .error: .red
        case .waiting: .orange
        }
    }
}

// MARK: - Settings

struct SettingsSheet: View {
    @AppStorage("serverAddress") private var address = LocSimModel.defaultAddress
    @Environment(\.dismiss) private var dismiss
    @State private var result: (text: String, kind: MessageLabel.Kind)?
    @State private var testing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(LocSimModel.defaultAddress, text: $address)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            Label("Test connection", systemImage: "antenna.radiowaves.left.and.right")
                            Spacer()
                            if testing { ProgressView() }
                        }
                    }
                    .disabled(testing)
                    if let result {
                        MessageLabel(text: result.text, kind: result.kind)
                    }
                } header: {
                    Text("Mac running LocSimServer")
                } footer: {
                    Text("LocSimServer prints the addresses to use when it starts. On the same Wi-Fi, use the Mac's name ending in “.local”. On your iPhone's hotspot, use the 172.20.10.x address. Away from home, use the Mac's Tailscale 100.x.x.x address to see the status – changing the location still needs the iPhone on the Mac's Wi-Fi or a cable.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func test() async {
        testing = true
        defer { testing = false }
        do {
            let status = try await LocSimClient(address: address).status()
            result = ("Connected to LocSimServer. \(status.message)", .success)
        } catch {
            result = (error.localizedDescription, .error)
        }
    }
}
