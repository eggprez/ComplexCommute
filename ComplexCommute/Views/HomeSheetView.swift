import CommuteCore
import SwiftData
import SwiftUI

struct HomeSheetView: View {
    private enum Route: Hashable {
        case trip(Commute?)
    }

    private enum Picking: String, Identifiable {
        case destination
        case newPlace
        var id: String { rawValue }
    }

    let planner: TripPlannerModel
    @Binding var detent: PresentationDetent

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Commute.createdAt) private var commutes: [Commute]
    @Query(sort: \SavedPlace.createdAt) private var places: [SavedPlace]

    @State private var path: [Route] = []
    @State private var picking: Picking?
    @State private var picked: (purpose: Picking, waypoint: Waypoint)?
    @State private var placeBeingNamed: Waypoint?
    @State private var placeName = ""
    @State private var isShowingSettings = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    Button {
                        picking = .destination
                    } label: {
                        Label("Where to?", systemImage: "magnifyingglass")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Commutes") {
                    ForEach(commutes) { commute in
                        Button {
                            open(commute.template, commute: commute)
                        } label: {
                            CommuteRow(commute: commute)
                        }
                        .tint(.primary)
                    }
                    .onDelete { offsets in
                        offsets.map { commutes[$0] }.forEach(modelContext.delete)
                    }

                    Button("New Commute", systemImage: "plus") {
                        open(TripTemplate(waypoints: [.currentLocation()], modes: []), commute: nil)
                    }
                }

                Section("Places") {
                    ForEach(places) { place in
                        Button {
                            open(TripTemplate(waypoints: [.currentLocation(), place.waypoint], modes: [.transit]), commute: nil)
                        } label: {
                            Label {
                                Text(place.name)
                                if let subtitle = place.subtitle {
                                    Text(subtitle)
                                }
                            } icon: {
                                Image(systemName: "mappin.circle.fill")
                            }
                        }
                        .tint(.primary)
                    }
                    .onDelete { offsets in
                        offsets.map { places[$0] }.forEach(modelContext.delete)
                    }

                    Button("Add Place", systemImage: "plus") {
                        picking = .newPlace
                    }
                }
            }
            .navigationTitle("Commute")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Transit Data", systemImage: "tram") { isShowingSettings = true }
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .trip(let commute):
                    TripView(planner: planner, commute: commute) { detent = RootView.half }
                }
            }
        }
        .onChange(of: path) {
            if path.isEmpty {
                planner.start(TripTemplate())
            }
        }
        .sheet(item: $picking, onDismiss: handlePick) { purpose in
            PlacePickerView(
                title: purpose == .destination ? "Where to?" : "Add Place",
                allowsCurrentLocation: false,
                location: planner.location
            ) { picked = (purpose, $0) }
        }
        .sheet(isPresented: $isShowingSettings, onDismiss: { detent = RootView.half }) {
            SettingsView()
        }
        .alert("Name This Place", isPresented: isNamingPlace) {
            TextField("Name", text: $placeName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                guard let waypoint = placeBeingNamed else { return }
                let name = placeName.trimmingCharacters(in: .whitespaces)
                modelContext.insert(SavedPlace(name: name.isEmpty ? waypoint.name : name, subtitle: waypoint.subtitle, coordinate: waypoint.coordinate))
            }
        }
    }

    private var isNamingPlace: Binding<Bool> {
        Binding(get: { placeBeingNamed != nil }, set: { if !$0 { placeBeingNamed = nil } })
    }

    private func open(_ template: TripTemplate, commute: Commute?) {
        planner.start(template)
        path = [.trip(commute)]
    }

    /// Runs once the picker sheet is fully gone, so follow-up navigation and alerts present cleanly.
    private func handlePick() {
        // Presenting the picker forced this sheet to full height; bring the map back.
        detent = RootView.half
        guard let (purpose, waypoint) = picked else { return }
        picked = nil
        switch purpose {
        case .destination:
            open(TripTemplate(waypoints: [.currentLocation(), waypoint], modes: [.transit]), commute: nil)
        case .newPlace:
            placeName = waypoint.name
            placeBeingNamed = waypoint
        }
    }
}

private struct CommuteRow: View {
    let commute: Commute

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(commute.name)
                .font(.headline)
            chain
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }

    private var chain: Text {
        let template = commute.template
        guard let first = template.waypoints.first else { return Text("Empty") }
        return template.segments.reduce(Text(first.name)) { text, segment in
            Text("\(text) \(Image(systemName: segment.mode.symbol)) \(segment.to.name)")
        }
    }
}
