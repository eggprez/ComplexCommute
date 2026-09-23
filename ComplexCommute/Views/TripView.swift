import CommuteCore
import GTFSKit
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
        /// Changing the buffer in Settings changes which connections can be made.
        var bufferMinutes: Int
    }

    private enum Naming {
        case savingCopy
        case renaming
    }

    @Bindable var planner: TripPlannerModel
    @State var commute: Commute?
    /// A commute keeps itself saved as it is edited; a one-off trip is only saved on request.
    var autosaves = false
    /// Called after a nested sheet closes; presenting one forces the main sheet to full height.
    var restoreSheet: () -> Void = {}
    var onStart: () -> Void = {}

    @Environment(\.modelContext) private var modelContext
    @AppStorage(StationBuffer.key) private var bufferMinutes = StationBuffer.defaultMinutes
    @State private var pickerTarget: PickerTarget?
    @State private var naming = Naming.savingCopy
    @State private var isNaming = false
    @State private var commuteName = ""
    /// A commute just created, waiting to be asked whether it has a standing arrival time.
    @State private var askingArriveBy: Commute?
    /// Only the editor on screen may write to its commute; one being popped must not save its successor's trip.
    @State private var isOnScreen = false

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
                if planner.template.modes.contains(.transit) {
                    ServicesPicker(template: $planner.template, location: planner.location.coordinate)
                }
                if let commute, planner.departure.target != nil {
                    Toggle("Every Time I Take This Commute", isOn: standingTarget(for: commute))
                        .font(.subheadline)
                }
            }

            if let target = planner.departure.target, let best = planner.selected {
                Section {
                    LeaveAtCard(itinerary: best, target: target)
                } header: {
                    Text("Leave At")
                } footer: {
                    Text(best.arrival <= target
                         ? "The latest you can leave and still be there by \(target.formatted(date: .omitted, time: .shortened))."
                         : "Nothing gets you there by \(target.formatted(date: .omitted, time: .shortened)); this is the soonest you can arrive.")
                }
            }

            if planner.selected != nil {
                Section {
                    Button {
                        if planner.startActiveTrip() { onStart() }
                    } label: {
                        Text("Go")
                            .font(.title3.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .accessibilityLabel("Start Trip")
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }

            Section {
                optionsContent
            } header: {
                HStack {
                    Text("Options")
                    // "Finding routes…" already says so when there is nothing to show yet.
                    if planner.isPlanning, !planner.itineraries.isEmpty {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
            } footer: {
                if let updated = planner.lastUpdated, !planner.itineraries.isEmpty, !isFixedDeparture {
                    Text("Updated \(updated, format: .relative(presentation: .named)). Options refresh from your location \(planner.departure == .now ? "every 30 seconds" : "every couple of minutes").")
                }
            }
        }
        // Colored rows (the Go button, a selected option) otherwise show through the title bar as they scroll under it.
        .scrollEdgeEffectStyle(.hard, for: .top)
        .navigationTitle(commute?.name ?? (autosaves ? "New Commute" : "Trip"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                saveMenu
            }
        }
        .task(id: PlanKey(template: planner.template, departure: planner.departure, bufferMinutes: bufferMinutes)) {
            await planner.planContinuously()
        }
        .onAppear { isOnScreen = true }
        .onDisappear { isOnScreen = false }
        .onChange(of: planner.template) { previous, template in
            autosave(template, replacing: previous)
            if previous.excludedFeedIDs != template.excludedFeedIDs {
                ServiceChoice.remember(template.excludedFeedIDs)
            }
        }
        .sheet(item: $askingArriveBy, onDismiss: restoreSheet) { commute in
            ArriveByPrompt(commute: commute) { target in
                planner.departure = target.map(DepartureChoice.arriveBy) ?? planner.departure
                try? modelContext.save()
                if target != nil { Task { await planner.notifier.requestAuthorizationIfNeeded() } }
            }
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
        .alert(naming == .renaming ? "Rename Commute" : "Save Commute", isPresented: $isNaming) {
            TextField("Name", text: $commuteName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let name = commuteName.trimmingCharacters(in: .whitespaces)
                if naming == .renaming, let commute {
                    if !name.isEmpty { commute.name = name }
                } else {
                    let saved = Commute(name: name.isEmpty ? Commute.defaultName(for: planner.template) : name, template: planner.template)
                    modelContext.insert(saved)
                    commute = saved
                }
                try? modelContext.save()
            }
        }
    }

    /// Commutes save themselves: created once there is somewhere to go, then kept in step with every edit.
    private func autosave(_ template: TripTemplate, replacing previous: TripTemplate) {
        guard autosaves, isOnScreen, template.isPlannable else { return }
        if let commute {
            // A name the app made up follows the endpoints; one the rider chose stays.
            if commute.name == Commute.defaultName(for: previous) {
                commute.name = Commute.defaultName(for: template)
            }
            commute.template = template
        } else {
            let saved = Commute(name: Commute.defaultName(for: template), template: template)
            modelContext.insert(saved)
            commute = saved
            askingArriveBy = saved
        }
        try? modelContext.save()
    }

    @ViewBuilder
    private var optionsContent: some View {
        if !planner.template.isPlannable {
            Text("Add at least two stops to see options.")
                .foregroundStyle(.secondary)
        } else if !planner.itineraries.isEmpty {
            if planner.departure.target == nil {
                ForEach(planner.itineraries) { itinerary in
                    card(for: itinerary)
                }
            } else {
                // The one to take is already answered above; the rest are there if it doesn't suit.
                DisclosureGroup("Other Departures") {
                    ForEach(planner.itineraries) { itinerary in
                        card(for: itinerary)
                    }
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

    /// A departure time the rider fixed themselves has nothing to watch for.
    private var isFixedDeparture: Bool {
        if case .at = planner.departure { return true }
        return false
    }

    private func card(for itinerary: Itinerary) -> some View {
        ItineraryCard(
            itinerary: itinerary,
            tags: planner.tags[itinerary.id] ?? [],
            isSelected: itinerary.id == planner.selected?.id,
            isLeavingNow: planner.departure == .now,
            target: planner.departure.target
        ) {
            withAnimation { planner.select(itinerary) }
        }
    }

    /// Keeps a commute's standing arrival time in step with the one being planned.
    private func standingTarget(for commute: Commute) -> Binding<Bool> {
        Binding(
            get: { commute.arriveByMinutes != nil },
            set: { isOn in
                commute.arriveBy = isOn ? planner.departure.target.map { TimeOfDay($0) } : nil
                commute.hasBeenAskedArriveBy = true
                try? modelContext.save()
                if isOn { Task { await planner.notifier.requestAuthorizationIfNeeded() } }
            }
        )
    }

    @ViewBuilder
    private var saveMenu: some View {
        if let commute {
            Menu("Commute", systemImage: "bookmark.fill") {
                if autosaves {
                    Section("Changes save automatically") {
                        Button("Rename…", systemImage: "pencil") {
                            commuteName = commute.name
                            naming = .renaming
                            isNaming = true
                        }
                    }
                } else {
                    Button("Update “\(commute.name)”", systemImage: "arrow.triangle.2.circlepath") {
                        commute.template = planner.template
                        try? modelContext.save()
                    }
                    .disabled(commute.template == planner.template)
                }
                Button("Save as New Commute…", systemImage: "plus") {
                    commuteName = ""
                    naming = .savingCopy
                    isNaming = true
                }
            }
        } else if !autosaves {
            Button("Save Commute", systemImage: "bookmark") {
                commuteName = Commute.defaultName(for: planner.template)
                naming = .savingCopy
                isNaming = true
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

/// The transit services this rider last left out, carried into the next trip they start.
enum ServiceChoice {
    private static let key = "lastExcludedFeedIDs"

    static var lastExcluded: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func remember(_ excluded: Set<String>) {
        UserDefaults.standard.set(excluded.sorted(), forKey: key)
    }
}

/// One compact row for turning individual transit services off for this trip, e.g. no buses.
/// The menu stays open while toggling, so several can be switched in one go.
private struct ServicesPicker: View {
    @Binding var template: TripTemplate
    let location: Coordinate?

    @Environment(TransitDataStore.self) private var store

    var body: some View {
        if !services.isEmpty {
            Menu {
                ForEach(regions) { region in
                    Section(regions.count > 1 ? region.name : "Take") {
                        ForEach(services.filter { $0.region == region }) { feed in
                            Toggle(feed.name, isOn: binding(for: feed))
                        }
                    }
                }
                if !excluded.isEmpty {
                    Button("Use All Services", systemImage: "arrow.counterclockwise") {
                        template.excludedFeedIDs.subtract(services.map(\.id))
                    }
                }
            } label: {
                LabeledContent {
                    Text(summary)
                        .foregroundStyle(excluded.isEmpty ? Color.secondary : Color.accentColor)
                } label: {
                    Label("Services", systemImage: "tram")
                }
                .contentShape(.rect)
            }
            .menuActionDismissBehavior(.disabled)
            .tint(.primary)
        }
    }

    /// Installed cities the trip passes through.
    private var regions: [TransitRegion] {
        let coordinates = template.waypoints.compactMap { waypoint in
            waypoint.kind == .currentLocation ? location : waypoint.coordinate
        }
        return TransitRegion.near(coordinates).filter { store.state(of: $0) != .notInstalled }
    }

    private var services: [FeedDescriptor] {
        regions.flatMap(FeedCatalog.feeds(in:)).filter { store.installed[$0.id] != nil }
    }

    private var excluded: [FeedDescriptor] {
        services.filter { template.excludedFeedIDs.contains($0.id) }
    }

    private var summary: String {
        switch excluded.count {
        case 0: "All"
        case services.count: "None"
        case 1...2: "No " + excluded.map(\.name).formatted(.list(type: .and))
        default: "\(services.count - excluded.count) of \(services.count)"
        }
    }

    private func binding(for feed: FeedDescriptor) -> Binding<Bool> {
        Binding(
            get: { !template.excludedFeedIDs.contains(feed.id) },
            set: { isOn in
                if isOn {
                    template.excludedFeedIDs.remove(feed.id)
                } else {
                    template.excludedFeedIDs.insert(feed.id)
                }
            }
        )
    }
}

private struct WaypointRow: View {
    let waypoint: Waypoint
    let modeToNext: Binding<TravelMode>?
    let onTap: () -> Void

    @Environment(SheetRouter.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
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
                if let station = waypoint.station {
                    Button("Departures", systemImage: "clock") { router.station = station }
                        .labelStyle(.iconOnly)
                }
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
    private enum Plan: String, CaseIterable, Identifiable {
        case now
        case leaveAt
        case arriveBy

        var id: String { rawValue }
        var label: String {
            switch self {
            case .now: "Leave Now"
            case .leaveAt: "Leave At"
            case .arriveBy: "Arrive By"
            }
        }
    }

    @Binding var departure: DepartureChoice

    var body: some View {
        Picker("When", selection: plan) {
            ForEach(Plan.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)

        switch departure {
        case .now:
            EmptyView()
        case .at(let date):
            DatePicker("Departure", selection: bound(to: DepartureChoice.at, from: date), in: Date.now...)
        case .arriveBy(let date):
            DatePicker("Arrival", selection: bound(to: DepartureChoice.arriveBy, from: date), in: Date.now...)
        }
    }

    private func bound(to make: @escaping (Date) -> DepartureChoice, from date: Date) -> Binding<Date> {
        Binding(get: { date }, set: { departure = make($0) })
    }

    private var plan: Binding<Plan> {
        Binding(
            get: {
                switch departure {
                case .now: .now
                case .at: .leaveAt
                case .arriveBy: .arriveBy
                }
            },
            set: { choice in
                switch choice {
                case .now: departure = .now
                case .leaveAt: departure = .at(Date.now.addingTimeInterval(900))
                case .arriveBy: departure = .arriveBy(Date.now.addingTimeInterval(3_600))
                }
            }
        )
    }
}

/// The one thing an arrive-by trip is asked for: when to walk out of the door.
private struct LeaveAtCard: View {
    let itinerary: Itinerary
    let target: Date

    var body: some View {
        let progress = ArriveByProgress(target: target, projectedArrival: itinerary.arrival)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(itinerary.departure.formatted(date: .omitted, time: .shortened))
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(lead)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Image(systemName: progress.standing.symbol)
                    .foregroundStyle(progress.standing.tint)
                Text("Arrive \(itinerary.arrival.formatted(date: .omitted, time: .shortened)) · \(progress.deltaDescription)")
                    .font(.subheadline)
            }
            SegmentStrip(legs: itinerary.legs)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Leave at \(itinerary.departure.clockTime), \(lead). Arriving \(itinerary.arrival.clockTime), \(progress.deltaDescription).")
    }

    private var lead: String {
        let wait = itinerary.departure.timeIntervalSinceNow
        return wait < 60 ? "leave now" : "in \(wait.shortDuration)"
    }
}

/// Asked once, when a commute is first saved: is this a trip with a time to be there by?
private struct ArriveByPrompt: View {
    let commute: Commute
    let onSave: (Date?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var time = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: .now) ?? .now

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Arrive By", selection: $time, displayedComponents: .hourAndMinute)
                } footer: {
                    Text("“\(commute.name)” will be planned backwards from this time, and can remind you when to leave. You can change or remove it whenever you take the trip.")
                }

                Section {
                    Button("Save With This Commute") {
                        let saved = TimeOfDay(time)
                        commute.arriveBy = saved
                        commute.hasBeenAskedArriveBy = true
                        onSave(saved.next())
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .navigationTitle("Be There By?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not Now") {
                        commute.hasBeenAskedArriveBy = true
                        onSave(nil)
                        dismiss()
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }
}
