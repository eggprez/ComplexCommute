import CommuteCore
import Foundation
import GTFSKit

/// A vehicle due to leave a station.
public struct StopDeparture: Hashable, Identifiable, Sendable {
    public let route: RouteBadge
    /// Where the vehicle is headed: its headsign, or failing that its last stop.
    public let destination: String
    public let scheduled: Date
    public let time: Date
    public let isRealtime: Bool

    public var id: String { "\(route.name)|\(destination)|\(Int(scheduled.timeIntervalSince1970))" }
}

/// The next few vehicles of one line to one destination, which is how a rider reads a departure board.
public struct DepartureGroup: Hashable, Identifiable, Sendable {
    public let route: RouteBadge
    public let destination: String
    /// Soonest first.
    public let departures: [StopDeparture]

    public var id: String { "\(route.name)|\(destination)" }

    /// Groups time-ordered departures by line and destination, keeping the next `limit` of each.
    /// Groups are ordered by their soonest departure.
    public static func groups(_ departures: [StopDeparture], limit: Int = 3) -> [DepartureGroup] {
        var order: [String] = []
        var members: [String: [StopDeparture]] = [:]
        for departure in departures.sorted(by: { $0.time < $1.time }) {
            let key = "\(departure.route.name)|\(departure.destination)"
            if members[key] == nil { order.append(key) }
            if members[key, default: []].count < limit {
                members[key, default: []].append(departure)
            }
        }
        return order.compactMap { key in
            guard let group = members[key], let first = group.first else { return nil }
            return DepartureGroup(route: first.route, destination: first.destination, departures: group)
        }
    }
}

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
        /// The feed's shape each trip follows, where it publishes one.
        let shapes: [Int?]
        /// Row-major `[trip][position]`. Live predictions where known, otherwise the schedule.
        let arrivals: [Int32]
        let departures: [Int32]
        /// What the schedule said, for showing delays and keeping a trip's identity stable.
        let scheduledDepartures: [Int32]
        let isRealtime: [Bool]

        var tripCount: Int { headsigns.count }

        func arrival(trip: Int, position: Int) -> Int { Int(arrivals[trip * stops.count + position]) }
        func departure(trip: Int, position: Int) -> Int { Int(departures[trip * stops.count + position]) }
        func scheduledDeparture(trip: Int, position: Int) -> Int { Int(scheduledDepartures[trip * stops.count + position]) }

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
        /// A walk along the street to another station, as opposed to a change inside one. In-station times are
        /// already the agency's minimum for making the connection; a street walk is only the walking.
        let isStreet: Bool
    }

    public let stops: [Stop]
    /// Midnight starting the base service day; every time in the timetable is seconds from here.
    public let midnight: Date
    let routes: [RouteBadge]
    /// Feed and route_id for each entry of `routes`, which is how alerts name routes.
    let routeSources: [(feedID: String, routeID: String)]
    /// Trips by stop sequence, as scheduled. Patterns are derived from these, and re-derived with live times.
    private let groups: [TripGroup]
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

    public init(feeds: [FeedTimetableData], midnight: Date = Date(timeIntervalSince1970: 0)) {
        var stops: [Stop] = []
        var routes: [RouteBadge] = []
        var routeSources: [(feedID: String, routeID: String)] = []
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
            routeSources.append(contentsOf: feed.routeIDs.map { (feed.feedID, $0) })

            for trip in feed.trips {
                let calls = feed.stopTimes[trip.stopTimes]
                let key = PatternKey(route: routeOffset + trip.route, stops: calls.map { stopOffset + $0.stop },
                                     canBoard: calls.map(\.canBoard), canAlight: calls.map(\.canAlight))
                groups[key, default: []].append(TripTimes(feedID: feed.feedID, tripID: trip.id, serviceDate: trip.serviceDate, headsign: trip.headsign, shape: trip.shape,
                                                          arrivals: calls.map { Int32($0.arrival) }, departures: calls.map { Int32($0.departure) }))
            }
        }
        links = Array(repeating: [:], count: stops.count)

        // Platforms of each station, used to expand station-level transfers and sibling links.
        var platforms: [Int: [Int]] = [:]
        let servedStops = Set(groups.keys.flatMap(\.stops))
        for stop in servedStops {
            platforms[stops[stop].station, default: []].append(stop)
        }
        func addLink(_ from: Int, _ to: Int, seconds: Int, isStreet: Bool = false) {
            guard from != to else { return }
            let meters = stops[from].coordinate.distance(to: stops[to].coordinate)
            if links[from][to].map({ seconds < $0.seconds }) ?? true {
                links[from][to] = Footpath(to: to, seconds: seconds, meters: meters, isStreet: isStreet)
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
                addLink(stop, neighbor.stop, seconds: Self.walkSeconds(forMeters: neighbor.meters), isStreet: true)
            }
        }

        // Sorted so pattern numbering, and therefore tie-breaking, is deterministic.
        let orderedGroups = groups
            .sorted { $0.key.route != $1.key.route ? $0.key.route < $1.key.route : $0.key.stops.lexicographicallyPrecedes($1.key.stops) }
            .map { TripGroup(key: $0.key, trips: $0.value) }

        self.stops = stops
        self.midnight = midnight
        self.routes = routes
        self.routeSources = routeSources
        self.groups = orderedGroups
        self.footpaths = links.map { $0.values.sorted { $0.seconds < $1.seconds } }
        (patterns, patternsAtStop) = Self.patterns(for: orderedGroups, stopCount: stops.count)
    }

    private init(copying base: Timetable, groups: [TripGroup]) {
        stops = base.stops
        midnight = base.midnight
        routes = base.routes
        routeSources = base.routeSources
        footpaths = base.footpaths
        self.groups = base.groups
        (patterns, patternsAtStop) = Self.patterns(for: groups, stopCount: base.stops.count)
    }

    private static func patterns(for groups: [TripGroup], stopCount: Int) -> ([Pattern], [[(pattern: Int, position: Int)]]) {
        var patterns: [Pattern] = []
        var patternsAtStop: [[(pattern: Int, position: Int)]] = Array(repeating: [], count: stopCount)
        for group in groups {
            for lane in nonOvertakingLanes(group.trips) {
                for (position, stop) in group.key.stops.enumerated() {
                    patternsAtStop[stop].append((patterns.count, position))
                }
                patterns.append(Pattern(
                    route: group.key.route, stops: group.key.stops, canBoard: group.key.canBoard, canAlight: group.key.canAlight,
                    headsigns: lane.map(\.headsign), shapes: lane.map(\.shape), arrivals: lane.flatMap(\.arrivals), departures: lane.flatMap(\.departures),
                    scheduledDepartures: lane.flatMap { $0.scheduledDepartures ?? $0.departures }, isRealtime: lane.map { $0.scheduledDepartures != nil }
                ))
            }
        }
        return (patterns, patternsAtStop)
    }

    // MARK: Realtime

    /// A copy of the schedule with live predictions folded in: matched trips take their predicted times
    /// (so the router catches what is really coming and re-checks connections) and cancelled trips disappear.
    public func applying(_ realtime: [String: FeedRealtime]) -> Timetable {
        guard realtime.values.contains(where: { !$0.tripUpdates.isEmpty }) else { return self }
        let base = Int(midnight.timeIntervalSince1970)

        var updates: [String: [String: [RealtimeFeed.TripUpdate]]] = [:]
        for (feedID, feed) in realtime {
            for update in feed.tripUpdates {
                updates[feedID, default: [:]][feed.source.matchKey(forTripID: update.tripID), default: []].append(update)
            }
        }

        let liveGroups = groups.map { group in
            TripGroup(key: group.key, trips: group.trips.compactMap { trip -> TripTimes? in
                guard let source = realtime[trip.feedID]?.source,
                      let candidates = updates[trip.feedID]?[source.matchKey(forTripID: trip.tripID)],
                      let update = candidates.first(where: { $0.startDate == nil || $0.startDate == trip.serviceDate }) else { return trip }
                if update.isCanceled { return nil }
                return trip.applying(update, stopIDs: group.key.stops.map { stops[$0].id }, midnight: base)
            })
        }
        return Timetable(copying: self, groups: liveGroups)
    }

    /// Boardable stops for a station or stop id: its platforms, or itself.
    public func platforms(feedID: String, stopID: String) -> [Int] {
        guard let index = stops.firstIndex(where: { $0.feedID == feedID && $0.id == stopID }) else { return [] }
        let station = stops[index].station
        return stops.indices.filter { stops[$0].station == station && !patternsAtStop[$0].isEmpty }
    }

    /// What leaves a station next, across all of its platforms, soonest first.
    public func departures(feedID: String, stopID: String, from date: Date, within horizon: TimeInterval, limit: Int) -> [StopDeparture] {
        let earliest = Int(date.timeIntervalSince(midnight))
        let latest = earliest + Int(horizon)

        var departures: [StopDeparture] = []
        for platform in platforms(feedID: feedID, stopID: stopID) {
            for (patternIndex, position) in patternsAtStop[platform] {
                let pattern = patterns[patternIndex]
                guard position < pattern.stops.count - 1, pattern.canBoard[position],
                      var trip = pattern.earliestTrip(at: position, notBefore: earliest, limit: pattern.tripCount) else { continue }
                let lastStop = stops[pattern.stops[pattern.stops.count - 1]].name
                while trip < pattern.tripCount, pattern.departure(trip: trip, position: position) <= latest {
                    departures.append(StopDeparture(
                        route: routes[pattern.route], destination: pattern.headsigns[trip] ?? lastStop,
                        scheduled: midnight.addingTimeInterval(TimeInterval(pattern.scheduledDeparture(trip: trip, position: position))),
                        time: midnight.addingTimeInterval(TimeInterval(pattern.departure(trip: trip, position: position))),
                        isRealtime: pattern.isRealtime[trip]
                    ))
                    trip += 1
                }
            }
        }
        var seen = Set<String>()
        return Array(departures.sorted { $0.time < $1.time }.filter { seen.insert($0.id).inserted }.prefix(limit))
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

    struct TripTimes: Sendable {
        var feedID = ""
        var tripID = ""
        var serviceDate = 0
        let headsign: String?
        var shape: Int?
        var arrivals: [Int32]
        var departures: [Int32]
        /// Set once live times replace `departures`.
        var scheduledDepartures: [Int32]?

        /// Overlays a trip update. Agencies list only upcoming stops, so stops before the first update keep
        /// their scheduled times and stops after the last inherit its delay.
        func applying(_ update: RealtimeFeed.TripUpdate, stopIDs: [String], midnight: Int) -> TripTimes {
            var live = self
            var cursor = 0
            var delay: Int32?

            for stopTime in update.stopTimes where !stopTime.isSkipped {
                guard let stopID = stopTime.stopID, let position = stopIDs[cursor...].firstIndex(of: stopID) else { continue }
                if let delay {
                    for index in cursor..<position {
                        live.arrivals[index] += delay
                        live.departures[index] += delay
                    }
                }
                let arrival = stopTime.arrival.map { Int32(clamping: $0 - midnight) } ?? stopTime.arrivalDelay.map { arrivals[position] + Int32(clamping: $0) }
                let departure = stopTime.departure.map { Int32(clamping: $0 - midnight) } ?? stopTime.departureDelay.map { departures[position] + Int32(clamping: $0) }
                guard let known = departure ?? arrival else { continue }
                live.arrivals[position] = arrival ?? known
                live.departures[position] = departure ?? known
                delay = live.departures[position] - departures[position]
                cursor = position + 1
            }
            guard let delay else { return self }
            for index in cursor..<stopIDs.count {
                live.arrivals[index] += delay
                live.departures[index] += delay
            }
            // Predictions for neighbouring stops can cross; a vehicle never runs backwards in time.
            for index in live.arrivals.indices {
                if index > 0 { live.arrivals[index] = max(live.arrivals[index], live.departures[index - 1]) }
                live.departures[index] = max(live.departures[index], live.arrivals[index])
            }
            live.scheduledDepartures = departures
            return live
        }
    }

    struct TripGroup: Sendable {
        let key: PatternKey
        let trips: [TripTimes]
    }

    struct PatternKey: Hashable, Sendable {
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
