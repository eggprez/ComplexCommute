import Foundation

/// One scheduled run of a vehicle: stable across re-plans and realtime updates, unlike a route and a time.
public struct TripRef: Codable, Hashable, Sendable {
    public var feedID: String
    public var tripID: String
    /// yyyymmdd of the service day the trip runs on.
    public var serviceDate: Int

    public init(feedID: String, tripID: String, serviceDate: Int) {
        self.feedID = feedID
        self.tripID = tripID
        self.serviceDate = serviceDate
    }
}

/// A location fix as the train matcher needs it: where, when, how sure, and how fast.
public struct LocationFix: Codable, Hashable, Sendable {
    public var coordinate: Coordinate
    public var time: Date
    /// Horizontal accuracy in meters.
    public var accuracy: Double
    /// Meters per second, as GPS measured it; nil where it couldn't say (underground, a first fix).
    public var speed: Double?

    public init(coordinate: Coordinate, time: Date, accuracy: Double, speed: Double? = nil) {
        self.coordinate = coordinate
        self.time = time
        self.accuracy = accuracy
        self.speed = speed
    }

    /// Faster than anyone walks or runs (11 mph): below this the rider is on foot, whatever line they are beside.
    public static let vehicleSpeed = 5.0
}

extension Array where Element == LocationFix {
    /// The fixes taken moving faster than a run: GPS's own speed where it gave one, otherwise the distance from a
    /// neighbouring fix, less what either could be out by. Walking beside the tracks never gets through.
    public func movingLikeAVehicle() -> [LocationFix] {
        let ordered = sorted { $0.time < $1.time }
        return ordered.indices.filter { index in
            let fix = ordered[index]
            if let speed = fix.speed { return speed >= LocationFix.vehicleSpeed }
            return [index - 1, index + 1].contains { other in
                guard ordered.indices.contains(other) else { return false }
                let seconds = abs(ordered[other].time.timeIntervalSince(fix.time))
                guard seconds >= 20 else { return false }
                let meters = fix.coordinate.distance(to: ordered[other].coordinate) - fix.accuracy - ordered[other].accuracy
                return meters / seconds >= LocationFix.vehicleSpeed
            }
        }
        .map { ordered[$0] }
    }
}

/// Why the app believes the rider is on the vehicle it shows them on.
public enum BoardingEvidence: String, Codable, Sendable {
    /// The train's departure time passed with nothing to say otherwise.
    case schedule
    /// The rider said they're aboard, without saying which train: location can still tell which.
    case riderAboard
    /// Moving along the line faster than on foot, and this train fits best so far. Checked again at every fix.
    case likely
    /// Location fixes along the line kept pace with this train and no other.
    case location
    /// The rider picked this train.
    case rider

    /// A trip saved by an earlier version may name a reason there is no longer: it is only as good as the schedule.
    public init(from decoder: any Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .schedule
    }
}

/// A place worth a geofence while the trip is at this point: the platform the next train leaves from, and
/// where the current leg ends. iOS watches these even with the app suspended, and wakes it on crossing one.
public struct WatchedPlace: Hashable, Sendable {
    /// "board.<segment>" or "end.<segment>": what crossing it means, and for which leg.
    public var id: String
    public var center: Coordinate
    public var radius: Double

    public init(id: String, center: Coordinate, radius: Double) {
        self.id = id
        self.center = center
        self.radius = radius
    }
}

/// Something the rider can tell the trip from outside the app: a Live Activity button.
public enum TripAction: String, Codable, CaseIterable, Sendable {
    /// At the end of the current drive or walk.
    case arrived
    /// On the vehicle (the planned one, unless location says which).
    case aboard
    /// It left without them.
    case missed

    public var title: String { title(for: nil) }
    public var symbol: String { symbol(for: nil) }

    /// Named for what is being caught: nobody is "on the train" at a bus stop.
    public func title(for vehicle: VehicleKind?) -> String {
        switch self {
        case .arrived: vehicle == .bus ? "At Stop" : "At Station"
        case .aboard: "On \((vehicle ?? .train).title)"
        case .missed: "Missed It"
        }
    }

    public func symbol(for vehicle: VehicleKind?) -> String {
        switch self {
        case .arrived: "mappin.and.ellipse"
        case .aboard: (vehicle ?? .train).symbol
        case .missed: "figure.wave"
        }
    }
}

/// A ride of a transit leg, and where it comes in the leg.
public struct WatchedRide: Hashable, Sendable {
    public var index: Int
    public var ride: Ride
    /// Not the ride the plan is on, but the other way the rider could go from the same place.
    public var isAlternative: Bool

    public init(index: Int, ride: Ride, isAlternative: Bool = false) {
        self.index = index
        self.ride = ride
        self.isAlternative = isAlternative
    }
}

/// A train the rider's location fits, found by matching fixes along the line against where each train was.
public struct TrainMatch: Hashable, Sendable {
    /// The train, ridden between the same stations as the ride it stands in for.
    public var ride: Ride
    /// Which ride of its leg it stands in for.
    public var rideIndex: Int
    /// Average seconds between where the fixes put the rider and where this train was at those moments.
    public var offset: TimeInterval
    /// Clear of every other train, over enough fixes to be sure of.
    public var isConfident: Bool
    /// The rider was seen leaving the boarding station, not just passing along the line somewhere near it.
    public var leftStation: Bool
    /// Another train that has fitted just as well for long enough that the fixes won't tell them apart:
    /// back to back, or a local and an express that haven't split yet.
    /// Or two lines that share the road out (the Q70 and the M60 leaving LaGuardia) and haven't parted yet.
    public var rival: Ride?
    /// The match is on the other way the rider could have gone, not the one the plan is on.
    public var isAlternative: Bool
    public var rivalIsAlternative: Bool

    public init(ride: Ride, rideIndex: Int, offset: TimeInterval, isConfident: Bool, leftStation: Bool = false, rival: Ride? = nil,
                isAlternative: Bool = false, rivalIsAlternative: Bool = false) {
        self.ride = ride
        self.rideIndex = rideIndex
        self.offset = offset
        self.isConfident = isConfident
        self.leftStation = leftStation
        self.rival = rival
        self.isAlternative = isAlternative
        self.rivalIsAlternative = rivalIsAlternative
    }
}

/// Which of two trains the rider is on, when their location can't say.
public struct TrainQuestion: Codable, Hashable, Sendable {
    /// Soonest first.
    public var options: [Ride]
    public var segment: Int
    public var rideIndex: Int
    /// For each option, whether taking it leaves the plan the trip is on. Optional so a trip saved by an
    /// earlier version still loads.
    public var alternatives: [Bool]?

    public init(options: [Ride], segment: Int, rideIndex: Int, alternatives: [Bool]? = nil) {
        self.options = options
        self.segment = segment
        self.rideIndex = rideIndex
        self.alternatives = alternatives
    }
}

extension Array where Element == Coordinate {
    /// The nearest point on this path to `coordinate`, if the path passes within `toleranceMeters` of it.
    public func snapping(_ coordinate: Coordinate, within toleranceMeters: Double) -> Coordinate? {
        guard count > 1 else { return nil }
        let metersPerLatitude = 111_320.0
        let metersPerLongitude = metersPerLatitude * cos(coordinate.latitude * .pi / 180)
        func point(_ c: Coordinate) -> (x: Double, y: Double) {
            ((c.longitude - coordinate.longitude) * metersPerLongitude, (c.latitude - coordinate.latitude) * metersPerLatitude)
        }
        var best: (point: (x: Double, y: Double), distance: Double)?
        for index in 0..<(count - 1) {
            let (a, b) = (point(self[index]), point(self[index + 1]))
            let (dx, dy) = (b.x - a.x, b.y - a.y)
            let lengthSquared = dx * dx + dy * dy
            let fraction = lengthSquared == 0 ? 0 : Swift.max(0, Swift.min(1, (-a.x * dx - a.y * dy) / lengthSquared))
            let nearest = (x: a.x + fraction * dx, y: a.y + fraction * dy)
            let distance = hypot(nearest.x, nearest.y)
            if best.map({ distance < $0.distance }) ?? true { best = (nearest, distance) }
        }
        guard let best, best.distance <= toleranceMeters else { return nil }
        return Coordinate(latitude: coordinate.latitude + best.point.y / metersPerLatitude,
                          longitude: coordinate.longitude + best.point.x / metersPerLongitude)
    }
}
