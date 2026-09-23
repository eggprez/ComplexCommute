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
    @State private var suggestions = PlaceSuggestions()
    /// Full search results, once a search is submitted or a category suggestion is chosen. Nil while suggesting.
    @State private var results: [MKMapItem]?
    @State private var isSearching = false
    @State private var stops: [TransitStop] = []
    @State private var nearbyStops: [TransitStop] = []
    @State private var recents = RecentPlaces.all

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    suggestionsForEmptyQuery
                } else {
                    if !stops.isEmpty {
                        Section("Stations & Stops") {
                            ForEach(stops) { stop in
                                stopButton(stop, showsDistance: false)
                            }
                        }
                    }
                    if let results {
                        Section(stops.isEmpty ? "" : "Places") {
                            ForEach(results, id: \.self) { item in
                                Button {
                                    pick(item)
                                } label: {
                                    PlaceResultRow(item: item, distanceMeters: location.coordinate?.distance(to: Coordinate(item.location.coordinate)))
                                }
                                .tint(.primary)
                            }
                        }
                    } else {
                        Section(stops.isEmpty ? "" : "Suggestions") {
                            ForEach(suggestions.completions, id: \.self) { completion in
                                Button {
                                    Task { await choose(completion) }
                                } label: {
                                    CompletionRow(completion: completion)
                                }
                                .tint(.primary)
                            }
                        }
                    }
                }
            }
            .overlay {
                if isSearching {
                    ProgressView()
                } else if !query.isEmpty, results?.isEmpty == true, stops.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search places, stations, addresses")
            .onSubmit(of: .search) {
                Task { _ = await search(MKLocalSearch.Request(), text: query) }
            }
            .task(id: query) { await suggest() }
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

    @ViewBuilder
    private var suggestionsForEmptyQuery: some View {
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
                    waypointButton(place.waypoint, symbol: "mappin.circle.fill")
                }
            }
        }
        if !recents.isEmpty {
            Section("Recents") {
                ForEach(recents) { recent in
                    waypointButton(recent, symbol: recent.station == nil ? "clock" : "tram.fill")
                }
            }
        }
    }

    private func waypointButton(_ waypoint: Waypoint, symbol: String) -> some View {
        Button {
            pick(waypoint)
        } label: {
            Label {
                Text(waypoint.name)
                if let subtitle = waypoint.subtitle {
                    Text(subtitle)
                }
            } icon: {
                Image(systemName: symbol)
            }
        }
        .tint(.primary)
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
        RecentPlaces.add(waypoint)
        onPick(waypoint)
        dismiss()
    }

    /// Apple's places stay places, even transit ones: the planner then weighs every stop within a walk, rather than
    /// the one stop a name match happened to land on (LaGuardia's Q90 curb instead of the Q70's).
    private func pick(_ item: MKMapItem) {
        pick(Waypoint(name: item.name ?? "Pin", subtitle: item.shortAddress, coordinate: Coordinate(item.location.coordinate)))
    }

    /// Installed schedules answer instantly; Apple's suggestions stream in behind them.
    private func suggest() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        results = nil
        suggestions.update(query: text, near: location.location?.coordinate)
        stops = text.isEmpty ? [] : await transitData.library.searchStops(matching: text, near: location.coordinate, limit: 6)
    }

    /// A suggestion naming one place is picked outright; a category or chain lists what matches nearby.
    private func choose(_ completion: MKLocalSearchCompletion) async {
        let found = await search(MKLocalSearch.Request(completion: completion), text: nil)
        if !completion.isQuery, let item = found.first {
            pick(item)
        }
    }

    @discardableResult
    private func search(_ request: MKLocalSearch.Request, text: String?) async -> [MKMapItem] {
        if let text {
            request.naturalLanguageQuery = text
        }
        request.resultTypes = [.address, .pointOfInterest]
        if let center = location.location?.coordinate {
            request.region = MKCoordinateRegion(center: center, latitudinalMeters: 80_000, longitudinalMeters: 80_000)
        }
        isSearching = true
        defer { isSearching = false }
        let items = (try? await MKLocalSearch(request: request).start().mapItems) ?? []
        results = items
        return items
    }
}

/// A suggestion as Maps shows it: the typed part stands out, with where or what it is underneath.
private struct CompletionRow: View {
    let completion: MKLocalSearchCompletion

    var body: some View {
        Label {
            Text(highlighted(completion.title, ranges: completion.titleHighlightRanges))
            if !completion.subtitle.isEmpty {
                Text(completion.subtitle)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: completion.isQuery ? "magnifyingglass" : "mappin.circle.fill")
                .foregroundStyle(completion.isQuery ? Color.secondary : Color.red)
        }
    }

    private func highlighted(_ text: String, ranges: [NSValue]) -> AttributedString {
        var attributed = AttributedString(text)
        attributed.foregroundColor = ranges.isEmpty ? .primary : .secondary
        for value in ranges {
            guard let range = Range(value.rangeValue, in: text), let matched = Range(range, in: attributed) else { continue }
            attributed[matched].foregroundColor = .primary
            attributed[matched].font = .body.weight(.semibold)
        }
        return attributed
    }
}

private struct PlaceResultRow: View {
    let item: MKMapItem
    let distanceMeters: Double?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.categorySymbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(item.categoryColor.gradient, in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name ?? "Pin")
                Text([item.categoryName, distanceMeters?.roadDistance].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let address = item.shortAddress {
                    Text(address)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
