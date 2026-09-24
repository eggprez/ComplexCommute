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

/// A location fix as the train matcher needs it: where, when, and how sure.
public struct LocationFix: Codable, Hashable, Sendable {
    public var coordinate: Coordinate
    public var time: Date
    /// Horizontal accuracy in meters.
    public var accuracy: Double

    public init(coordinate: Coordinate, time: Date, accuracy: Double) {
        self.coordinate = coordinate
        self.time = time
        self.accuracy = accuracy
    }
}

/// Why the app believes the rider is on the vehicle it shows them on.
public enum BoardingEvidence: String, Codable, Sendable {
    /// The train's departure time passed with nothing to say otherwise.
    case schedule
    /// The phone started moving like a vehicle as the rider left the station, around when the train was due.
    case movement
    /// The rider said they're aboard, without saying which train: location can still tell which.
    case riderAboard
    /// Location fixes along the line kept pace with this train and no other.
    case location
    /// The rider picked this train.
    case rider
}

/// What the phone's motion coprocessor says the rider is doing. A train reads as `automotive`, like a car.
public enum Motion: String, Codable, Sendable {
    case stationary
    case walking
    case running
    case cycling
    case automotive
    case unknown

    var isOnFoot: Bool { self == .walking || self == .running }
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
    /// On the train (the planned one, unless location says which).
    case aboard
    /// The train left without them.
    case missed
    /// Yes to the train the app asked about.
    case confirmTrain
    /// No, or not yet.
    case rejectTrain

    public var title: String {
        switch self {
        case .arrived: "At Station"
        case .aboard: "On Train"
        case .missed: "Missed It"
        case .confirmTrain: "Yes"
        case .rejectTrain: "No"
        }
    }

    public var symbol: String {
        switch self {
        case .arrived: "mappin.and.ellipse"
        case .aboard: "tram.fill"
        case .missed: "figure.wave"
        case .confirmTrain: "checkmark"
        case .rejectTrain: "xmark"
        }
    }
}

/// A ride of a transit leg, and where it comes in the leg.
public struct WatchedRide: Hashable, Sendable {
    public var index: Int
    public var ride: Ride

    public init(index: Int, ride: Ride) {
        self.index = index
        self.ride = ride
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
    /// Clear of every other train, over enough fixes to act on without asking.
    public var isConfident: Bool

    public init(ride: Ride, rideIndex: Int, offset: TimeInterval, isConfident: Bool) {
        self.ride = ride
        self.rideIndex = rideIndex
        self.offset = offset
        self.isConfident = isConfident
    }
}

/// A train the app thinks the rider may be on, waiting for them to say yes or no.
public struct TrainSuggestion: Codable, Hashable, Sendable {
    public var ride: Ride
    public var segment: Int
    public var rideIndex: Int

    public init(ride: Ride, segment: Int, rideIndex: Int) {
        self.ride = ride
        self.segment = segment
        self.rideIndex = rideIndex
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
