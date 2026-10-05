import Foundation

/// A line's name and colours: enough to draw its bullet somewhere that has no feed to look it up in.
public struct RouteLabel: Codable, Hashable, Sendable {
    public var name: String
    /// "RRGGBB", as published by the agency.
    public var colorHex: String?
    public var textColorHex: String?

    public init(name: String, colorHex: String? = nil, textColorHex: String? = nil) {
        self.name = name
        self.colorHex = colorHex
        self.textColorHex = textColorHex
    }
}

extension Ride {
    public var label: RouteLabel {
        RouteLabel(name: routeName, colorHex: routeColorHex, textColorHex: routeTextColorHex)
    }
}

/// The one thing to do next, a leg at a time: no turns, just where to be and what to be on.
public struct TripInstruction: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Waiting for the time to set off.
        case leave
        /// Driving, walking, or on transit the app has no vehicles for.
        case travel
        /// Waiting for the first vehicle of a transit leg.
        case board
        /// Between one vehicle and the next.
        case change
        /// Aboard, waiting for the stop to get off at.
        case ride
        case arrived
    }

    public var kind: Kind
    public var mode: TravelMode?
    /// "Drive to Metropark", "Board at Canal St", "Exit at 57 St". A ride's line is in `route`, not in here.
    public var title: String
    public var detail: String?
    public var route: RouteLabel?
    /// The moment this step is counting down to: setting off, the doors closing, the stop coming up.
    public var deadline: Date?
    /// A train to catch is about to leave: count down the seconds. Otherwise whole minutes are plenty,
    /// and a countdown ticking every second on the way to a station 20 minutes off is just noise.
    public var countsSeconds: Bool

    public init(kind: Kind, mode: TravelMode? = nil, title: String, detail: String? = nil, route: RouteLabel? = nil, deadline: Date? = nil,
                countsSeconds: Bool = false) {
        self.kind = kind
        self.mode = mode
        self.title = title
        self.detail = detail
        self.route = route
        self.deadline = deadline
        self.countsSeconds = countsSeconds
    }

    /// Seconds are counted down only this close to a departure the rider has to make.
    public static let secondsCountdown: TimeInterval = 2 * 60

    /// The whole step in words, for VoiceOver and for anywhere too small for a badge.
    public var spokenTitle: String {
        guard let route, kind == .board || kind == .change, let place = title.range(of: " at ") else { return title }
        return "\(kind == .board ? "Board" : "Change to") \(route.name)\(title[place.lowerBound...])"
    }
}

/// What leaves the station of the change coming up, going where the rider needs to go: the planned
/// vehicle and the ones either side of it, so a missed or late connection has an answer on the Lock Screen.
public struct ConnectionBoard: Codable, Hashable, Sendable {
    public struct Departure: Codable, Hashable, Sendable {
        public var route: RouteLabel
        public var time: Date
        public var isRealtime: Bool
        /// The vehicle the plan is on.
        public var isPlanned: Bool

        public init(route: RouteLabel, time: Date, isRealtime: Bool = false, isPlanned: Bool = false) {
            self.route = route
            self.time = time
            self.isRealtime = isRealtime
            self.isPlanned = isPlanned
        }
    }

    /// Where the change is: "Canal St".
    public var station: String
    /// Where the next vehicle is ridden to: "57 St". Every departure listed stops there.
    public var toward: String
    /// Soonest first.
    public var departures: [Departure]

    public init(station: String, toward: String, departures: [Departure]) {
        self.station = station
        self.toward = toward
        self.departures = departures
    }

    /// Everything still catchable from `time`; nil once nothing is.
    public func catchable(from time: Date, limit: Int = 3) -> ConnectionBoard? {
        let left = departures.filter { $0.time >= time }.prefix(limit)
        return left.isEmpty ? nil : ConnectionBoard(station: station, toward: toward, departures: Array(left))
    }
}

/// One of the ways onward from the next boarding, as a button: the lines it rides, when the first of them
/// leaves, and when it gets the rider there.
public struct BranchGlance: Codable, Hashable, Identifiable, Sendable {
    /// The branch's own id (see `TripBranch`), handed back when the button is tapped.
    public var id: String
    /// The lines ridden this way, in order.
    public var routes: [RouteLabel]
    public var departs: Date
    public var arrival: Date
    public var isRealtime: Bool

    public init(id: String, routes: [RouteLabel], departs: Date, arrival: Date, isRealtime: Bool = false) {
        self.id = id
        self.routes = routes
        self.departs = departs
        self.arrival = arrival
        self.isRealtime = isRealtime
    }
}

/// The choice coming up: where it is made, and the two best ways on from there.
public struct DecisionGlance: Codable, Hashable, Sendable {
    /// Where the boarding is: "LaGuardia Terminal B".
    public var station: String
    public var options: [BranchGlance]
    /// Not a choice ahead but a check on one the clock made: the rider is shown on the first of these with
    /// nothing seen to back it, and can say so or say it was the other.
    public var isAssumed: Bool

    public init(station: String, options: [BranchGlance], isAssumed: Bool = false) {
        self.station = station
        self.options = options
        self.isAssumed = isAssumed
    }
}

/// A trip in progress boiled down to what fits on a Lock Screen or a wrist: how it stands against
/// the time to be there, and the next thing to do.
public struct TripGlance: Codable, Hashable, Sendable {
    public var destination: String
    public var instruction: TripInstruction
    /// When the trip is expected to end, or when it did.
    public var arrival: Date
    public var arriveBy: Date?
    public var isFinished: Bool
    /// The next vehicles from the change the rider is coming up on (see `ActiveTrip.upcomingChange`).
    /// The trip can't know these by itself: the app looks them up and fills them in.
    public var connections: ConnectionBoard?
    /// Buttons for telling the trip what happened without opening the app.
    public var actions: [TripAction]
    /// What the buttons are about, so they can say "On Bus" at a bus stop.
    public var vehicle: VehicleKind?
    /// The ways onward from the next boarding, while which to take is still the rider's to pick.
    public var decision: DecisionGlance?

    public init(destination: String, instruction: TripInstruction, arrival: Date, arriveBy: Date? = nil, isFinished: Bool = false,
                connections: ConnectionBoard? = nil, actions: [TripAction] = [], vehicle: VehicleKind? = nil, decision: DecisionGlance? = nil) {
        self.actions = actions
        self.vehicle = vehicle
        self.decision = decision
        self.destination = destination
        self.instruction = instruction
        self.arrival = arrival
        self.arriveBy = arriveBy
        self.isFinished = isFinished
        self.connections = connections
    }

    /// Nil when the rider never said when they have to be there; the arrival time stands in for the bar then.
    public var progress: ArriveByProgress? {
        arriveBy.map { ArriveByProgress(target: $0, projectedArrival: arrival, isFinal: isFinished) }
    }
}

/// A station the rider will shortly board at, and where they ride to from it.
public struct UpcomingChange: Hashable, Sendable {
    public var station: StationRef
    /// The stop the next vehicle is ridden to. Any line that gets there from `station` will do.
    public var toward: StationRef
    /// The soonest a vehicle can leave and still be caught.
    public var catchableFrom: Date
    public var planned: Ride

    /// The departures a lookup found, as the Lock Screen lists them, with the planned vehicle marked.
    public func board(_ departures: [ConnectionBoard.Departure]) -> ConnectionBoard {
        let marked = departures.map { departure in
            var departure = departure
            departure.isPlanned = departure.route.name == planned.routeName
                && abs(departure.time.timeIntervalSince(planned.board)) < 60
            return departure
        }
        return ConnectionBoard(station: station.name, toward: toward.name, departures: marked)
    }
}

extension ActiveTrip {
    public func glance(at now: Date) -> TripGlance {
        var projected = finishedAt ?? arrival
        if finishedAt == nil, projected < now {
            // The plan has stopped moving and the clock hasn't. Whole minutes, so that a glance which is
            // otherwise unchanged doesn't count as new every second.
            projected = Date(timeIntervalSinceReferenceDate: (now.timeIntervalSinceReferenceDate / 60).rounded(.up) * 60)
        }
        var instruction = instruction(at: now)
        let decision = decision
        if decision != nil, instruction.kind != .ride {
            // Which vehicle is the open question: the step names the place, and the choices say the rest.
            instruction.route = nil
            instruction.detail = nil
            if instruction.kind == .board || instruction.kind == .change {
                instruction.deadline = nil
                instruction.countsSeconds = false
            }
        }
        return TripGlance(destination: template.waypoints.last?.name ?? "", instruction: instruction,
                          arrival: projected, arriveBy: arriveBy, isFinished: isFinished, actions: actions(at: now),
                          vehicle: (currentLeg?.mode == .transit ? currentRide(at: now) : connection?.ride)?.vehicle, decision: decision)
    }

    /// The open choice as the Lock Screen draws it, or nil when there is nothing to pick between.
    public var decision: DecisionGlance? {
        if let (riding, other) = assumption, let other {
            return DecisionGlance(station: riding.boardStopName, options: [
                BranchGlance(id: Self.assumedPrefix + Self.key(for: riding), routes: [riding.label], departs: riding.board,
                             arrival: arrival, isRealtime: riding.isRealtime),
                BranchGlance(id: Self.assumedPrefix + other.id, routes: Array(other.rides.map(\.label).prefix(3)), departs: other.ride.board,
                             arrival: other.arrival, isRealtime: other.ride.isRealtime),
            ], isAssumed: true)
        }
        let branches = branches
        guard branches.count > 1, !isFinished else { return nil }
        return DecisionGlance(station: branches[0].ride.boardStopName, options: branches.map { branch in
            BranchGlance(id: branch.id, routes: Array(branch.rides.map(\.label).prefix(3)), departs: branch.ride.board,
                         arrival: branch.arrival, isRealtime: branch.ride.isRealtime)
        })
    }

    public func instruction(at now: Date) -> TripInstruction {
        guard let leg = currentLeg else {
            return TripInstruction(kind: .arrived, title: "You've Arrived", detail: template.waypoints.last?.name)
        }
        let heading = "\(leg.mode.verb) to \(leg.to.name)"

        guard leg.mode == .transit, let ride = currentRide(at: now) else {
            if leg.mode != .transit, !isMoving, leg.departure.timeIntervalSince(now) >= 60 {
                return TripInstruction(kind: .leave, mode: leg.mode, title: "Leave at \(leg.departure.shortTime)",
                                       detail: "\(heading) · \(leg.duration.shortDuration)", deadline: leg.departure)
            }
            let catching = connection.map { ride, spare in
                "Then \(ride.routeName) \(ride.board.shortTime) · \(spare >= 60 ? "\(spare.shortDuration) to spare" : "tight")"
            }
            return TripInstruction(kind: .travel, mode: leg.mode, title: heading, detail: catching, deadline: leg.arrival)
        }

        if hasBoarded, now >= ride.board {
            let left = ride.stops.isEmpty ? nil : ride.stops.dropFirst().count { $0.time > now }
            let stops = left.flatMap { $0 > 0 ? "\($0) \($0 == 1 ? "stop" : "stops")" : nil }
            let detail = [stops, step(after: ride, in: leg)].compactMap(\.self).joined(separator: " · ")
            return TripInstruction(kind: .ride, mode: .transit, title: "Exit at \(ride.alightStopName)",
                                   detail: detail.isEmpty ? nil : detail, route: ride.label, deadline: ride.alight)
        }

        let isChange = isChangingVehicles
        let walk = ride.walkBefore >= 60 ? "\(ride.walkBefore.shortDuration) walk" : nil
        let toward = ride.headsign.map { "toward \($0)" }
        let delay = ride.board.timeIntervalSince(ride.scheduledBoard)
        let status = !ride.isRealtime ? nil : delay >= 60 ? "\(delay.shortDuration) late" : delay <= -60 ? "\((-delay).shortDuration) early" : "on time"
        let free = isChange && ride.freeTransfer != nil ? "free transfer" : nil
        let detail = [isChange ? walk : nil, free, toward, status].compactMap(\.self).joined(separator: " · ")
        return TripInstruction(kind: isChange ? .change : .board, mode: .transit,
                               title: "\(isChange ? "Change" : "Board") at \(ride.boardStopName)",
                               detail: detail.isEmpty ? nil : detail, route: ride.label, deadline: ride.board,
                               countsSeconds: ride.board.timeIntervalSince(now) <= TripInstruction.secondsCountdown)
    }

    /// How close to a change of vehicles the rider has to be before the Lock Screen lists what leaves there.
    public static let changeLookahead: TimeInterval = 5 * 60

    /// The next boarding the rider is on the way to, once it is within `changeLookahead`: getting off one
    /// vehicle for another, reaching a station by road or on foot, or already standing on the platform.
    public func upcomingChange(at now: Date) -> UpcomingChange? {
        guard let leg = currentLeg else { return nil }
        let next: Ride
        /// Getting off, or reaching the end of the drive or walk.
        let reached: Date
        /// On foot from there to the platform: across the station, or along the street as at Farragut North to
        /// Farragut West, whether that walk is inside the transit leg or a short walk leg of its own.
        var walk: TimeInterval = 0
        if leg.mode == .transit {
            guard let ride = currentRide(at: now) else { return nil }
            if hasBoarded, now >= ride.board {
                let rides = leg.option.rides
                if let index = rides.firstIndex(of: ride), index + 1 < rides.count {
                    next = rides[index + 1]
                } else {
                    guard let (first, crossing) = firstRide(after: 1) else { return nil }
                    next = first
                    walk = crossing
                }
                reached = ride.alight
            } else {
                // Waiting for it, or crossing to it: already there as far as the list is concerned.
                next = ride
                reached = now
            }
        } else {
            guard let (first, crossing) = firstRide(after: 1) else { return nil }
            next = first
            reached = leg.arrival
            walk = crossing
        }
        guard reached.timeIntervalSince(now) <= Self.changeLookahead,
              let station = next.stops.first?.station, let toward = next.stops.last?.station else { return nil }
        // A rider still on their way needs the walk to the platform as well; one who is there doesn't.
        let catchable = reached > now ? reached + walk + next.walkBefore : now
        return UpcomingChange(station: station, toward: toward, catchableFrom: catchable, planned: next)
    }

    /// The first vehicle of the transit leg `offset` legs on, looking past one walk leg in between (a street
    /// crossing between two stations), and how long that walk takes.
    private func firstRide(after offset: Int) -> (Ride, walk: TimeInterval)? {
        let ahead = remainingLegs.dropFirst(offset).prefix(2)
        guard let next = ahead.first else { return nil }
        if next.mode == .transit, let ride = next.option.rides.first { return (ride, 0) }
        guard next.mode == .walk, let after = ahead.dropFirst().first, after.mode == .transit,
              let ride = after.option.rides.first else { return nil }
        return (ride, next.duration)
    }

    /// What getting off leads to: another vehicle, the next leg, or the end of the trip.
    private func step(after ride: Ride, in leg: Leg) -> String? {
        let rides = leg.option.rides
        if let index = rides.firstIndex(of: ride), index + 1 < rides.count {
            return "then \(rides[index + 1].routeName)"
        }
        guard let next = remainingLegs.dropFirst().first else { return nil }
        return "then \(next.mode.verb.lowercased()) to \(next.to.name)"
    }
}

extension TravelMode {
    /// "Drive", "Walk", "Transit": the mode as the start of an instruction.
    var verb: String {
        switch self {
        case .drive: "Drive"
        case .walk: "Walk"
        case .transit: "Transit"
        }
    }
}

extension Date {
    /// "8:42 AM"
    var shortTime: String { formatted(date: .omitted, time: .shortened) }
}
