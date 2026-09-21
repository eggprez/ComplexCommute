import CommuteCore
import SwiftData
import SwiftUI

struct HomeSheetView: View {
    private enum Route: Hashable {
        /// `autosaves` marks a commute being built or edited, as opposed to a one-off trip.
        case trip(Commute?, autosaves: Bool)
        case activeTrip
        case station(StationRef)
    }

    private enum Picking: String, Identifiable {
        case destination
        case newPlace
        var id: String { rawValue }
    }

    let planner: TripPlannerModel
    @Binding var detent: PresentationDetent

    @Environment(\.modelContext) private var modelContext
    @Environment(SheetRouter.self) private var router
    @Query(sort: \Commute.createdAt) private var commutes: [Commute]
    @Query(sort: \SavedPlace.createdAt) private var places: [SavedPlace]

    @State private var path: [Route] = []
    @State private var picking: Picking?
    @State private var picked: (purpose: Picking, waypoint: Waypoint)?
    @State private var placeBeingNamed: Waypoint?
    @State private var placeName = ""

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
                            // A commute saved without any stops still opens as something that can be built on.
                            let template = commute.template
                            open(template.waypoints.isEmpty ? TripTemplate(waypoints: [.currentLocation()], modes: []) : template,
                                 commute: commute, autosaves: true, arrivingBy: commute.nextArriveBy)
                        } label: {
                            CommuteRow(commute: commute)
                        }
                        .tint(.primary)
                    }
                    .onDelete { offsets in
                        offsets.map { commutes[$0] }.forEach(modelContext.delete)
                    }

                    Button("New Commute", systemImage: "plus") {
                        open(TripTemplate(waypoints: [.currentLocation()], modes: []), autosaves: true)
                    }
                }

                Section("Places") {
                    ForEach(places) { place in
                        Button {
                            open(TripTemplate(waypoints: [.currentLocation(), place.waypoint], modes: [.transit]))
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
                    Button("Transit Data", systemImage: "tram") { router.isShowingTransitData = true }
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .trip(let commute, let autosaves):
                    TripView(planner: planner, commute: commute, autosaves: autosaves, restoreSheet: { detent = RootView.half }, onStart: {
                        path.append(.activeTrip)
                        // Navigation happens on the map; don't leave it buried under a full-height sheet.
                        // Setting off by car, a driver wants the road and the numbers, nothing else.
                        detent = planner.isNavigating && planner.guidedLeg?.mode == .drive
                            ? RootView.collapsed(withTarget: planner.active?.arriveBy != nil) : RootView.half
                    })
                case .activeTrip:
                    ActiveTripView(planner: planner, onEdit: {
                        planner.editRemainingTrip()
                        path = [.trip(nil, autosaves: false)]
                    }, onDone: {
                        path = []
                        // Driving leaves the sheet tucked away; home is no use at that size.
                        detent = RootView.half
                    })
                case .station(let station):
                    StationBoardView(station: station)
                }
            }
        }
        // A trip can begin without this screen's say-so: picked back up at launch, or started from the Watch.
        .onChange(of: planner.active != nil, initial: true) { _, isActive in
            if isActive, !path.contains(.activeTrip) { path = [.activeTrip] }
        }
        .onChange(of: router.station) {
            guard let station = router.station else { return }
            router.station = nil
            if path.last != .station(station) { path.append(.station(station)) }
            // A tap on the map would otherwise go unanswered behind a collapsed sheet.
            if detent != RootView.half, detent != .large { detent = RootView.half }
        }
        .onChange(of: path) {
            if path.isEmpty {
                planner.start(TripTemplate())
            } else if !path.contains(.activeTrip) {
                planner.endActiveTrip()
            }
        }
        .sheet(item: $picking, onDismiss: handlePick) { purpose in
            PlacePickerView(
                title: purpose == .destination ? "Where to?" : "Add Place",
                allowsCurrentLocation: false,
                location: planner.location
            ) { picked = (purpose, $0) }
        }
        .sheet(isPresented: Bindable(router).isShowingTransitData, onDismiss: { detent = RootView.half }) {
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

    private func open(_ template: TripTemplate, commute: Commute? = nil, autosaves: Bool = false, arrivingBy target: Date? = nil) {
        planner.start(template, arrivingBy: target)
        path = [.trip(commute, autosaves: autosaves)]
    }

    /// Runs once the picker sheet is fully gone, so follow-up navigation and alerts present cleanly.
    private func handlePick() {
        // Presenting the picker forced this sheet to full height; bring the map back.
        detent = RootView.half
        guard let (purpose, waypoint) = picked else { return }
        picked = nil
        switch purpose {
        case .destination:
            open(TripTemplate(waypoints: [.currentLocation(), waypoint], modes: [.transit]))
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
            HStack(spacing: 6) {
                Text(commute.name)
                    .font(.headline)
                if let arriveBy = commute.nextArriveBy {
                    Label(arriveBy.formatted(date: .omitted, time: .shortened), systemImage: "target")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
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
