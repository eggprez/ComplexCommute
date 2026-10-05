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

                    Button {
                        open(TripTemplate(waypoints: [.currentLocation()], modes: [], excludedFeedIDs: ServiceChoice.lastExcluded), autosaves: true)
                    } label: {
                        Label("New Commute", systemImage: "plus.circle.fill")
                            .fontWeight(.medium)
                    }
                } header: {
                    SheetSectionHeader("Commutes")
                } footer: {
                    if commutes.isEmpty {
                        Text("Save the trips you take often. Each one plans itself from wherever you are, and can count back from the time you have to be there.")
                    }
                }

                Section {
                    placeShortcuts
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                } header: {
                    SheetSectionHeader("Places")
                }
            }
            // Rows otherwise show through the header as they scroll under it.
            .scrollEdgeEffectStyle(.hard, for: .top)
            .contentMargins(.top, 8, for: .scrollContent)
            // Like Maps, the search field is the top of the sheet, and all that shows when it is pulled down.
            .safeAreaInset(edge: .top, spacing: 0) {
                header
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .trip(let commute, let autosaves):
                    TripView(planner: planner, commute: commute, autosaves: autosaves, restoreSheet: { detent = RootView.half }, onStart: {
                        path.append(.activeTrip)
                        // The trip is on the map; don't leave it buried under a full-height sheet.
                        detent = RootView.half
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
        // A trip can begin without this screen's say-so: picked back up at launch.
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
        // From a commute's widget: straight to the commute, counting back from an arrival time the rider can change.
        .onChange(of: router.commuteID, initial: true) { openCommuteFromWidget() }
        // At a cold launch the link can arrive before the commutes have been read.
        .onChange(of: commutes.count) { openCommuteFromWidget() }
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

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                picking = .destination
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .fontWeight(.medium)
                    Text("Where to?")
                    Spacer(minLength: 0)
                }
                .font(.body)
                .foregroundStyle(Color.secondary)
                .padding(.horizontal, 14)
                .frame(height: 46)
                .background(Color(.secondarySystemGroupedBackground), in: .capsule)
                .contentShape(.capsule)
            }
            .accessibilityLabel("Where to?")
            .accessibilityAddTraits(.isSearchField)

            Button {
                router.isShowingTransitData = true
            } label: {
                Image(systemName: "tram.fill")
                    .font(.body.weight(.medium))
                    .frame(width: 46, height: 46)
                    .background(Color(.secondarySystemGroupedBackground), in: .circle)
                    .contentShape(.circle)
            }
            .accessibilityLabel("Transit Data")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 16)
        // Clear of the sheet's grabber.
        .padding(.top, 22)
        .padding(.bottom, 10)
        .background(Color(.systemGroupedBackground))
    }

    /// Saved places as a row of round shortcuts, the way Maps keeps favorites.
    private var placeShortcuts: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 6) {
                ForEach(places) { place in
                    Button {
                        open(TripTemplate(waypoints: [.currentLocation(), place.waypoint], modes: [.transit], excludedFeedIDs: ServiceChoice.lastExcluded))
                    } label: {
                        PlaceShortcut(name: place.name, symbol: place.symbol, color: place.tint)
                    }
                    .contextMenu {
                        Button("Remove", systemImage: "trash", role: .destructive) {
                            modelContext.delete(place)
                        }
                    }
                    .accessibilityHint(place.subtitle ?? "")
                }

                Button {
                    picking = .newPlace
                } label: {
                    PlaceShortcut(name: "Add", symbol: "plus", color: nil)
                }
                .accessibilityLabel("Add Place")
            }
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .buttonStyle(.plain)
    }

    private var isNamingPlace: Binding<Bool> {
        Binding(get: { placeBeingNamed != nil }, set: { if !$0 { placeBeingNamed = nil } })
    }

    private func open(_ template: TripTemplate, commute: Commute? = nil, autosaves: Bool = false, arrivingBy target: Date? = nil) {
        planner.start(template, arrivingBy: target)
        path = [.trip(commute, autosaves: autosaves)]
    }

    private func openCommuteFromWidget() {
        guard let id = router.commuteID, let commute = commutes.first(where: { $0.widgetID == id }) else { return }
        router.commuteID = nil
        // A trip being travelled isn't dropped for a tap on the Home Screen.
        guard planner.active == nil else { return }
        open(commute.template, commute: commute, autosaves: true, arrivingBy: commute.nextArriveBy ?? Date.now.addingTimeInterval(3_600))
        // The arrival time sits under the stops; show the whole editor.
        detent = .large
    }

    /// Runs once the picker sheet is fully gone, so follow-up navigation and alerts present cleanly.
    private func handlePick() {
        // Presenting the picker forced this sheet to full height; bring the map back.
        detent = RootView.half
        guard let (purpose, waypoint) = picked else { return }
        picked = nil
        switch purpose {
        case .destination:
            open(TripTemplate(waypoints: [.currentLocation(), waypoint], modes: [.transit], excludedFeedIDs: ServiceChoice.lastExcluded))
        case .newPlace:
            placeName = waypoint.name
            placeBeingNamed = waypoint
        }
    }
}

private struct CommuteRow: View {
    let commute: Commute

    var body: some View {
        let template = commute.template
        let look = commute.look
        HStack(spacing: 12) {
            IconTile(systemName: look.primary.symbol, color: look.primary.tint, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(commute.name)
                    .font(.headline)
                chain(for: template)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if look.kinds.count > 1 || commute.nextArriveBy != nil {
                    HStack(spacing: 8) {
                        if look.kinds.count > 1 {
                            KindStrip(kinds: look.kinds)
                        }
                        if let arriveBy = commute.nextArriveBy {
                            Chip(text: "by \(arriveBy.formatted(date: .omitted, time: .shortened))", systemImage: "target")
                        }
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityValue(look.kinds.map(\.label).formatted(.list(type: .and)))
    }

    private func chain(for template: TripTemplate) -> Text {
        guard let first = template.waypoints.first else { return Text("No stops yet") }
        return template.waypoints.dropFirst().reduce(Text(first.name)) { text, waypoint in
            Text("\(text) \(Image(systemName: "arrow.right")) \(waypoint.name)")
        }
    }
}

/// How a commute is travelled, in order: car, then train, then subway.
private struct KindStrip: View {
    let kinds: [TravelKind]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(kinds.enumerated()), id: \.offset) { index, kind in
                if index > 0 {
                    Image(systemName: "chevron.compact.right")
                        .font(.caption2)
                        .foregroundStyle(Color.secondary.opacity(0.5))
                }
                Image(systemName: kind.symbol)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(kind.tint)
                    .frame(width: 26, height: 20)
                    .background(kind.tint.opacity(0.16), in: .capsule)
            }
        }
        .accessibilityHidden(true)
    }
}

/// One saved place: a round tile and its name underneath.
private struct PlaceShortcut: View {
    let name: String
    let symbol: String
    /// Nil for the shortcut that adds one.
    let color: Color?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(color == nil ? Color.accentColor : Color.white)
                .frame(width: 58, height: 58)
                .background(color.map { AnyShapeStyle($0.gradient) } ?? AnyShapeStyle(Color(.secondarySystemGroupedBackground)), in: .circle)
            Text(name)
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
        }
        .frame(width: 76)
        .contentShape(.rect)
    }
}

extension SavedPlace {
    /// A place named for what it is gets that thing's symbol.
    private var look: (symbol: String, tint: Color) {
        let name = name.lowercased()
        if name.contains("home") { return ("house.fill", .blue) }
        if name.contains("work") || name.contains("office") { return ("briefcase.fill", .brown) }
        if name.contains("school") || name.contains("campus") { return ("graduationcap.fill", .purple) }
        if name.contains("gym") { return ("dumbbell.fill", .green) }
        if name.contains("airport") { return ("airplane", .cyan) }
        return ("mappin", .red)
    }

    var symbol: String { look.symbol }
    var tint: Color { look.tint }
}
