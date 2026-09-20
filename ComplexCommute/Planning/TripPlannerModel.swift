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

    let location: LocationService
    private let planner: ChainPlanner

    /// How often "leave now" trips re-plan while on screen.
    static let refreshInterval: Duration = .seconds(30)

    init(location: LocationService, resolver: any LegResolving) {
        self.location = location
        self.planner = ChainPlanner(resolver: resolver)
    }

    var selected: Itinerary? {
        itineraries.first { $0.id == selectedID } ?? itineraries.first
    }

    func start(_ template: TripTemplate) {
        self.template = template
        departure = .now
        itineraries = []
        tags = [:]
        selectedID = nil
        status = .idle
        lastUpdated = nil
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
