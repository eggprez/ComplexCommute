import CommuteCore
import SwiftData
import SwiftUI

/// Edit a trip's waypoints and modes, and watch its options re-plan live.
struct TripView: View {
    private enum PickerTarget: Identifiable {
        case replace(Int)
        case append

        var id: Int {
            switch self {
            case .replace(let index): index
            case .append: -1
            }
        }
    }

    private struct PlanKey: Hashable {
        var template: TripTemplate
        var departure: DepartureChoice
    }

    @Bindable var planner: TripPlannerModel
    @State var commute: Commute?
    /// Called after a nested sheet closes; presenting one forces the main sheet to full height.
    var restoreSheet: () -> Void = {}
    var onStart: () -> Void = {}

    @Environment(\.modelContext) private var modelContext
    @State private var pickerTarget: PickerTarget?
    @State private var isNamingCommute = false
    @State private var commuteName = ""

    var body: some View {
        List {
            Section {
                ForEach(Array(planner.template.waypoints.enumerated()), id: \.element.id) { index, waypoint in
                    WaypointRow(
                        waypoint: waypoint,
                        modeToNext: index < planner.template.modes.count ? modeBinding(forSegment: index) : nil
                    ) {
                        pickerTarget = .replace(index)
                    }
                }
                .onDelete { offsets in
                    for index in offsets.sorted(by: >) {
                        planner.template.removeWaypoint(at: index)
                    }
                }
                .onMove { source, destination in
                    guard let from = source.first else { return }
                    planner.template.moveWaypoint(from: from, to: destination > from ? destination - 1 : destination)
                }

                Button("Add Stop", systemImage: "plus.circle.fill") {
                    pickerTarget = .append
                }
            }

            Section {
                DeparturePicker(departure: $planner.departure)
            }

            if planner.selected != nil {
                Section {
                    Button {
                        if planner.startActiveTrip() { onStart() }
                    } label: {
                        Label("Start Trip", systemImage: "location.north.line.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }

            Section {
                optionsContent
            } header: {
                HStack {
                    Text("Options")
                    if planner.isPlanning {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
            } footer: {
                if let updated = planner.lastUpdated, planner.departure == .now, !planner.itineraries.isEmpty {
                    Text("Updated \(updated, format: .relative(presentation: .named)). Options refresh from your location every 30 seconds.")
                }
            }
        }
        .navigationTitle(commute?.name ?? "Trip")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                saveMenu
            }
        }
        .task(id: PlanKey(template: planner.template, departure: planner.departure)) {
            await planner.planContinuously()
        }
        .sheet(item: $pickerTarget, onDismiss: restoreSheet) { target in
            PlacePickerView(title: target.id < 0 ? "Add Stop" : "Change Stop", location: planner.location) { waypoint in
                switch target {
                case .replace(let index):
                    planner.template.replaceWaypoint(at: index, with: waypoint)
                case .append:
                    planner.template.append(waypoint, mode: defaultMode(to: waypoint))
                }
            }
        }
        .alert("Save Commute", isPresented: $isNamingCommute) {
            TextField("Name", text: $commuteName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let name = commuteName.trimmingCharacters(in: .whitespaces)
                let saved = Commute(name: name.isEmpty ? "My Commute" : name, template: planner.template)
                modelContext.insert(saved)
                commute = saved
            }
        }
    }

    @ViewBuilder
    private var optionsContent: some View {
        if !planner.template.isPlannable {
            Text("Add at least two stops to see options.")
                .foregroundStyle(.secondary)
        } else if !planner.itineraries.isEmpty {
            ForEach(planner.itineraries) { itinerary in
                ItineraryCard(
                    itinerary: itinerary,
                    tags: planner.tags[itinerary.id] ?? [],
                    isSelected: itinerary.id == planner.selected?.id,
                    isLeavingNow: planner.departure == .now
                ) {
                    withAnimation { planner.selectedID = itinerary.id }
                }
            }
        } else {
            switch planner.status {
            case .waitingForLocation:
                Label("Waiting for your location…", systemImage: "location.slash")
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            case .idle:
                HStack {
                    ProgressView()
                    Text("Finding routes…")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var saveMenu: some View {
        if let commute {
            Menu("Save", systemImage: "bookmark.fill") {
                Button("Update “\(commute.name)”", systemImage: "arrow.triangle.2.circlepath") {
                    commute.template = planner.template
                }
                .disabled(commute.template == planner.template)
                Button("Save as New Commute…", systemImage: "plus") {
                    commuteName = ""
                    isNamingCommute = true
                }
            }
        } else {
            Button("Save Commute", systemImage: "bookmark") {
                commuteName = ""
                isNamingCommute = true
            }
            .disabled(!planner.template.isPlannable)
        }
    }

    /// Station to station means riding; otherwise alternate walking with transit, the usual shape of a commute.
    private func defaultMode(to waypoint: Waypoint) -> TravelMode {
        if case .stop = waypoint.kind, case .stop = planner.template.waypoints.last?.kind {
            return .transit
        }
        return planner.template.modes.last == .walk ? .transit : .walk
    }

    private func modeBinding(forSegment index: Int) -> Binding<TravelMode> {
        Binding(
            get: { index < planner.template.modes.count ? planner.template.modes[index] : .walk },
            set: { planner.template.setMode($0, forSegment: index) }
        )
    }
}

private struct WaypointRow: View {
    let waypoint: Waypoint
    let modeToNext: Binding<TravelMode>?
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onTap) {
                Label {
                    Text(waypoint.name)
                        .foregroundStyle(Color.primary)
                    if let subtitle = waypoint.subtitle {
                        Text(subtitle)
                            .foregroundStyle(Color.secondary)
                    }
                } icon: {
                    Image(systemName: waypoint.symbol)
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }

            if let modeToNext {
                Picker("Then", selection: modeToNext) {
                    ForEach(TravelMode.allCases, id: \.self) { mode in
                        Label(mode.label, systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Travel mode to next stop")
            }
        }
        .buttonStyle(.borderless)
    }
}

private struct DeparturePicker: View {
    @Binding var departure: DepartureChoice

    var body: some View {
        Picker("Leave", selection: isScheduled) {
            Text("Now").tag(false)
            Text("At a Time").tag(true)
        }
        if case .at(let date) = departure {
            DatePicker("Departure", selection: Binding(get: { date }, set: { departure = .at($0) }), in: Date.now...)
        }
    }

    private var isScheduled: Binding<Bool> {
        Binding(
            get: { departure != .now },
            set: { departure = $0 ? .at(Date.now.addingTimeInterval(900)) : .now }
        )
    }
}
