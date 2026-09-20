import CommuteCore
import GTFSKit
import MapKit
import SwiftData
import SwiftUI

struct PlacePickerView: View {
    let title: String
    var allowsCurrentLocation = true
    let location: LocationService
    let onPick: (Waypoint) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(TransitDataStore.self) private var transitData
    @Query(sort: \SavedPlace.createdAt) private var places: [SavedPlace]

    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var stops: [TransitStop] = []
    @State private var nearbyStops: [TransitStop] = []
    @State private var searchFailed = false

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    if allowsCurrentLocation {
                        Button {
                            pick(.currentLocation())
                        } label: {
                            Label("Current Location", systemImage: "location.fill")
                        }
                    }
                    if !nearbyStops.isEmpty {
                        Section("Nearby Stops") {
                            ForEach(nearbyStops) { stop in
                                stopButton(stop, showsDistance: true)
                            }
                        }
                    }
                    if !places.isEmpty {
                        Section("Places") {
                            ForEach(places) { place in
                                Button {
                                    pick(place.waypoint)
                                } label: {
                                    row(name: place.name, subtitle: place.subtitle, symbol: "mappin.circle.fill")
                                }
                                .tint(.primary)
                            }
                        }
                    }
                } else {
                    if !stops.isEmpty {
                        Section("Stations & Stops") {
                            ForEach(stops) { stop in
                                stopButton(stop, showsDistance: false)
                            }
                        }
                    }
                    Section(stops.isEmpty ? "" : "Places") {
                        ForEach(results, id: \.self) { item in
                            Button {
                                pick(Waypoint(name: item.name ?? "Pin", subtitle: item.shortAddress, coordinate: Coordinate(item.location.coordinate)))
                            } label: {
                                row(name: item.name ?? "Pin", subtitle: item.shortAddress, symbol: item.isTransit ? "tram.circle.fill" : "mappin.circle.fill")
                            }
                            .tint(.primary)
                        }
                    }
                }
            }
            .overlay {
                if !query.isEmpty && results.isEmpty && stops.isEmpty && searchFailed {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search places, stations, addresses")
            .task(id: query) { await search() }
            .task {
                if let coordinate = location.coordinate {
                    nearbyStops = await transitData.library.stops(near: coordinate)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
            }
        }
    }

    private func row(name: String, subtitle: String?, symbol: String) -> some View {
        Label {
            Text(name)
            if let subtitle {
                Text(subtitle)
            }
        } icon: {
            Image(systemName: symbol)
        }
    }

    private func stopButton(_ stop: TransitStop, showsDistance: Bool) -> some View {
        Button {
            pick(stop.waypoint)
        } label: {
            TransitStopRow(stop: stop, distanceMeters: showsDistance ? location.coordinate?.distance(to: stop.coordinate) : nil)
        }
        .tint(.primary)
    }

    private func pick(_ waypoint: Waypoint) {
        onPick(waypoint)
        dismiss()
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            results = []
            stops = []
            return
        }
        // Installed schedules answer instantly; Apple's search follows after the debounce.
        stops = await transitData.library.searchStops(matching: text, near: location.coordinate, limit: 8)
        // Debounce typing; .task(id:) cancels this when the query changes.
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.resultTypes = [.address, .pointOfInterest]
        if let center = location.location?.coordinate {
            request.region = MKCoordinateRegion(center: center, latitudinalMeters: 80_000, longitudinalMeters: 80_000)
        }
        do {
            results = try await MKLocalSearch(request: request).start().mapItems
            searchFailed = results.isEmpty
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            searchFailed = true
        }
    }
}

private extension MKMapItem {
    var shortAddress: String? {
        address?.shortAddress ?? address?.fullAddress
    }

    var isTransit: Bool {
        pointOfInterestCategory == .publicTransport
    }
}
