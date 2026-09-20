import CommuteCore
import Foundation
import GTFSKit

/// An in-memory network laid out for RAPTOR: trips grouped into patterns (same route, same stop
/// sequence, never overtaking each other) plus walking links between stops.
public struct Timetable: Sendable {
    public struct Stop: Sendable {
        public let feedID: String
        public let id: String
        public let name: String
        public let coordinate: Coordinate
        /// Index of the parent station, or of the stop itself when it has none.
        public let station: Int
    }

    struct Pattern: Sendable {
        let route: Int
        let stops: [Int]
        let canBoard: [Bool]
        let canAlight: [Bool]
        let headsigns: [String?]
        /// Row-major `[trip][position]`.
        let arrivals: [Int32]
        let departures: [Int32]

        var tripCount: Int { headsigns.count }

        func arrival(trip: Int, position: Int) -> Int { Int(arrivals[trip * stops.count + position]) }
        func departure(trip: Int, position: Int) -> Int { Int(departures[trip * stops.count + position]) }

        /// First trip leaving `position` at or after `time`, searching only trips before `limit`.
        func earliestTrip(at position: Int, notBefore time: Int, limit: Int) -> Int? {
            var low = 0
            var high = limit
            while low < high {
                let middle = (low + high) / 2
                if departure(trip: middle, position: position) >= time { high = middle } else { low = middle + 1 }
            }
            return low < limit ? low : nil
        }
    }

    struct Footpath: Sendable {
        let to: Int
        let seconds: Int
        let meters: Double
    }

    public let stops: [Stop]
    let routes: [RouteBadge]
    let patterns: [Pattern]
    /// For each stop: the patterns calling there and the position within each.
    let patternsAtStop: [[(pattern: Int, position: Int)]]
    let footpaths: [[Footpath]]

    /// Time allowed for an in-station change when the feed doesn't say.
    static let defaultTransferSeconds = 120
    /// Stops this close are linked by a walking transfer even across agencies.
    static let walkLinkRadiusMeters = 400.0
    static let walkLinksPerStop = 8

    /// Streets are rarely straight: real walks run about 30% longer than the crow flies.
    static let walkDetourFactor = 1.3
    static let walkMetersPerSecond = 1.3

    /// Estimated walking time for a straight-line distance.
    public static func walkSeconds(forMeters meters: Double) -> Int {
        Int((meters * walkDetourFactor / walkMetersPerSecond).rounded())
    }

    public init(feeds: [FeedTimetableData]) {
        var stops: [Stop] = []
        var routes: [RouteBadge] = []
        var groups: [PatternKey: [TripTimes]] = [:]
        var links: [[Int: Footpath]] = []

        for feed in feeds {
            let stopOffset = stops.count
            let routeOffset = routes.count
            for (index, stop) in feed.stops.enumerated() {
                stops.append(Stop(feedID: feed.feedID, id: stop.id, name: stop.name, coordinate: stop.coordinate,
                                  station: stopOffset + (stop.parent ?? index)))
            }
            routes.append(contentsOf: feed.routes)

            for trip in feed.trips {
                let calls = feed.stopTimes[trip.stopTimes]
                let key = PatternKey(route: routeOffset + trip.route, stops: calls.map { stopOffset + $0.stop },
                                     canBoard: calls.map(\.canBoard), canAlight: calls.map(\.canAlight))
                groups[key, default: []].append(TripTimes(headsign: trip.headsign, arrivals: calls.map { Int32($0.arrival) },
                                                          departures: calls.map { Int32($0.departure) }))
            }
        }
        links = Array(repeating: [:], count: stops.count)

        // Platforms of each station, used to expand station-level transfers and sibling links.
        var platforms: [Int: [Int]] = [:]
        let servedStops = Set(groups.keys.flatMap(\.stops))
        for stop in servedStops {
            platforms[stops[stop].station, default: []].append(stop)
        }
        func addLink(_ from: Int, _ to: Int, seconds: Int) {
            guard from != to else { return }
            let meters = stops[from].coordinate.distance(to: stops[to].coordinate)
            if links[from][to].map({ seconds < $0.seconds }) ?? true {
                links[from][to] = Footpath(to: to, seconds: seconds, meters: meters)
            }
        }

        // 1. Transfers the agency published. They may name stations, so expand to platforms.
        var stopOffset = 0
        for feed in feeds {
            for transfer in feed.transfers {
                let seconds = transfer.seconds ?? Self.defaultTransferSeconds
                for from in platforms[stops[stopOffset + transfer.from].station] ?? [] {
                    for to in platforms[stops[stopOffset + transfer.to].station] ?? [] {
                        addLink(from, to, seconds: seconds)
                    }
                }
            }
            stopOffset += feed.stops.count
        }
        // 2. Platforms of the same station.
        for siblings in platforms.values where siblings.count > 1 {
            for from in siblings {
                for to in siblings where links[from][to] == nil {
                    addLink(from, to, seconds: Self.defaultTransferSeconds)
                }
            }
        }
        // 3. Anything within a short walk, which is what connects different agencies.
        let grid = StopGrid(stops: servedStops.map { ($0, stops[$0].coordinate) }, cellMeters: Self.walkLinkRadiusMeters)
        for stop in servedStops {
            let nearby = grid.stops(within: Self.walkLinkRadiusMeters, of: stops[stop].coordinate)
                .filter { $0.stop != stop && links[stop][$0.stop] == nil }
                .prefix(Self.walkLinksPerStop)
            for neighbor in nearby {
                addLink(stop, neighbor.stop, seconds: Self.walkSeconds(forMeters: neighbor.meters) + 60)
            }
        }

        var patterns: [Pattern] = []
        var patternsAtStop: [[(pattern: Int, position: Int)]] = Array(repeating: [], count: stops.count)
        // Sorted so pattern numbering, and therefore tie-breaking, is deterministic.
        let orderedGroups = groups.sorted {
            $0.key.route != $1.key.route ? $0.key.route < $1.key.route : $0.key.stops.lexicographicallyPrecedes($1.key.stops)
        }
        for (key, trips) in orderedGroups {
            for lane in Self.nonOvertakingLanes(trips) {
                for (position, stop) in key.stops.enumerated() {
                    patternsAtStop[stop].append((patterns.count, position))
                }
                patterns.append(Pattern(route: key.route, stops: key.stops, canBoard: key.canBoard, canAlight: key.canAlight,
                                        headsigns: lane.map(\.headsign), arrivals: lane.flatMap(\.arrivals), departures: lane.flatMap(\.departures)))
            }
        }

        self.stops = stops
        self.routes = routes
        self.patterns = patterns
        self.patternsAtStop = patternsAtStop
        self.footpaths = links.map { $0.values.sorted { $0.seconds < $1.seconds } }
    }

    /// Boardable stops for a station or stop id: its platforms, or itself.
    public func platforms(feedID: String, stopID: String) -> [Int] {
        guard let index = stops.firstIndex(where: { $0.feedID == feedID && $0.id == stopID }) else { return [] }
        let station = stops[index].station
        return stops.indices.filter { stops[$0].station == station && !patternsAtStop[$0].isEmpty }
    }

    /// Served stops near a coordinate, nearest first.
    public func stops(near coordinate: Coordinate, radiusMeters: Double, limit: Int) -> [(stop: Int, meters: Double)] {
        stops.indices
            .filter { !patternsAtStop[$0].isEmpty }
            .map { ($0, stops[$0].coordinate.distance(to: coordinate)) }
            .filter { $0.1 <= radiusMeters }
            .sorted { $0.1 < $1.1 }
            .prefix(limit)
            .map { (stop: $0.0, meters: $0.1) }
    }

    /// RAPTOR finds the earliest trip by binary search, which needs trips ordered at every stop.
    /// Trips that overtake (an express sharing a local's stop list, schedule quirks) go to a separate lane.
    static func nonOvertakingLanes(_ trips: [TripTimes]) -> [[TripTimes]] {
        var lanes: [[TripTimes]] = []
        for trip in trips.sorted(by: { ($0.departures.first ?? 0, $0.arrivals.last ?? 0) < ($1.departures.first ?? 0, $1.arrivals.last ?? 0) }) {
            let fits = lanes.firstIndex { lane in
                guard let last = lane.last else { return true }
                return zip(last.departures, trip.departures).allSatisfy { $0 <= $1 } && zip(last.arrivals, trip.arrivals).allSatisfy { $0 <= $1 }
            }
            if let fits {
                lanes[fits].append(trip)
            } else {
                lanes.append([trip])
            }
        }
        return lanes
    }

    struct TripTimes {
        let headsign: String?
        let arrivals: [Int32]
        let departures: [Int32]
    }

    private struct PatternKey: Hashable {
        let route: Int
        let stops: [Int]
        let canBoard: [Bool]
        let canAlight: [Bool]
    }
}

/// Uniform grid for "what's within a few hundred meters" without comparing every pair of stops.
private struct StopGrid {
    private var cells: [Cell: [(stop: Int, coordinate: Coordinate)]] = [:]
    private let cellDegrees: Double

    private struct Cell: Hashable {
        let x: Int
        let y: Int
    }

    init(stops: [(Int, Coordinate)], cellMeters: Double) {
        // Longitude cells are narrower than latitude cells away from the equator; search ±2 to compensate.
        cellDegrees = cellMeters / 111_000
        for (stop, coordinate) in stops {
            cells[cell(for: coordinate), default: []].append((stop, coordinate))
        }
    }

    private func cell(for coordinate: Coordinate) -> Cell {
        Cell(x: Int((coordinate.longitude / cellDegrees).rounded(.down)), y: Int((coordinate.latitude / cellDegrees).rounded(.down)))
    }

    func stops(within meters: Double, of center: Coordinate) -> [(stop: Int, meters: Double)] {
        let origin = cell(for: center)
        var found: [(stop: Int, meters: Double)] = []
        for x in (origin.x - 2)...(origin.x + 2) {
            for y in (origin.y - 1)...(origin.y + 1) {
                for entry in cells[Cell(x: x, y: y)] ?? [] {
                    let distance = entry.coordinate.distance(to: center)
                    if distance <= meters {
                        found.append((entry.stop, distance))
                    }
                }
            }
        }
        return found.sorted { $0.meters < $1.meters }
    }
}
