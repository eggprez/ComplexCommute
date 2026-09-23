import Foundation

public enum TravelMode: String, Codable, CaseIterable, Hashable, Sendable {
    case drive
    case walk
    case transit
}

public struct Waypoint: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: Codable, Hashable, Sendable {
        /// Resolved to the device's position each time the trip is planned.
        case currentLocation
        case place
        case stop(feedID: String, stopID: String)
    }

    public var id: UUID
    public var name: String
    public var subtitle: String?
    public var coordinate: Coordinate
    public var kind: Kind

    public init(id: UUID = UUID(), name: String, subtitle: String? = nil, coordinate: Coordinate, kind: Kind = .place) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.coordinate = coordinate
        self.kind = kind
    }

    /// A stop with a schedule, as opposed to a place the rider has to get to a stop from.
    public var isStop: Bool {
        if case .stop = kind { return true }
        return false
    }

    public static func currentLocation(_ coordinate: Coordinate = Coordinate(latitude: 0, longitude: 0)) -> Waypoint {
        Waypoint(name: "Current Location", coordinate: coordinate, kind: .currentLocation)
    }
}

/// The user-pinned shape of a trip: ordered waypoints with a travel mode between each pair.
/// Invariant: `modes.count == max(0, waypoints.count - 1)`.
public struct TripTemplate: Codable, Hashable, Sendable {
    public struct Segment: Hashable, Sendable {
        public let index: Int
        public let from: Waypoint
        public let to: Waypoint
        public let mode: TravelMode
    }

    public private(set) var waypoints: [Waypoint]
    public private(set) var modes: [TravelMode]
    /// Transit services (feed ids) the rider doesn't want to ride on this trip, e.g. buses or a pricier
    /// commuter railroad. Transit legs are routed as if these schedules weren't installed.
    public var excludedFeedIDs: Set<String>

    public init() {
        waypoints = []
        modes = []
        excludedFeedIDs = []
    }

    public init(waypoints: [Waypoint], modes: [TravelMode], excludedFeedIDs: Set<String> = []) {
        precondition(modes.count == max(0, waypoints.count - 1), "need exactly one mode between each pair of waypoints")
        self.waypoints = waypoints
        self.modes = modes
        self.excludedFeedIDs = excludedFeedIDs
    }

    private enum CodingKeys: String, CodingKey {
        case waypoints, modes, excludedFeedIDs
    }

    /// Commutes saved before services could be turned off have no exclusions.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        waypoints = try container.decode([Waypoint].self, forKey: .waypoints)
        modes = try container.decode([TravelMode].self, forKey: .modes)
        excludedFeedIDs = try container.decodeIfPresent(Set<String>.self, forKey: .excludedFeedIDs) ?? []
    }

    /// The part of this trip from waypoint `index` on, keeping the rider's choice of services.
    public func suffix(from index: Int) -> TripTemplate {
        TripTemplate(waypoints: Array(waypoints[index...]), modes: Array(modes[index...]), excludedFeedIDs: excludedFeedIDs)
    }

    public var isPlannable: Bool { waypoints.count >= 2 }

    public var segments: [Segment] {
        modes.indices.map { Segment(index: $0, from: waypoints[$0], to: waypoints[$0 + 1], mode: modes[$0]) }
    }

    public mutating func append(_ waypoint: Waypoint, mode: TravelMode) {
        insert(waypoint, at: waypoints.count, mode: mode)
    }

    /// Inserts a waypoint. `mode` applies to the segment leaving the new waypoint, or arriving at
    /// it when appended at the end.
    public mutating func insert(_ waypoint: Waypoint, at index: Int, mode: TravelMode) {
        if !waypoints.isEmpty {
            modes.insert(mode, at: min(index, modes.count))
        }
        waypoints.insert(waypoint, at: index)
    }

    public mutating func removeWaypoint(at index: Int) {
        waypoints.remove(at: index)
        if !modes.isEmpty {
            modes.remove(at: min(index, modes.count - 1))
        }
    }

    public mutating func replaceWaypoint(at index: Int, with waypoint: Waypoint) {
        waypoints[index] = waypoint
    }

    /// Reorders waypoints; modes stay with their position in the chain.
    public mutating func moveWaypoint(from source: Int, to destination: Int) {
        let waypoint = waypoints.remove(at: source)
        waypoints.insert(waypoint, at: destination)
    }

    public mutating func setMode(_ mode: TravelMode, forSegment index: Int) {
        modes[index] = mode
    }

    public mutating func updateCurrentLocation(_ coordinate: Coordinate) {
        for index in waypoints.indices where waypoints[index].kind == .currentLocation {
            waypoints[index].coordinate = coordinate
        }
    }

    public var usesCurrentLocation: Bool {
        waypoints.contains { $0.kind == .currentLocation }
    }
}
