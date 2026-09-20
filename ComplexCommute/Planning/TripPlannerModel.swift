import CommuteCore
import Foundation
import Observation

enum DepartureChoice: Hashable {
    case now
    case at(Date)
}

/// The trip currently being edited, planned and shown on the map.
@Observable
final class TripPlannerModel {
    enum Status: Equatable {
        case idle
        case waitingForLocation
        case failed(String)
    }

    var template = TripTemplate()
    var departure: DepartureChoice = .now
    var selectedID: Itinerary.ID?

    private(set) var itineraries: [Itinerary] = []
    private(set) var tags: [Itinerary.ID: Set<ItineraryTag>] = [:]
    private(set) var status: Status = .idle
    private(set) var isPlanning = false
    private(set) var lastUpdated: Date?
    /// The trip being travelled, once the rider taps Start.
    private(set) var active: ActiveTrip?

    let location: LocationService
    private let planner: ChainPlanner

    /// How often "leave now" trips re-plan while on screen.
    static let refreshInterval: Duration = .seconds(30)
    /// A trip in progress re-plans more eagerly: a missed connection should show up fast.
    static let activeRefreshInterval: Duration = .seconds(20)

    init(location: LocationService, resolver: any LegResolving) {
        self.location = location
        self.planner = ChainPlanner(resolver: resolver)
    }

    var selected: Itinerary? {
        itineraries.first { $0.id == selectedID } ?? itineraries.first
    }

    /// What the map draws: the rest of the trip in progress, or the option being considered.
    var displayedItinerary: Itinerary? {
        active.map { Itinerary(legs: $0.remainingLegs) } ?? selected
    }

    func start(_ template: TripTemplate) {
        self.template = template
        departure = .now
        itineraries = []
        tags = [:]
        selectedID = nil
        status = .idle
        lastUpdated = nil
        active = nil
    }

    // MARK: Active trip

    /// Starts travelling the selected option. Returns false if there is nothing to start.
    @discardableResult
    func startActiveTrip() -> Bool {
        guard let selected else { return false }
        var resolved = template
        if let coordinate = location.coordinate {
            resolved.updateCurrentLocation(coordinate)
        }
        active = ActiveTrip(template: resolved, itinerary: selected)
        return active != nil
    }

    func endActiveTrip() {
        active = nil
    }

    /// Stops the trip and hands what's left of it to the editor, starting from where the rider is now.
    func editRemainingTrip() {
        guard let trip = active else { return }
        let next = min(trip.currentSegment + 1, trip.template.waypoints.count - 1)
        let remaining = [.currentLocation()] + trip.template.waypoints[next...]
        let modes = Array(trip.template.modes[(next - 1)...])
        start(TripTemplate(waypoints: remaining, modes: modes))
    }

    func markArrived() {
        active?.markArrived()
    }

    func markMissed() {
        active?.markMissed()
    }

    func dismissNotice() {
        active?.dismissNotice()
    }

    func follow(_ itinerary: Itinerary) {
        active?.follow(itinerary)
    }

    /// Tracks progress and keeps re-planning what's left until the trip ends or the calling task is cancelled.
    func followActiveTrip() async {
        while !Task.isCancelled, let trip = active, !trip.isFinished {
            await refreshActiveTrip()
            try? await Task.sleep(for: Self.activeRefreshInterval)
        }
    }

    /// Cheap enough to run on every location fix: only checks whether the rider reached the next waypoint.
    func locationDidChange() {
        guard active?.update(location: location.coordinate, now: .now) == true else { return }
        Task { await refreshActiveTrip() }
    }

    func refreshActiveTrip() async {
        active?.update(location: location.coordinate, now: .now)
        guard let request = active?.replanRequest(location: location.coordinate, now: .now) else { return }
        isPlanning = true
        defer { isPlanning = false }
        let planned = try? await planner.plan(request.template, departingAt: request.departure, canDelayDeparture: request.canDelayDeparture)
        guard !Task.isCancelled, let planned else { return }
        active?.apply(planned, for: request)
        lastUpdated = .now
    }

    /// Plans once, then keeps re-planning from the live location until the calling task is cancelled.
    func planContinuously() async {
        repeat {
            await plan()
            try? await Task.sleep(for: Self.refreshInterval)
        } while !Task.isCancelled && departure == .now
    }

    func plan() async {
        guard template.isPlannable else {
            itineraries = []
            status = .idle
            return
        }

        var resolved = template
        if resolved.usesCurrentLocation {
            guard let coordinate = location.coordinate else {
                status = .waitingForLocation
                return
            }
            resolved.updateCurrentLocation(coordinate)
        }

        let departingAt: Date = switch departure {
        case .now: .now
        case .at(let date): date
        }

        isPlanning = true
        defer { isPlanning = false }
        do {
            let planned = try await planner.plan(resolved, departingAt: departingAt)
            guard !Task.isCancelled else { return }
            itineraries = planned
            tags = ChainPlanner.tags(for: planned)
            if selectedID == nil || !planned.contains(where: { $0.id == selectedID }) {
                selectedID = planned.first?.id
            }
            status = .idle
            lastUpdated = .now
        } catch is CancellationError {
        } catch PlanningError.noRoute(let index) {
            let segment = resolved.segments[index]
            itineraries = []
            status = .failed("No \(segment.mode.label.lowercased()) route from \(segment.from.name) to \(segment.to.name).")
        } catch {
            // Keep showing the last good options through transient network failures.
            if itineraries.isEmpty {
                status = .failed(error.localizedDescription)
            }
        }
    }
}
