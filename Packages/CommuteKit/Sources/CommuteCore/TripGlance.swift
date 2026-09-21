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

    public init(kind: Kind, mode: TravelMode? = nil, title: String, detail: String? = nil, route: RouteLabel? = nil, deadline: Date? = nil) {
        self.kind = kind
        self.mode = mode
        self.title = title
        self.detail = detail
        self.route = route
        self.deadline = deadline
    }

    /// The whole step in words, for VoiceOver and for anywhere too small for a badge.
    public var spokenTitle: String {
        guard let route, kind == .board || kind == .change, let place = title.range(of: " at ") else { return title }
        return "\(kind == .board ? "Board" : "Change to") \(route.name)\(title[place.lowerBound...])"
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

    public init(destination: String, instruction: TripInstruction, arrival: Date, arriveBy: Date? = nil, isFinished: Bool = false) {
        self.destination = destination
        self.instruction = instruction
        self.arrival = arrival
        self.arriveBy = arriveBy
        self.isFinished = isFinished
    }

    /// Nil when the rider never said when they have to be there; the arrival time stands in for the bar then.
    public var progress: ArriveByProgress? {
        arriveBy.map { ArriveByProgress(target: $0, projectedArrival: arrival, isFinal: isFinished) }
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
        return TripGlance(destination: template.waypoints.last?.name ?? "", instruction: instruction(at: now),
                          arrival: projected, arriveBy: arriveBy, isFinished: isFinished)
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

        let isChange = leg.option.rides.first != ride
        let walk = ride.walkBefore >= 60 ? "\(ride.walkBefore.shortDuration) walk" : nil
        let toward = ride.headsign.map { "toward \($0)" }
        let delay = ride.board.timeIntervalSince(ride.scheduledBoard)
        let status = !ride.isRealtime ? nil : delay >= 60 ? "\(delay.shortDuration) late" : delay <= -60 ? "\((-delay).shortDuration) early" : "on time"
        let detail = [isChange ? walk : nil, toward, status].compactMap(\.self).joined(separator: " · ")
        return TripInstruction(kind: isChange ? .change : .board, mode: .transit,
                               title: "\(isChange ? "Change" : "Board") at \(ride.boardStopName)",
                               detail: detail.isEmpty ? nil : detail, route: ride.label, deadline: ride.board)
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
