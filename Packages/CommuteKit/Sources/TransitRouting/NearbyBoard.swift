import CommuteCore
import Foundation
import GTFSKit

/// Which kinds of service a board of nearby departures lists.
public enum NearbyModes: String, Codable, Sendable, CaseIterable {
    case all
    /// Subways, trains, trams and ferries: anything boarded at a station.
    case rail
    case bus
}

/// One station or stop near the rider, and what leaves it next.
public struct NearbyBoard: Codable, Hashable, Identifiable, Sendable {
    public var station: StationRef
    /// Straight-line distance from the rider.
    public var meters: Double
    public var isBus: Bool
    /// Each line to each destination, soonest first.
    public var groups: [DepartureGroup]

    public var id: String { station.id }
    public var walk: TimeInterval { TimeInterval(Timetable.walkSeconds(forMeters: meters)) }

    public init(station: StationRef, meters: Double, isBus: Bool, groups: [DepartureGroup]) {
        self.station = station
        self.meters = meters
        self.isBus = isBus
        self.groups = groups
    }

    /// The board as it stands at `date`: vehicles that have left drop off, and lines with nothing left drop out.
    public func upcoming(at date: Date) -> NearbyBoard {
        var board = self
        board.groups = groups.compactMap { group in
            let left = group.departures.filter { $0.time > date.addingTimeInterval(-30) }
            return left.isEmpty ? nil : DepartureGroup(route: group.route, destination: group.destination, departures: left)
        }
        return board
    }
}
