import Foundation

/// One vehicle boarding within a transit leg.
public struct Ride: Codable, Hashable, Sendable {
    public var routeName: String
    public var routeColorHex: String?
    public var routeTextColorHex: String?
    /// GTFS route_type (1 subway, 2 rail, 3 bus, ...).
    public var routeType: Int
    public var headsign: String?
    public var boardStopName: String
    public var alightStopName: String
    public var scheduledBoard: Date
    public var board: Date
    public var alight: Date
    public var isRealtime: Bool
    /// Coordinates of every stop from boarding to exit, for drawing the ride.
    public var path: [Coordinate]
    /// Walking time from the previous ride (or the leg's start) to the boarding stop.
    public var walkBefore: TimeInterval

    /// Stops ridden, counting the exit but not the boarding stop.
    public var stopCount: Int { max(0, path.count - 1) }

    public init(routeName: String, routeColorHex: String? = nil, routeTextColorHex: String? = nil, routeType: Int = 1,
                headsign: String? = nil, boardStopName: String, alightStopName: String, scheduledBoard: Date, board: Date,
                alight: Date, isRealtime: Bool = false, path: [Coordinate] = [], walkBefore: TimeInterval = 0) {
        self.routeName = routeName
        self.routeColorHex = routeColorHex
        self.routeTextColorHex = routeTextColorHex
        self.routeType = routeType
        self.path = path
        self.walkBefore = walkBefore
        self.headsign = headsign
        self.boardStopName = boardStopName
        self.alightStopName = alightStopName
        self.scheduledBoard = scheduledBoard
        self.board = board
        self.alight = alight
        self.isRealtime = isRealtime
    }
}

/// One way of covering a single template segment, as produced by a `LegResolving`.
public struct LegOption: Hashable, Sendable {
    public var mode: TravelMode
    public var departure: Date
    public var arrival: Date
    public var distanceMeters: Double?
    /// Walking inside the leg (the whole leg for `.walk`, station access/transfers for `.transit`).
    public var walkingMeters: Double
    public var geometry: [Coordinate]
    public var rides: [Ride]
    /// Walking time from the last ride's exit to the end of the leg.
    public var walkAfter: TimeInterval
    public var summary: String?
    /// True when times are a coarse estimate rather than a concrete schedule.
    public var isEstimate: Bool

    public init(mode: TravelMode, departure: Date, arrival: Date, distanceMeters: Double? = nil, walkingMeters: Double = 0,
                geometry: [Coordinate] = [], rides: [Ride] = [], walkAfter: TimeInterval = 0, summary: String? = nil, isEstimate: Bool = false) {
        self.mode = mode
        self.departure = departure
        self.arrival = arrival
        self.distanceMeters = distanceMeters
        self.walkingMeters = walkingMeters
        self.geometry = geometry
        self.rides = rides
        self.walkAfter = walkAfter
        self.summary = summary
        self.isEstimate = isEstimate
    }

    public var duration: TimeInterval { arrival.timeIntervalSince(departure) }
}

public struct Leg: Hashable, Identifiable, Sendable {
    public var segmentIndex: Int
    public var from: Waypoint
    public var to: Waypoint
    public var option: LegOption

    public var id: Int { segmentIndex }
    public var mode: TravelMode { option.mode }
    public var departure: Date { option.departure }
    public var arrival: Date { option.arrival }
    public var duration: TimeInterval { option.duration }

    public init(segmentIndex: Int, from: Waypoint, to: Waypoint, option: LegOption) {
        self.segmentIndex = segmentIndex
        self.from = from
        self.to = to
        self.option = option
    }
}

public struct Itinerary: Hashable, Identifiable, Sendable {
    public var legs: [Leg]

    public init(legs: [Leg]) {
        self.legs = legs
    }

    /// Stable across re-plans as long as the same vehicles are used, so a selection survives refreshes.
    public var id: String {
        legs.map { leg in
            let rides = leg.option.rides
                .map { "\($0.routeName)@\($0.boardStopName)@\(Int($0.scheduledBoard.timeIntervalSince1970))" }
                .joined(separator: ",")
            return "\(leg.mode.rawValue)[\(rides)]"
        }.joined(separator: ">")
    }

    public var departure: Date { legs.first?.departure ?? .distantPast }
    public var arrival: Date { legs.last?.arrival ?? .distantPast }
    public var duration: TimeInterval { arrival.timeIntervalSince(departure) }
    public var walkingMeters: Double { legs.reduce(0) { $0 + $1.option.walkingMeters } }
    public var rideCount: Int { legs.reduce(0) { $0 + $1.option.rides.count } }
    public var hasEstimates: Bool { legs.contains { $0.option.isEstimate } }

    /// Idle time before the given leg starts (e.g. waiting on a platform).
    public func wait(before index: Int) -> TimeInterval {
        guard index > 0 else { return 0 }
        return max(0, legs[index].departure.timeIntervalSince(legs[index - 1].arrival))
    }
}

public enum ItineraryTag: String, CaseIterable, Hashable, Sendable {
    case fastest
    case fewestTransfers
    case leastWalking
}
