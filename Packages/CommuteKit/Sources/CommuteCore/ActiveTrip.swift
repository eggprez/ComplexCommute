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
        /// Aboard a ride with more changes to come in the same leg: the rides so far are fixed, and the request plans
        /// the rest of that leg from where the current one lets the rider off. They go back in front of whatever comes back.
        public var keptRides: [Ride] = []
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
    /// Why the app thinks the rider is on the ride it shows them on, once aboard.
    public private(set) var boardedBy: BoardingEvidence?
    /// A train the rider's location fits, but not clearly enough to act on without asking them.
    public private(set) var suggestedTrain: TrainSuggestion?
    /// Trains the rider said they are not on, so the location doesn't keep suggesting them.
    /// Optional so a trip saved by an earlier version still loads.
    private var rejectedTrains: Set<TripRef>?
    /// What the motion sensor and the station geofences have said. Optional for the same reason.
    private var sensing: Sensing?

    private struct Sensing: Codable {
        var motion: Motion?
        /// The motion sensor saw this leg being driven, so walking afterwards means the car is parked.
        var sawDriving = false
        /// Inside the geofence around the platform the next train leaves from.
        var isInsideStation = false
        /// Something says the rider is moving on a train, but not which one: ask them.
        var isAskingAboutTrain = false
    }

    private var sense: Sensing {
        get { sensing ?? Sensing() }
        set { sensing = newValue }
    }

    /// Movement is taken as boarding the planned train only this close to when it was due to leave.
    static let movementBoardingWindow: TimeInterval = 3 * 60
    /// Walking after driving this close to the station means the car is parked. A park-and-ride lot can be big.
    static let parkedRadius = 1_000.0
    /// Without having seen the drive, walking only counts this close: it could be a stop on the way.
    static let unseenParkedRadius = 400.0

    /// An alternative has to save at least this much before it interrupts the rider.
    public static let worthwhileSaving: TimeInterval = 5 * 60
    /// Close enough to a boarding stop to count as being at it.
    static let platformRadius = 200.0
    /// Until the rider sets out, re-plans look this far ahead of the followed plan for an earlier way to go.
    /// Beyond it they plan from the trip's own time, not the clock: a trip started the night before is
    /// about tomorrow morning's trains, not whatever runs at midnight.
    static let replanLookahead: TimeInterval = 10 * 60
    /// This close to the time to leave, a trip that has been started is taken to be under way.
    public static let departureWindow: TimeInterval = 20 * 60
    /// Earlier than that, the rider has to get this far (0.15 mi) from where they started before the trip
    /// counts as begun: a stroll to the mailbox an hour early isn't setting out.
    public static let earlyDepartureRadius = 241.0

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
    /// Still waiting for the time to leave a drive or walk, so "I'm leaving now" means something.
    public var canMarkLeaving: Bool { !isUnderway && currentLeg.map { $0.mode != .transit } ?? false }

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
            if let startLocation, location.distance(to: startLocation) > Self.earlyDepartureRadius { isUnderway = true }

            while let leg = currentLeg, hasReachedEnd(of: leg, at: location, now: now) {
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
        if !isUnderway, let leg = currentLeg, leg.mode != .transit,
           leg.departure.timeIntervalSince(now) <= Self.departureWindow {
            isUnderway = true
        }
        if let leg = currentLeg, leg.mode == .transit, !hasBoarded, !isAwaitingReplan {
            let boardTime = leg.option.rides.first?.board ?? leg.departure
            if now >= boardTime.addingTimeInterval(30) {
                hasBoarded = true
                boardedBy = .schedule
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

    /// The rider says they are setting out now, ahead of the time the plan had them leaving.
    public mutating func markLeaving() {
        guard canMarkLeaving else { return }
        isUnderway = true
    }

    /// The rider says the train left without them; the next plan starts again from this station.
    public mutating func markMissed(now: Date = .now) {
        recordMiss(now: now)
        hasBoarded = false
        boardedBy = nil
        suggestedTrain = nil
        sense.isAskingAboutTrain = false
        isAwaitingReplan = true
    }

    public mutating func dismissNotice() {
        notice = nil
    }

    /// - Parameter recording: false when catching up on a leg that ended unseen, whose timing nobody knows.
    private mutating func advance(now: Date, recording: Bool = true) {
        accessRecordID = nil
        reachedPlatformAt = nil
        startedAtPlatform = false
        if recording { recordConnections(leaving: currentSegment, now: now) }
        currentSegment += 1
        hasBoarded = false
        boardedBy = nil
        suggestedTrain = nil
        let motion = sense.motion
        sensing = Sensing(motion: motion)
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

    /// At the leg's end, or, for a drive or walk that leads to a train, on the platform that train leaves from:
    /// a station's pin, or the car park, can be a long way from where the rider actually ends up.
    private func hasReachedEnd(of leg: Leg, at location: Coordinate, now: Date) -> Bool {
        if location.distance(to: leg.to.coordinate) <= arrivalRadius(for: leg, now: now) { return true }
        guard leg.mode != .transit, leg.segmentIndex + 1 < legs.count, legs[leg.segmentIndex + 1].mode == .transit,
              let platform = legs[leg.segmentIndex + 1].option.rides.first?.stops.first?.station else { return false }
        return location.distance(to: platform.coordinate) <= Self.platformRadius
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
        let notYetDue = max(now, leg.departure.addingTimeInterval(-Self.replanLookahead))

        if leg.mode == .transit {
            if hasBoarded {
                let rides = leg.option.rides
                if let ride = currentRide(at: now), let index = rides.firstIndex(of: ride), index + 1 < rides.count,
                   let exit = ride.stops.last?.station {
                    // Aboard, with changes still to make: what's ridden so far is fixed, but the rest of the leg is
                    // worth another look from where this train really gets in.
                    let exitStop = Waypoint(name: exit.name, coordinate: exit.coordinate, kind: .stop(feedID: exit.feedID, stopID: exit.stopID))
                    return ReplanRequest(template: TripTemplate(waypoints: [exitStop] + waypoints[(currentSegment + 1)...],
                                                                modes: Array(modes[currentSegment...]), excludedFeedIDs: template.excludedFeedIDs),
                                         departure: max(now, ride.alight), firstSegment: currentSegment, canDelayDeparture: false,
                                         isWaitingAtOrigin: false, keptRides: Array(rides[...index]))
                }
                // Aboard the last ride of the leg: it is fixed. Everything after it starts when it arrives.
                let next = currentSegment + 1
                guard next < legs.count else { return nil }
                return ReplanRequest(template: template.suffix(from: next),
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
            return ReplanRequest(template: TripTemplate(waypoints: ahead, modes: Array(modes[currentSegment...]),
                                                           excludedFeedIDs: template.excludedFeedIDs),
                                 departure: notYetDue, firstSegment: currentSegment, canDelayDeparture: false, isWaitingAtOrigin: isAtStation)
        }

        // Driving or walking: measure from where the rider actually is.
        var remaining = Array(waypoints[currentSegment...])
        if let location {
            remaining[0] = .currentLocation(location)
        }
        return ReplanRequest(template: TripTemplate(waypoints: remaining, modes: Array(modes[currentSegment...]),
                                                       excludedFeedIDs: template.excludedFeedIDs),
                             departure: isUnderway ? now : notYetDue, firstSegment: currentSegment, canDelayDeparture: !isUnderway, isWaitingAtOrigin: false)
    }

    /// Takes fresh plans for `request`. Keeps following the same vehicles when that is still possible (updating
    /// their times), and otherwise switches to the best new plan and says so.
    public mutating func apply(_ itineraries: [Itinerary], for request: ReplanRequest) {
        // A request is stale if the rider moved on while it was being planned.
        guard !itineraries.isEmpty, request.firstSegment >= currentSegment, request.firstSegment < legs.count else { return }
        var itineraries = itineraries
        if !request.keptRides.isEmpty {
            // Only still good if the rider is on the same rides the request was made for.
            let leg = legs[request.firstSegment]
            guard request.firstSegment == currentSegment, hasBoarded,
                  leg.option.rides.count >= request.keptRides.count,
                  zip(leg.option.rides, request.keptRides).allSatisfy({ Self.isSameRide($0, $1) }) else { return }
            itineraries = itineraries.compactMap { Self.merging($0, onto: Array(leg.option.rides.prefix(request.keptRides.count)), of: leg) }
            guard !itineraries.isEmpty else { return }
        }
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

    /// Puts rides already taken back in front of a plan for the rest of their leg.
    private static func merging(_ itinerary: Itinerary, onto kept: [Ride], of leg: Leg) -> Itinerary? {
        guard var first = itinerary.legs.first, first.mode == .transit else { return nil }
        var option = first.option
        option.rides = kept + option.rides
        option.departure = leg.departure
        option.walkingMeters += leg.option.walkingMeters
        option.geometry = [leg.from.coordinate] + kept.flatMap { $0.stops.map(\.station.coordinate) } + option.geometry.dropFirst()
        option.alerts = leg.option.alerts + option.alerts.filter { alert in !leg.option.alerts.contains { $0.id == alert.id } }
        first.option = option
        first.from = leg.from
        var legs = itinerary.legs
        legs[0] = first
        return Itinerary(legs: legs)
    }

    /// Plans for a truncated template number their legs from zero; put them back on the original numbering.
    private static func reindexed(_ itinerary: Itinerary, from firstSegment: Int) -> Itinerary {
        Itinerary(legs: itinerary.legs.map { leg in
            var leg = leg
            leg.segmentIndex += firstSegment
            return leg
        })
    }

    // MARK: Which train

    /// The rides worth matching the rider's location against: the rest of the transit leg under way, or the
    /// one coming up after a drive or walk (in case that ended without the app seeing it end).
    public func ridesToWatch(at now: Date) -> (segment: Int, rides: [WatchedRide])? {
        guard let leg = currentLeg else { return nil }
        let segment: Int
        let rides: [Ride]
        var from = 0
        if leg.mode == .transit {
            segment = currentSegment
            rides = leg.option.rides
            // The rider has said which train they're on; only later changes are still open.
            if boardedBy == .rider { from = ridingIndex(at: now) + 1 }
        } else {
            segment = currentSegment + 1
            guard segment < legs.count, legs[segment].mode == .transit else { return nil }
            rides = legs[segment].option.rides
        }
        let watched = rides.enumerated().filter { $0.offset >= from && $0.element.trip != nil }
            .map { WatchedRide(index: $0.offset, ride: $0.element) }
        return watched.isEmpty ? nil : (segment: segment, rides: watched)
    }

    /// Where in the current leg the rider is, ride by ride.
    public func ridingIndex(at now: Date) -> Int {
        guard let leg = currentLeg, let ride = currentRide(at: now) else { return 0 }
        return leg.option.rides.firstIndex(of: ride) ?? 0
    }

    /// Takes a train the location matched: a clear match is acted on, an unclear one is put to the rider.
    public mutating func apply(_ match: TrainMatch, segment: Int, now: Date) {
        guard let trip = match.ride.trip, !(rejectedTrains ?? []).contains(trip), segment >= currentSegment, segment < legs.count else { return }
        let rides = legs[segment].option.rides
        guard match.rideIndex < rides.count else { return }
        if segment == currentSegment, hasBoarded, rides[match.rideIndex].trip == trip, ridingIndex(at: now) == match.rideIndex {
            // Already shown on that very train; the location just makes it surer.
            if boardedBy != .rider, match.isConfident { boardedBy = .location }
            if suggestedTrain?.ride.trip == trip { suggestedTrain = nil }
            return
        }
        if segment == currentSegment, boardedBy == .rider, match.rideIndex <= ridingIndex(at: now) { return }
        if match.isConfident {
            board(match.ride, segment: segment, rideIndex: match.rideIndex, evidence: .location, now: now)
        } else {
            suggestedTrain = TrainSuggestion(ride: match.ride, segment: segment, rideIndex: match.rideIndex)
        }
    }

    /// The rider says they're on the suggested train.
    public mutating func acceptSuggestedTrain(now: Date = .now) {
        guard let suggestion = suggestedTrain else { return }
        board(suggestion.ride, segment: suggestion.segment, rideIndex: suggestion.rideIndex, evidence: .rider, now: now)
    }

    /// The rider says they're not on the suggested train.
    public mutating func rejectSuggestedTrain() {
        guard let trip = suggestedTrain?.ride.trip else { return }
        rejectedTrains = (rejectedTrains ?? []).union([trip])
        suggestedTrain = nil
    }

    /// Puts the rider on `ride` in place of ride `rideIndex` of leg `segment`, moving the trip on to that leg if it
    /// hadn't got there: a drive to the station that ended without the app seeing it end is simply over.
    public mutating func board(_ ride: Ride, segment: Int, rideIndex: Int, evidence: BoardingEvidence, now: Date = .now) {
        guard segment >= currentSegment, segment < legs.count, legs[segment].mode == .transit,
              rideIndex < legs[segment].option.rides.count else { return }
        let isCatchingUp = segment > currentSegment
        while currentSegment < segment { advance(now: now, recording: false) }

        var leg = legs[segment]
        let replaced = leg.option.rides[rideIndex]
        var ride = ride
        ride.walkBefore = replaced.walkBefore
        ride.freeTransfer = ride.freeTransfer ?? replaced.freeTransfer
        if ride.path.count < 2 { ride.path = replaced.path }
        var rides = leg.option.rides
        rides[rideIndex] = ride
        // Rides before this one are done with.
        rides.removeFirst(rideIndex)
        if rideIndex > 0, let board = ride.stops.first?.station {
            leg.from = Waypoint(name: board.name, coordinate: board.coordinate, kind: .stop(feedID: board.feedID, stopID: board.stopID))
            leg.option.departure = ride.board.addingTimeInterval(-ride.walkBefore)
        } else {
            leg.option.departure = min(leg.option.departure, ride.board.addingTimeInterval(-ride.walkBefore))
        }
        leg.option.rides = rides
        if rides.count == 1 {
            leg.option.arrival = ride.alight.addingTimeInterval(leg.option.walkAfter)
        }
        legs[segment] = leg

        let wasBoarded = hasBoarded
        hasBoarded = true
        boardedBy = evidence
        isAwaitingReplan = false
        suggestedTrain = nil
        sense.isAskingAboutTrain = false
        if let trip = ride.trip { rejectedTrains?.remove(trip) }
        if !wasBoarded, !isCatchingUp { recordBoarding(now: now) }
    }

    // MARK: Motion and geofences

    /// Something says the rider is on a train, but not which one.
    public var isAskingAboutTrain: Bool { sense.isAskingAboutTrain }

    /// The rider says they're on the train: the one they're waiting for, or the one the drive or walk is for.
    public mutating func markAboard(now: Date = .now) {
        guard let leg = currentLeg else { return }
        if leg.mode == .transit {
            let index = ridingIndex(at: now)
            guard index < leg.option.rides.count else { return }
            board(leg.option.rides[index], segment: currentSegment, rideIndex: index, evidence: .riderAboard, now: now)
        } else if currentSegment + 1 < legs.count, let ride = legs[currentSegment + 1].option.rides.first {
            board(ride, segment: currentSegment + 1, rideIndex: 0, evidence: .riderAboard, now: now)
        }
    }

    /// The rider says they're not on a train after all.
    public mutating func dismissTrainQuestion() {
        sense.isAskingAboutTrain = false
    }

    /// Folds in what the motion sensor says. Returns true if the rider moved on to another leg.
    ///
    /// Driving then walking near the station: parked. Standing at the station then moving like a vehicle:
    /// on the train. Riding then walking at the far end: off it.
    @discardableResult
    public mutating func update(motion: Motion, location: Coordinate?, now: Date) -> Bool {
        let before = currentSegment
        let previous = sense.motion
        sense.motion = motion
        guard let leg = currentLeg else { return false }

        switch leg.mode {
        case .drive:
            if motion == .automotive { sense.sawDriving = true }
            guard motion.isOnFoot, currentSegment + 1 < legs.count, legs[currentSegment + 1].mode == .transit else { break }
            let radius = sense.sawDriving ? Self.parkedRadius : Self.unseenParkedRadius
            let isNear = location.map { isNearStation(after: leg, $0, within: radius) }
                ?? (sense.sawDriving && now >= leg.arrival.addingTimeInterval(-10 * 60))
            if isNear { advance(now: now) }
        case .walk:
            // Walked to the station and now moving like a vehicle from it: the walk is over and the train under way.
            guard motion == .automotive, currentSegment + 1 < legs.count, legs[currentSegment + 1].mode == .transit,
                  sense.isInsideStation || location.map({ isNearStation(after: leg, $0, within: Self.unseenParkedRadius) }) ?? false else { break }
            advance(now: now)
            boardByMovement(now: now)
        case .transit:
            if motion == .automotive, !hasBoarded || boardedBy == .schedule, wasAtStation(location: location) {
                boardByMovement(now: now)
            } else if motion.isOnFoot, previous == .automotive, hasBoarded, now >= leg.arrival.addingTimeInterval(-5 * 60),
                      location.map({ $0.distance(to: leg.to.coordinate) <= 600 }) ?? true {
                advance(now: now)
            }
        }
        return currentSegment != before
    }

    /// Geofences for where the trip is now. Crossing one is reported to `crossed(_:entered:now:)`.
    public var placesToWatch: [WatchedPlace] {
        guard let leg = currentLeg else { return [] }
        var places: [WatchedPlace] = []
        if leg.mode != .transit, currentSegment + 1 < legs.count, let platform = legs[currentSegment + 1].option.rides.first?.stops.first?.station {
            places.append(WatchedPlace(id: "board.\(currentSegment + 1)", center: platform.coordinate, radius: 150))
        }
        if leg.mode == .transit, !hasBoarded || boardedBy == .schedule, let platform = currentRide(at: .now)?.stops.first?.station {
            places.append(WatchedPlace(id: "board.\(currentSegment)", center: platform.coordinate, radius: 150))
        }
        places.append(WatchedPlace(id: "end.\(currentSegment)", center: leg.to.coordinate, radius: leg.mode == .drive ? 250 : 200))
        return places
    }

    /// A geofence from `placesToWatch` was crossed. Returns true if the rider moved on to another leg.
    @discardableResult
    public mutating func crossed(_ id: String, entered: Bool, now: Date) -> Bool {
        let before = currentSegment
        let parts = id.split(separator: ".")
        guard parts.count == 2, let segment = Int(parts[1]), let leg = currentLeg else { return false }

        switch (parts[0], entered) {
        case ("end", true) where segment == currentSegment:
            // Passing through the exit station's fence on a train isn't arriving: only once it's due in.
            if leg.mode != .transit || (hasBoarded && now >= leg.arrival.addingTimeInterval(-5 * 60)) {
                advance(now: now)
            }
        case ("board", true):
            if segment == currentSegment + 1, leg.mode != .transit {
                advance(now: now)
            }
            if segment == currentSegment, currentLeg?.mode == .transit {
                sense.isInsideStation = true
                if !hasBoarded, reachedPlatformAt == nil, !startedAtPlatform { reachedPlatformAt = now }
            }
        case ("board", false) where segment == currentSegment && leg.mode == .transit:
            guard sense.isInsideStation else { break }
            sense.isInsideStation = false
            // Leaving the station on foot is leaving it; leaving it at vehicle speed is the train pulling out.
            if sense.motion == .automotive { boardByMovement(now: now) }
        default:
            break
        }
        return currentSegment != before
    }

    private func isNearStation(after leg: Leg, _ location: Coordinate, within radius: Double) -> Bool {
        if location.distance(to: leg.to.coordinate) <= radius { return true }
        guard leg.segmentIndex + 1 < legs.count, let platform = legs[leg.segmentIndex + 1].option.rides.first?.stops.first?.station else { return false }
        return location.distance(to: platform.coordinate) <= radius
    }

    private func wasAtStation(location: Coordinate?) -> Bool {
        if reachedPlatformAt != nil || startedAtPlatform || sense.isInsideStation { return true }
        guard let location, let platform = currentRide(at: .now)?.stops.first?.station else { return false }
        return location.distance(to: platform.coordinate) <= Self.unseenParkedRadius
    }

    /// Moving like a vehicle from the station: on the planned train if it was due, otherwise on some train, so ask.
    private mutating func boardByMovement(now: Date) {
        guard let leg = currentLeg, leg.mode == .transit, let ride = currentRide(at: now) else { return }
        if hasBoarded {
            if boardedBy == .schedule { boardedBy = .movement }
            return
        }
        if abs(now.timeIntervalSince(ride.board)) <= Self.movementBoardingWindow {
            hasBoarded = true
            boardedBy = .movement
            isAwaitingReplan = false
            recordBoarding(now: now)
        } else {
            sense.isAskingAboutTrain = true
        }
    }

    /// What the rider can say from the Lock Screen right now, and the question it answers, if there is one.
    public func actions(at now: Date) -> (prompt: String?, actions: [TripAction]) {
        guard let leg = currentLeg else { return (nil, []) }
        if let suggestion = suggestedTrain {
            return ("On the \(suggestion.ride.board.clockTime) \(suggestion.ride.routeName)?", [.confirmTrain, .rejectTrain])
        }
        if sense.isAskingAboutTrain {
            return ("On a train?", [.aboard, .rejectTrain])
        }
        switch leg.mode {
        case .transit where !hasBoarded:
            return (nil, [.aboard, .missed])
        case .transit where boardedBy == .schedule:
            return ("On the \(currentRide(at: now)?.routeName ?? "train")?", [.aboard, .missed])
        case .transit:
            return (nil, [])
        case .drive, .walk:
            guard isUnderway, connection != nil else { return (nil, []) }
            return (nil, [.arrived, .aboard])
        }
    }

    /// Fresh times for the train the rider is on, so what comes after it is planned from when it really gets in.
    public mutating func refreshRide(_ live: Ride) {
        guard hasBoarded, let trip = live.trip, var leg = currentLeg,
              let index = leg.option.rides.firstIndex(where: { $0.trip == trip }) else { return }
        var ride = leg.option.rides[index]
        ride.board = live.board
        ride.alight = live.alight
        ride.stops = live.stops
        ride.isRealtime = live.isRealtime
        leg.option.rides[index] = ride
        if index == leg.option.rides.count - 1 {
            leg.option.arrival = ride.alight.addingTimeInterval(leg.option.walkAfter)
        }
        legs[currentSegment] = leg
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
