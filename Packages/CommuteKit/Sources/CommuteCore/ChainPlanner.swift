import Foundation

/// Produces the ways to cover one segment when leaving `from` no earlier than `departingAt`.
public protocol LegResolving: Sendable {
    func options(from: Waypoint, to: Waypoint, mode: TravelMode, departingAt: Date) async throws -> [LegOption]
}

public enum PlanningError: Error, Equatable {
    case notPlannable
    case noRoute(segmentIndex: Int)
}

/// Chains per-segment options into whole-trip itineraries, left to right from the departure time.
public struct ChainPlanner: Sendable {
    public var resolver: any LegResolving
    public var maxAlternatives: Int

    public init(resolver: any LegResolving, maxAlternatives: Int = 5) {
        self.resolver = resolver
        self.maxAlternatives = maxAlternatives
    }

    /// - Parameter canDelayDeparture: slide leading drive/walk legs later to meet the first train. Turn off for a
    ///   rider already on the move, whose first leg really does start now.
    public func plan(_ template: TripTemplate, departingAt departure: Date, canDelayDeparture: Bool = true) async throws -> [Itinerary] {
        guard template.isPlannable else { throw PlanningError.notPlannable }

        var partials: [Itinerary] = [Itinerary(legs: [])]
        for segment in template.segments {
            var extended: [Itinerary] = []
            for partial in partials {
                try Task.checkCancellation()
                let readyAt = partial.legs.isEmpty ? departure : partial.arrival
                let options = try await resolver.options(from: segment.from, to: segment.to, mode: segment.mode, departingAt: readyAt)
                for option in options where option.departure >= readyAt.addingTimeInterval(-1) {
                    let leg = Leg(segmentIndex: segment.index, from: segment.from, to: segment.to, option: option)
                    extended.append(Itinerary(legs: partial.legs + [leg]))
                }
            }
            guard !extended.isEmpty else { throw PlanningError.noRoute(segmentIndex: segment.index) }
            partials = Self.prune(extended, keeping: maxAlternatives)
        }
        return canDelayDeparture ? partials.map(Self.departingAsLateAsPossible) : partials
    }

    /// Drops duplicates and itineraries that are no better than another on arrival, rides and walking.
    static func prune(_ itineraries: [Itinerary], keeping limit: Int) -> [Itinerary] {
        var seen = Set<String>()
        let unique = itineraries
            .sorted { ($0.arrival, $0.rideCount, $0.walkingMeters) < ($1.arrival, $1.rideCount, $1.walkingMeters) }
            .filter { seen.insert($0.id).inserted }

        var kept: [Itinerary] = []
        for candidate in unique {
            let dominated = kept.contains {
                $0.arrival <= candidate.arrival && $0.rideCount <= candidate.rideCount && $0.walkingMeters <= candidate.walkingMeters
            }
            if !dominated { kept.append(candidate) }
        }
        // Dominated options still make useful "next train" alternatives when there's room.
        for candidate in unique where kept.count < limit && !kept.contains(where: { $0.id == candidate.id }) {
            kept.append(candidate)
        }
        return Array(kept.sorted { $0.arrival < $1.arrival }.prefix(limit))
    }

    /// Slides leading drive/walk legs forward so waiting happens before leaving, not on the platform.
    static func departingAsLateAsPossible(_ itinerary: Itinerary) -> Itinerary {
        var legs = itinerary.legs
        guard let anchor = legs.firstIndex(where: { $0.mode == .transit }), anchor > 0 else {
            return itinerary
        }
        var deadline = legs[anchor].departure
        for index in stride(from: anchor - 1, through: 0, by: -1) {
            let shift = deadline.timeIntervalSince(legs[index].arrival)
            if shift > 0 {
                legs[index].option.departure.addTimeInterval(shift)
                legs[index].option.arrival.addTimeInterval(shift)
            }
            deadline = legs[index].departure
        }
        return Itinerary(legs: legs)
    }

    public static func tags(for itineraries: [Itinerary]) -> [Itinerary.ID: Set<ItineraryTag>] {
        guard itineraries.count > 1 else { return [:] }
        var tags: [Itinerary.ID: Set<ItineraryTag>] = [:]
        if let fastest = itineraries.min(by: { $0.arrival < $1.arrival }) {
            tags[fastest.id, default: []].insert(.fastest)
        }
        if Set(itineraries.map(\.rideCount)).count > 1, let fewest = itineraries.min(by: { $0.rideCount < $1.rideCount }) {
            tags[fewest.id, default: []].insert(.fewestTransfers)
        }
        if Set(itineraries.map(\.walkingMeters)).count > 1, let least = itineraries.min(by: { $0.walkingMeters < $1.walkingMeters }) {
            tags[least.id, default: []].insert(.leastWalking)
        }
        return tags
    }
}
