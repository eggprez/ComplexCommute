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
    /// What the station geofences have said. Optional so a trip saved by an earlier version still loads.
    private var sensing: Sensing?
    /// When the current leg began, as far as the app could tell. Optional for the same reason.
    private var legStartedAt: Date?
    /// Two trains fit the rider's location about equally (back to back, or a local and an express that haven't
    /// split yet): the one time the app asks which.
    public private(set) var trainQuestion: TrainQuestion?
    /// Asked once already for the ride under way; not again, whatever the answer.
    private var askedWhichTrain: Bool?

    private struct Sensing: Codable {
        /// Inside the geofence around the platform the next train leaves from.
        var isInsideStation: Bool?
        /// When the rider last left that geofence: about when their train pulled out, if they are on one.
        var leftStationAt: Date?
    }

    private var sense: Sensing {
        get { sensing ?? Sensing() }
        set { sensing = newValue }
    }

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

    /// Folds in a location and the clock, as if it were a fresh, accurate fix. Returns true if the rider moved on to another leg.
    @discardableResult
    public mutating func update(location: Coordinate?, now: Date) -> Bool {
        update(fix: location.map { LocationFix(coordinate: $0, time: now, accuracy: 10) }, now: now)
    }

    /// Folds in a location fix and the clock. Returns true if the rider moved on to another leg.
    @discardableResult
    public mutating func update(fix: LocationFix?, now: Date) -> Bool {
        let segmentBefore = currentSegment
        let isFirstFix = startLocation == nil
        let location = fix?.coordinate
        if let fix, let location {
            if startLocation == nil { startLocation = location }
            if let startLocation, location.distance(to: startLocation) > Self.earlyDepartureRadius { isUnderway = true }

            while let leg = currentLeg, hasReachedEnd(of: leg, with: fix, now: now) {
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
        trainQuestion = nil
        askedWhichTrain = nil
        sense.leftStationAt = nil
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
        legStartedAt = now
        hasBoarded = false
        boardedBy = nil
        trainQuestion = nil
        askedWhichTrain = nil
        sensing = nil
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
    private func hasReachedEnd(of leg: Leg, with fix: LocationFix, now: Date) -> Bool {
        let location = fix.coordinate
        let isOnAVehicle = (fix.speed ?? 0) >= LocationFix.vehicleSpeed
        if leg.mode == .walk {
            // A train can run right under where the rider is walking to, and a fix taken aboard it isn't them there.
            guard !isOnAVehicle, canFinishWalk(leg, at: fix.time) else { return false }
            if isWalkFromTrain(leg), fix.accuracy > Self.surfacedAccuracy { return false }
        }
        let radius = isOnAVehicle ? min(arrivalRadius(for: leg, now: now), Self.platformRadius) : arrivalRadius(for: leg, now: now)
        if location.distance(to: leg.to.coordinate) <= radius { return true }
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
            // train is in. Before that, stay strict: the train may be passing under somewhere near it on the way.
            return hasBoarded && now >= leg.arrival ? 600 : 200
        }
    }

    /// Worse than this, a fix is the phone guessing from cell towers: underground, still on the train.
    static let surfacedAccuracy = 100.0

    /// Getting off a train, up to the street and along it takes time: a walk from one can't be over the moment it starts.
    private func isWalkFromTrain(_ leg: Leg) -> Bool {
        leg.segmentIndex > 0 && legs[leg.segmentIndex - 1].mode == .transit
    }

    private func canFinishWalk(_ leg: Leg, at time: Date) -> Bool {
        guard isWalkFromTrain(leg) else { return true }
        guard let legStartedAt else { return true }
        let least = min(2 * 60, max(30, leg.duration / 2))
        return time.timeIntervalSince(legStartedAt) >= least
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

    /// Takes a train the location matched. A clear match is taken as fact, an unclear one as the likeliest train for
    /// now, to be replaced if later fixes fit another better. Only when two trains still fit alike well after the rider
    /// should be past a stop or two is it put to them, once.
    public mutating func apply(_ match: TrainMatch, segment: Int, now: Date) {
        guard let trip = match.ride.trip, segment >= currentSegment, segment < legs.count else { return }
        let rides = legs[segment].option.rides
        guard match.rideIndex < rides.count else { return }
        let evidence: BoardingEvidence = match.isConfident ? .location : .likely
        if segment == currentSegment, hasBoarded, rides[match.rideIndex].trip == trip, ridingIndex(at: now) == match.rideIndex {
            // Already shown on that very train; the location just makes it surer.
            if let boardedBy, boardedBy != .rider, boardedBy != .location { self.boardedBy = evidence }
        } else {
            if segment == currentSegment, hasBoarded, match.rideIndex <= ridingIndex(at: now),
               boardedBy == .rider || (boardedBy == .location && !match.isConfident) {
                // The rider's word stands, and a clear match isn't undone by a vaguer one.
                return
            }
            // Moving on from a drive or walk the app didn't see end takes more: in a car beside the tracks, a single
            // fix can fit a passing train. Only a clear match, from the station itself, will do.
            if segment > currentSegment, !(match.isConfident && match.leftStation) { return }
            board(match.ride, segment: segment, rideIndex: match.rideIndex, evidence: evidence, now: now)
        }
        if match.isConfident {
            trainQuestion = nil
        } else if let rival = match.rival, boardedBy != .rider, askedWhichTrain != true {
            trainQuestion = TrainQuestion(options: [match.ride, rival].sorted { $0.board < $1.board },
                                          segment: currentSegment, rideIndex: ridingIndex(at: now))
            askedWhichTrain = true
        }
    }

    /// The rider picked one of the trains the app asked about.
    public mutating func answerTrainQuestion(_ option: Int, now: Date = .now) {
        guard let question = trainQuestion, question.options.indices.contains(option) else { return }
        board(question.options[option], segment: question.segment, rideIndex: question.rideIndex, evidence: .rider, now: now)
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
        trainQuestion = nil
        isAwaitingReplan = false
        if !wasBoarded, !isCatchingUp { recordBoarding(now: now) }
    }

    // MARK: Geofences

    /// When the rider left the station they were waiting at, for telling which train pulled out with them.
    public var leftStationAt: Date? { sense.leftStationAt }

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
            // Passing through the exit station's fence on a train isn't arriving: only once it's due in. Nor is
            // passing under where a walk from the train ends, before there has been time to walk anywhere.
            if leg.mode == .walk ? canFinishWalk(leg, at: now) : leg.mode != .transit || (hasBoarded && now >= leg.arrival.addingTimeInterval(-5 * 60)) {
                advance(now: now)
            }
        case ("board", true):
            if segment == currentSegment + 1, leg.mode != .transit {
                advance(now: now)
            }
            if segment == currentSegment, currentLeg?.mode == .transit {
                sense.isInsideStation = true
                sense.leftStationAt = nil
                if !hasBoarded, reachedPlatformAt == nil, !startedAtPlatform { reachedPlatformAt = now }
            }
        case ("board", false) where segment == currentSegment && leg.mode == .transit:
            guard sense.isInsideStation == true else { break }
            sense.isInsideStation = false
            // On foot or on a train, nobody can tell yet: the location matcher weighs this against when each
            // train left, and only takes it as a train once the rider moves along the line faster than a run.
            sense.leftStationAt = now
        default:
            break
        }
        return currentSegment != before
    }

    /// What the rider can say from outside the app right now: the manual backup to the geofences and the location.
    public func actions(at now: Date) -> [TripAction] {
        guard let leg = currentLeg else { return [] }
        switch leg.mode {
        case .transit where !hasBoarded || boardedBy == .schedule:
            return [.aboard, .missed]
        case .transit:
            return []
        case .drive, .walk:
            guard isUnderway, connection != nil else { return [] }
            return [.arrived, .aboard]
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
