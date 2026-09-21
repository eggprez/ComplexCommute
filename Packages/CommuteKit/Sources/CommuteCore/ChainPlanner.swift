import Foundation

/// Produces the ways to cover one segment when leaving `from` no earlier than `departingAt`.
public protocol LegResolving: Sendable {
    /// - Parameter isWaitingAtOrigin: the traveller is already standing at `from`, so no time needs allowing for
    ///   getting into the station; whatever leaves next can be caught.
    func options(from: Waypoint, to: Waypoint, mode: TravelMode, departingAt: Date, isWaitingAtOrigin: Bool) async throws -> [LegOption]
}

public enum PlanningError: Error, Equatable {
    case notPlannable
    case noRoute(segmentIndex: Int)
}

/// Chains per-segment options into whole-trip itineraries, left to right from the departure time.
public struct ChainPlanner: Sendable {
    public var resolver: any LegResolving
    public var maxAlternatives: Int

    /// Plans run per arrive-by search. Each is a round of resolver calls, so this is the cost ceiling.
    static let arriveByPasses = 4
    /// Close enough to the target to stop hunting for a later departure.
    static let arriveBySlack: TimeInterval = 5 * 60
    /// Aimed at just before the ideal departure rather than exactly at it: a probe that lands a minute
    /// late misses the same train over and over, where one that lands early catches it.
    static let arriveByMargin: TimeInterval = 2 * 60

    public init(resolver: any LegResolving, maxAlternatives: Int = 5) {
        self.resolver = resolver
        self.maxAlternatives = maxAlternatives
    }

    /// - Parameter canDelayDeparture: slide leading drive/walk legs later to meet the first train. Turn off for a
    ///   rider already on the move, whose first leg really does start now.
    /// - Parameter isWaitingAtOrigin: the rider is already at the first waypoint, a station, waiting for a vehicle.
    public func plan(_ template: TripTemplate, departingAt departure: Date, canDelayDeparture: Bool = true,
                     isWaitingAtOrigin: Bool = false) async throws -> [Itinerary] {
        guard template.isPlannable else { throw PlanningError.notPlannable }

        var partials: [Itinerary] = [Itinerary(legs: [])]
        for segment in template.segments {
            var extended: [Itinerary] = []
            for partial in partials {
                try Task.checkCancellation()
                let readyAt = partial.legs.isEmpty ? departure : partial.arrival
                let options = try await resolver.options(from: segment.from, to: segment.to, mode: segment.mode, departingAt: readyAt,
                                                         isWaitingAtOrigin: isWaitingAtOrigin && segment.index == 0)
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

    /// Plans for a rider who has to be somewhere by `target`: leave as late as the trip allows.
    ///
    /// The router works forwards, so this hunts for the departure rather than reversing the search.
    /// Each pass moves by the time it was out by — the spare time left over, or the amount it overshot —
    /// and bisects towards the last departure known to work when stepping back isn't reaching an earlier
    /// vehicle. That closes on the last one that makes it within a handful of passes.
    ///
    /// - Returns: the options that make it, latest departure first, then those that don't, least late
    ///   first. Empty only when nothing can be planned at all.
    public func plan(_ template: TripTemplate, arrivingBy target: Date, notBefore earliest: Date = .now) async throws -> [Itinerary] {
        var pool: [Itinerary] = []
        var probe = earliest
        // The latest departure known to make it.
        var latest = earliest
        var hasOvershot = false

        for _ in 0..<Self.arriveByPasses {
            let planned = try await plan(template, departingAt: probe)
            pool += planned
            guard !planned.isEmpty else { break }

            if let best = planned.filter({ $0.arrival <= target }).max(by: { $0.departure < $1.departure }) {
                latest = max(latest, best.departure)
                hasOvershot = false
                let spare = target.timeIntervalSince(best.arrival)
                guard spare > Self.arriveBySlack else { break }
                probe = best.departure.addingTimeInterval(spare - Self.arriveByMargin)
            } else if hasOvershot {
                // Stepping back politely isn't reaching an earlier vehicle: halve the gap to the last
                // departure known to work instead.
                probe = latest.addingTimeInterval(probe.timeIntervalSince(latest) / 2)
            } else {
                // Left too late: come back by what the soonest arrival overshot, and then some, so the
                // next try isn't left waiting for the very same vehicle.
                hasOvershot = true
                let overshoot = planned.map(\.arrival).min().map { $0.timeIntervalSince(target) } ?? 0
                probe = probe.addingTimeInterval(-max(overshoot + Self.arriveByMargin, Self.arriveByMargin))
            }
            guard probe > latest, probe > earliest else { break }
        }

        var seen = Set<String>()
        let unique = pool.filter { seen.insert("\($0.id)@\($0.departure.timeIntervalSince1970)").inserted }
        let makesIt = unique.filter { $0.arrival <= target }.sorted { $0.departure > $1.departure }
        let doesNot = unique.filter { $0.arrival > target }.sorted { $0.arrival < $1.arrival }
        return Array((makesIt + doesNot).prefix(maxAlternatives))
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
