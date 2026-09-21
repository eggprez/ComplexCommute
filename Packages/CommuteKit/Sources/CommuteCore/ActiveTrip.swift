import Foundation

/// A trip being travelled: which leg the rider is on, and how to re-plan the rest from where they really are.
///
/// GPS is unreliable underground, so progress combines three signals: proximity to the next waypoint,
/// the clock (a train's departure time passing means "aboard" unless the rider says otherwise), and
/// explicit corrections from the rider.
///
/// Codable so a trip survives the app being closed under it: everything it knows is in here.
public struct ActiveTrip: Codable, Sendable {
    public enum Notice: Codable, Sendable {
        /// The followed plan stopped being possible (a missed or cancelled train) and was replaced.
        case planChanged(previousArrival: Date)
        /// The followed plan still works, but another gets there meaningfully sooner.
        case fasterOption(Itinerary)
    }

    /// What to plan next: a template for the part of the trip still ahead.
    public struct ReplanRequest: Sendable {
        public let template: TripTemplate
        public let departure: Date
        /// Segment of the original template that the request's first segment corresponds to.
        public let firstSegment: Int
        /// False once the rider is moving: sliding the first leg later would misstate when they arrive.
        public let canDelayDeparture: Bool
        /// The rider is at the first waypoint's station already, so the buffer for getting into it no longer applies.
        public let isWaitingAtOrigin: Bool
    }

    public let template: TripTemplate
    /// The followed itinerary, one leg per template segment.
    public private(set) var legs: [Leg]
    /// When the rider has to be there, if they said. Can be set or changed mid-trip.
    public var arriveBy: Date?
    public private(set) var currentSegment = 0
    /// Aboard the current transit leg (or, for a leg without ride details, under way on it).
    public private(set) var hasBoarded = false
    public private(set) var notice: Notice?

    private var startLocation: Coordinate?
    private var isUnderway = false
    /// When the trip ended, so the arrive-by verdict stops moving once it is settled.
    public private(set) var finishedAt: Date?
    /// Each leg as it stood when the rider set out on it: what the day gets measured against.
    /// Re-planning rewrites `legs`, so the promise has to be kept separately from what came of it.
    private var committed: [Int: Leg] = [:]
    /// Connections recorded but not yet stored.
    private var records: [ConnectionRecord] = []
    /// The record for the connection into the current leg, so "I missed this train" can correct it
    /// rather than counting the same platform twice.
    private var accessRecordID: UUID?
    /// When the rider was first seen at the platform of the leg they are waiting for.
    private var reachedPlatformAt: Date?
    /// The rider was already standing at the platform when this leg began, so their journey to it
    /// says nothing about how long that journey takes them.
    private var startedAtPlatform = false
    /// Set by `markMissed` until the next plan lands, so the clock doesn't immediately re-assume boarding.
    private var isAwaitingReplan = false

    /// An alternative has to save at least this much before it interrupts the rider.
    public static let worthwhileSaving: TimeInterval = 5 * 60
    /// Close enough to a boarding stop to count as being at it.
    static let platformRadius = 200.0

    public init?(template: TripTemplate, itinerary: Itinerary, arriveBy: Date? = nil) {
        guard template.isPlannable, itinerary.legs.count == template.segments.count else { return nil }
        self.template = template
        self.legs = itinerary.legs
        self.arriveBy = arriveBy
        commitPlan()
    }

    public var isFinished: Bool { currentSegment >= legs.count }
    public var currentLeg: Leg? { isFinished ? nil : legs[currentSegment] }
    public var remainingLegs: [Leg] { Array(legs[min(currentSegment, legs.count)...]) }
    public var arrival: Date { legs.last?.arrival ?? .distantPast }
    /// Moving along the current drive/walk leg, as opposed to waiting for the time to leave.
    public var isMoving: Bool { isUnderway }

    /// The first vehicle the drive or walk under way is meant to catch, and the time in hand on reaching its platform.
    public var connection: (ride: Ride, spare: TimeInterval)? {
        guard let leg = currentLeg, leg.mode != .transit,
              let next = remainingLegs.dropFirst().first, let ride = next.option.rides.first else { return nil }
        return (ride, ride.board.timeIntervalSince(leg.arrival) - ride.walkBefore)
    }

    /// The ride the rider is on or waiting for within the current transit leg.
    public func currentRide(at now: Date) -> Ride? {
        guard let leg = currentLeg else { return nil }
        return leg.option.rides.first { $0.alight > now } ?? leg.option.rides.last
    }

    // MARK: Progress

    /// Folds in a location fix and the clock. Returns true if the rider moved on to another leg.
    @discardableResult
    public mutating func update(location: Coordinate?, now: Date) -> Bool {
        let segmentBefore = currentSegment
        let isFirstFix = startLocation == nil
        if let location {
            if startLocation == nil { startLocation = location }
            if let startLocation, location.distance(to: startLocation) > 150 { isUnderway = true }

            while let leg = currentLeg, location.distance(to: leg.to.coordinate) <= arrivalRadius(for: leg, now: now) {
                advance(now: now)
            }
        }
        if let location, let leg = currentLeg, leg.mode == .transit, !hasBoarded, reachedPlatformAt == nil,
           let platform = leg.option.rides.first?.stops.first?.station,
           location.distance(to: platform.coordinate) <= Self.platformRadius {
            if isFirstFix {
                startedAtPlatform = true
            } else {
                reachedPlatformAt = now
            }
        }
        if let leg = currentLeg, leg.mode == .transit, !hasBoarded, !isAwaitingReplan {
            let boardTime = leg.option.rides.first?.board ?? leg.departure
            if now >= boardTime.addingTimeInterval(30) {
                hasBoarded = true
                recordBoarding(now: now)
            }
        }
        return currentSegment != segmentBefore
    }

    /// The rider says they have reached the next waypoint.
    public mutating func markArrived(now: Date = .now) {
        guard !isFinished else { return }
        advance(now: now)
    }

    /// The rider says the train left without them; the next plan starts again from this station.
    public mutating func markMissed(now: Date = .now) {
        recordMiss(now: now)
        hasBoarded = false
        isAwaitingReplan = true
    }

    public mutating func dismissNotice() {
        notice = nil
    }

    private mutating func advance(now: Date) {
        accessRecordID = nil
        reachedPlatformAt = nil
        startedAtPlatform = false
        recordConnections(leaving: currentSegment, now: now)
        currentSegment += 1
        hasBoarded = false
        isUnderway = true
        if isFinished {
            finishedAt = now
        } else {
            commitPlan()
        }
    }

    /// Takes the plan the rider is setting out on as the promise the rest of this leg is judged against.
    private mutating func commitPlan() {
        for leg in legs[min(currentSegment, legs.count)...] {
            committed[leg.segmentIndex] = leg
        }
    }

    private func arrivalRadius(for leg: Leg, now: Date) -> Double {
        switch leg.mode {
        case .drive:
            return 250 // parking is rarely at the pin
        case .walk:
            return 120
        case .transit:
            // Surfacing from a big station can put the first fix blocks from its pin, so be generous once the
            // train is due in. Before that, stay strict: the next station may simply be close by.
            return hasBoarded && now >= leg.arrival.addingTimeInterval(-90) ? 600 : 200
        }
    }

    // MARK: Re-planning

    /// The part of the trip that can still change, or nil when there is nothing left to decide.
    public func replanRequest(location: Coordinate?, now: Date) -> ReplanRequest? {
        guard let leg = currentLeg else { return nil }
        let waypoints = template.waypoints
        let modes = template.modes

        if leg.mode == .transit {
            if hasBoarded {
                // Aboard: this leg is fixed. Everything after it starts when it arrives.
                let next = currentSegment + 1
                guard next < legs.count else { return nil }
                return ReplanRequest(template: TripTemplate(waypoints: Array(waypoints[next...]), modes: Array(modes[next...])),
                                     departure: max(now, leg.arrival), firstSegment: next, canDelayDeparture: false, isWaitingAtOrigin: false)
            }
            // Waiting at the station: what can be caught from here now? Having got there, by an earlier leg or
            // by starting the trip on its doorstep, the rider no longer needs time in hand for getting in.
            var ahead = Array(waypoints[currentSegment...])
            // Standing where the leg starts only counts when that place is a stop. A rider at home is
            // not on a platform, however exactly the trip starts at their door.
            var isAtStation = currentSegment > 0 || (leg.from.isStop
                && location.map { $0.distance(to: leg.from.coordinate) <= Self.platformRadius } ?? false)
            if !isAtStation, let location, let platform = leg.option.rides.first?.stops.first?.station,
               location.distance(to: platform.coordinate) <= Self.platformRadius {
                // Already on the platform, ahead of where the leg said it would start: plan from the
                // stop itself, or every re-plan would keep allowing for a walk that is already done.
                ahead[0] = Waypoint(name: platform.name, coordinate: platform.coordinate,
                                    kind: .stop(feedID: platform.feedID, stopID: platform.stopID))
                isAtStation = true
            }
            return ReplanRequest(template: TripTemplate(waypoints: ahead, modes: Array(modes[currentSegment...])),
                                 departure: now, firstSegment: currentSegment, canDelayDeparture: false, isWaitingAtOrigin: isAtStation)
        }

        // Driving or walking: measure from where the rider actually is.
        var remaining = Array(waypoints[currentSegment...])
        if let location {
            remaining[0] = .currentLocation(location)
        }
        return ReplanRequest(template: TripTemplate(waypoints: remaining, modes: Array(modes[currentSegment...])),
                             departure: now, firstSegment: currentSegment, canDelayDeparture: !isUnderway, isWaitingAtOrigin: false)
    }

    /// Takes fresh plans for `request`. Keeps following the same vehicles when that is still possible (updating
    /// their times), and otherwise switches to the best new plan and says so.
    public mutating func apply(_ itineraries: [Itinerary], for request: ReplanRequest) {
        // A request is stale if the rider moved on while it was being planned.
        guard !itineraries.isEmpty, request.firstSegment >= currentSegment, request.firstSegment < legs.count else { return }
        isAwaitingReplan = false

        let followedID = Itinerary(legs: Array(legs[request.firstSegment...])).id
        let best = itineraries.min { $0.arrival < $1.arrival } ?? itineraries[0]

        if let same = itineraries.first(where: { $0.id == followedID }) {
            replaceLegs(from: request.firstSegment, with: same)
            if best.id != followedID, same.arrival.timeIntervalSince(best.arrival) >= Self.worthwhileSaving {
                notice = .fasterOption(Self.reindexed(best, from: request.firstSegment))
            } else if case .fasterOption = notice {
                notice = nil
            }
        } else {
            let previousArrival = arrival
            replaceLegs(from: request.firstSegment, with: best)
            notice = .planChanged(previousArrival: previousArrival)
        }
    }

    /// Switches to an alternative that a `.fasterOption` notice offered.
    public mutating func follow(_ itinerary: Itinerary) {
        guard let first = itinerary.legs.first?.segmentIndex, first >= currentSegment,
              first + itinerary.legs.count == legs.count else { return }
        legs.replaceSubrange(first..., with: itinerary.legs)
        notice = nil
    }

    private mutating func replaceLegs(from firstSegment: Int, with itinerary: Itinerary) {
        guard firstSegment + itinerary.legs.count == legs.count else { return }
        legs.replaceSubrange(firstSegment..., with: Self.reindexed(itinerary, from: firstSegment).legs)
    }

    /// Plans for a truncated template number their legs from zero; put them back on the original numbering.
    private static func reindexed(_ itinerary: Itinerary, from firstSegment: Int) -> Itinerary {
        Itinerary(legs: itinerary.legs.map { leg in
            var leg = leg
            leg.segmentIndex += firstSegment
            return leg
        })
    }

    // MARK: Arrive by

    /// How the trip is doing against the time the rider has to be there, or nil if they never said.
    public func arriveByProgress(now: Date) -> ArriveByProgress? {
        guard let arriveBy else { return nil }
        if let finishedAt {
            return ArriveByProgress(target: arriveBy, projectedArrival: finishedAt, isFinal: true)
        }
        // An arrival already in the past means the plan has stopped moving; the clock hasn't.
        return ArriveByProgress(target: arriveBy, projectedArrival: max(arrival, now))
    }

    // MARK: Learning the buffer

    /// Hands over the connections recorded since the last call, for storing.
    public mutating func drainRecords() -> [ConnectionRecord] {
        defer { records = [] }
        return records
    }

    /// Two vehicles are the same one if they are the same service leaving the same stop at the same time.
    private static func isSameRide(_ one: Ride, _ other: Ride) -> Bool {
        one.routeName == other.routeName && one.boardStopName == other.boardStopName && one.scheduledBoard == other.scheduledBoard
    }

    /// When the plan had the rider on the platform: the leg's start plus the walk into the station,
    /// which by construction leaves exactly the buffer the trip was planned with.
    private func plannedPlatformArrival(for leg: Leg) -> Date? {
        leg.option.rides.first.map { leg.departure.addingTimeInterval($0.walkBefore) }
    }

    /// A trip that starts with a ride has no leg boundary at the station, so the connection is timed
    /// from the rider turning up on the platform to the train pulling out.
    private mutating func recordBoarding(now: Date) {
        guard accessRecordID == nil, !startedAtPlatform, let reachedPlatformAt,
              let promised = committed[currentSegment], let aimedFor = promised.option.rides.first,
              let plannedArrival = plannedPlatformArrival(for: promised) else { return }

        let live = currentLeg?.option.rides.first
        let departed = live.map { Self.isSameRide($0, aimedFor) ? $0.board : aimedFor.board } ?? aimedFor.board
        let record = ConnectionRecord(
            date: now,
            approach: .walk,
            stationID: aimedFor.stops.first?.station.id,
            stationName: aimedFor.boardStopName,
            routeName: aimedFor.routeName,
            plannedArrival: plannedArrival,
            actualArrival: reachedPlatformAt,
            plannedDeparture: aimedFor.board,
            actualDeparture: departed,
            isObserved: true,
            wasMissed: reachedPlatformAt > departed
        )
        accessRecordID = record.id
        records.append(record)
    }

    private mutating func recordConnections(leaving segment: Int, now: Date) {
        guard segment < legs.count else { return }
        recordChanges(within: legs[segment], planned: committed[segment], now: now)
        recordAccess(reaching: segment + 1, from: segment, now: now)
    }

    /// Reaching a platform by road or on foot: the one connection the app can really time, from the
    /// moment the rider got there to the moment their vehicle left.
    private mutating func recordAccess(reaching segment: Int, from previous: Int, now: Date) {
        guard segment < legs.count, legs[segment].mode == .transit,
              let arriving = committed[previous], arriving.mode != .transit,
              let aimedFor = committed[segment]?.option.rides.first else { return }

        // Realtime may have moved the very train being caught; the rider gets the benefit of that.
        let live = legs[segment].option.rides.first
        let departed = live.map { Self.isSameRide($0, aimedFor) ? $0.board : aimedFor.board } ?? aimedFor.board

        let record = ConnectionRecord(
            date: now,
            approach: arriving.mode == .drive ? .drive : .walk,
            stationID: aimedFor.stops.first?.station.id,
            stationName: aimedFor.boardStopName,
            routeName: aimedFor.routeName,
            plannedArrival: arriving.arrival,
            actualArrival: now,
            plannedDeparture: aimedFor.board,
            actualDeparture: departed,
            isObserved: true,
            wasMissed: now > departed
        )
        accessRecordID = record.id
        records.append(record)
    }

    /// Changes of vehicle inside a transit leg happen underground, where there is nothing to watch, so
    /// they are only worth recording where realtime says what actually became of them.
    private mutating func recordChanges(within leg: Leg, planned: Leg?, now: Date) {
        let rides = leg.option.rides
        guard rides.count > 1, let promised = planned?.option.rides else { return }

        for index in 1..<rides.count {
            let (off, onto) = (rides[index - 1], rides[index])
            guard off.isRealtime || onto.isRealtime,
                  let was = promised.firstIndex(where: { Self.isSameRide($0, off) }),
                  was + 1 < promised.count, Self.isSameRide(promised[was + 1], onto) else { continue }

            // The platform is reached when the first vehicle lets the rider off and they have walked across.
            let plannedArrival = promised[was].alight.addingTimeInterval(promised[was + 1].walkBefore)
            let actualArrival = off.alight.addingTimeInterval(onto.walkBefore)
            records.append(ConnectionRecord(
                date: now,
                approach: .change,
                stationID: onto.stops.first?.station.id,
                stationName: onto.boardStopName,
                routeName: onto.routeName,
                plannedArrival: plannedArrival,
                actualArrival: actualArrival,
                plannedDeparture: promised[was + 1].board,
                actualDeparture: onto.board,
                isObserved: false,
                wasMissed: actualArrival > onto.board
            ))
        }
    }

    /// "I missed this train" is the clearest signal there is that the buffer was not enough: whatever
    /// the plan had in hand, all of it went, and it still wasn't enough.
    private mutating func recordMiss(now: Date) {
        guard let leg = currentLeg, leg.mode == .transit,
              let missed = committed[currentSegment]?.option.rides.first ?? leg.option.rides.first else { return }
        let arriving = currentSegment > 0 ? committed[currentSegment - 1] : nil
        let record = ConnectionRecord(
            // Correcting the connection already recorded for this platform, where there is one.
            id: accessRecordID ?? UUID(),
            date: now,
            approach: arriving.map { $0.mode == .drive ? .drive : .walk } ?? .change,
            stationID: missed.stops.first?.station.id,
            stationName: missed.boardStopName,
            routeName: missed.routeName,
            plannedArrival: arriving?.arrival ?? committed[currentSegment].flatMap(plannedPlatformArrival) ?? missed.board,
            // Not ready until it had gone: no time in hand at all, and the whole planned buffer used up.
            actualArrival: missed.board,
            plannedDeparture: missed.board,
            actualDeparture: missed.board,
            isObserved: true,
            wasMissed: true
        )
        records.removeAll { $0.id == record.id }
        records.append(record)
    }
}
