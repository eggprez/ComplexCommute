import CommuteCore
import Foundation
import GTFSKit

/// Plans transit legs from the installed schedules. Keeps the current service day's network in memory.
public actor TransitPlanner {
    private let library: FeedLibrary
    private let realtime: RealtimeService?
    private let calendar: Calendar
    private var cache: (key: CacheKey, timetable: Timetable, midnight: Date)?
    private var liveCache: (key: CacheKey, version: Int, timetable: Timetable)?
    /// Shapes already read for drawing rides. Re-planning asks for the same few over and over.
    private var shapes: [ShapeKey: [Coordinate]?] = [:]

    private struct ShapeKey: Hashable {
        let feedID: String
        let index: Int
    }

    private struct CacheKey: Equatable {
        let serviceDate: Int
        let libraryRevision: Int
        let feedIDs: [String]
    }

    /// How far someone will walk between a non-station waypoint and a stop.
    static let accessRadiusMeters = 1_200.0
    static let accessStopLimit = 12
    /// Time the rider wants in hand when reaching a station and at every change of vehicles, unless they say otherwise.
    public static let defaultBufferSeconds = 180
    /// Even a rider who wants no buffer can't step off one train and onto another in no time at all.
    static let minimumChangeSeconds = 60
    /// Runs of the router per request, each leaving just after the previous best.
    static let departuresToTry = 3
    /// An option with an extra ride must save at least this much to be worth showing.
    static let worthwhileSavingPerRide: TimeInterval = 180

    /// Predictions only reach an hour or two ahead; beyond that the schedule is all anyone knows.
    static let realtimeHorizon: TimeInterval = 2 * 3_600

    public init(library: FeedLibrary, realtime: RealtimeService? = nil, timeZone: TimeZone = TimeZone(identifier: "America/New_York")!) {
        self.library = library
        self.realtime = realtime
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
    }

    /// Ways to ride from `origin` to `destination`, soonest arrival first. Empty when no installed schedule connects them.
    /// - Parameter bufferSeconds: time to allow between reaching a station (from a drive, a walk or another vehicle)
    ///   and the vehicle leaving, covering parking, fares, stairs and a train that pulls out early.
    ///   A rider `isWaitingAtOrigin` is past the first of those already; changes of vehicle keep theirs.
    public func options(from origin: Waypoint, to destination: Waypoint, departingAt departure: Date,
                        bufferSeconds: Int = TransitPlanner.defaultBufferSeconds, isWaitingAtOrigin: Bool = false) async -> [LegOption] {
        let accessBufferSeconds = isWaitingAtOrigin ? 0 : bufferSeconds
        guard let (scheduled, midnight, key) = await timetable(for: departure, near: [origin.coordinate, destination.coordinate]) else { return [] }
        let snapshot = abs(departure.timeIntervalSinceNow) < Self.realtimeHorizon ? await realtime?.snapshot(for: key.feedIDs) : nil
        let timetable = snapshot.map { liveTimetable(scheduled, key: key, snapshot: $0) } ?? scheduled
        let access = stops(for: origin, in: timetable, bufferSeconds: accessBufferSeconds)
        let egress = stops(for: destination, in: timetable, bufferSeconds: 0)
        guard !access.isEmpty, !egress.isEmpty else { return [] }

        var router = RaptorRouter(timetable: timetable)
        router.changeSeconds = max(Self.minimumChangeSeconds, bufferSeconds)
        var options: [LegOption] = []
        var seen = Set<String>()
        var clock = Int(departure.timeIntervalSince(midnight))

        for _ in 0..<Self.departuresToTry {
            let journeys = router.journeys(from: access, to: egress, departure: clock)
            var found: [LegOption] = []
            for journey in journeys {
                found.append(await legOption(for: journey, in: timetable, midnight: midnight, from: origin, to: destination, snapshot: snapshot,
                                             accessBufferSeconds: accessBufferSeconds))
            }
            guard let soonest = found.map(\.departure).min() else { break }
            for option in Self.worthwhile(found) where seen.insert(Self.signature(option)).inserted {
                options.append(option)
            }
            clock = Int(soonest.timeIntervalSince(midnight)) + 60
        }
        let useful = options.filter { option in !options.contains { Self.makesPointless(option, $0) } }
        return useful.sorted { $0.arrival < $1.arrival }
    }

    /// What leaves `station` next, across all of its platforms, soonest first. Live where predictions exist.
    public func departures(from station: StationRef, after date: Date = .now, within horizon: TimeInterval = 2 * 3_600, limit: Int = 400) async -> [StopDeparture] {
        guard let (scheduled, _, key) = await timetable(for: date, near: [station.coordinate]) else { return [] }
        let snapshot = abs(date.timeIntervalSinceNow) < Self.realtimeHorizon ? await realtime?.snapshot(for: key.feedIDs) : nil
        let timetable = snapshot.map { liveTimetable(scheduled, key: key, snapshot: $0) } ?? scheduled
        return timetable.departures(feedID: station.feedID, stopID: station.stopID, from: date, within: horizon, limit: limit)
    }

    // MARK: Timetable

    /// Re-deriving patterns is the expensive part of going live, so do it once per fetched snapshot.
    private func liveTimetable(_ scheduled: Timetable, key: CacheKey, snapshot: RealtimeSnapshot) -> Timetable {
        if let liveCache, liveCache.key == key, liveCache.version == snapshot.version {
            return liveCache.timetable
        }
        let live = scheduled.applying(snapshot.feeds)
        liveCache = (key, snapshot.version, live)
        return live
    }

    private func timetable(for date: Date, near coordinates: [Coordinate]) async -> (Timetable, Date, CacheKey)? {
        let midnight = calendar.startOfDay(for: date)
        let revision = await library.revision

        func serviceDay(offsetDays: Int, endingAfter: Int? = nil, startingBefore: Int? = nil) -> ServiceDay {
            let day = calendar.date(byAdding: .day, value: offsetDays, to: midnight) ?? midnight
            let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
            return ServiceDay(date: (parts.year ?? 0) * 10_000 + (parts.month ?? 0) * 100 + (parts.day ?? 0),
                              weekday: ((parts.weekday ?? 2) + 5) % 7, // Calendar: 1 = Sunday; GTFS bit order: 0 = Monday
                              offsetSeconds: offsetDays * 86_400, tripsEndingAfter: endingAfter, tripsStartingBefore: startingBefore)
        }
        let today = serviceDay(offsetDays: 0)

        // Yesterday's trips that run past midnight, and tomorrow's early ones so late-night plans can finish.
        let days = [serviceDay(offsetDays: -1, endingAfter: 86_400), today, serviceDay(offsetDays: 1, startingBefore: 8 * 3_600)]
        let feedIDs = await library.feedIDs(near: coordinates)
        let key = CacheKey(serviceDate: today.date, libraryRevision: revision, feedIDs: feedIDs)
        if let cache, cache.key == key {
            return (cache.timetable, cache.midnight, key)
        }
        let feeds = await library.timetableData(for: days, feedIDs: feedIDs)
        guard !feeds.isEmpty else { return nil }
        let timetable = Timetable(feeds: feeds, midnight: midnight)
        cache = (key, timetable, midnight)
        // A re-imported feed numbers its shapes afresh.
        shapes.removeAll()
        return (timetable, midnight, key)
    }

    private func stops(for waypoint: Waypoint, in timetable: Timetable, bufferSeconds: Int) -> [StopAccess] {
        if case .stop(let feedID, let stopID) = waypoint.kind {
            let platforms = timetable.platforms(feedID: feedID, stopID: stopID)
            if !platforms.isEmpty {
                return platforms.map { StopAccess(stop: $0, seconds: bufferSeconds) }
            }
        }
        return timetable.stops(near: waypoint.coordinate, radiusMeters: Self.accessRadiusMeters, limit: Self.accessStopLimit)
            .map { StopAccess(stop: $0.stop, seconds: Timetable.walkSeconds(forMeters: $0.meters) + bufferSeconds, meters: $0.meters) }
    }

    /// Where the vehicle runs between the first and last of `calls`, from the trip's published shape.
    private func path(feedID: String, shape: Int?, calls: [RideStop]) async -> [Coordinate]? {
        guard let shape else { return nil }
        let key = ShapeKey(feedID: feedID, index: shape)
        let points: [Coordinate]?
        if let cached = shapes[key] {
            points = cached
        } else {
            points = await library.shape(feedID: feedID, index: shape)
            if shapes.count > 200 { shapes.removeAll() }
            shapes[key] = .some(points)
        }
        return points?.clipped(passing: calls.map(\.station.coordinate))
    }

    // MARK: Results

    private func legOption(for journey: Journey, in timetable: Timetable, midnight: Date, from origin: Waypoint, to destination: Waypoint,
                           snapshot: RealtimeSnapshot?, accessBufferSeconds: Int) async -> LegOption {
        var rides: [Ride] = []
        var alerts: [ServiceAlert] = []
        let now = Int(Date.now.timeIntervalSince1970)
        var geometry = [origin.coordinate]
        var walkingMeters = journey.walkAfter.meters

        for (index, ride) in journey.rides.enumerated() {
            // The first walk was padded with the rider's buffer so the router would allow for it. It is waiting, not walking.
            let walkSeconds = ride.walkBefore.seconds - (index == 0 ? accessBufferSeconds : 0)
            let pattern = timetable.patterns[ride.pattern]
            let route = timetable.routes[pattern.route]
            let calls = (ride.boardPosition...ride.alightPosition).map { position in
                let stop = timetable.stops[pattern.stops[position]]
                let seconds = position == ride.boardPosition ? pattern.departure(trip: ride.trip, position: position) : pattern.arrival(trip: ride.trip, position: position)
                return RideStop(station: StationRef(feedID: stop.feedID, stopID: stop.id, name: stop.name, coordinate: stop.coordinate),
                                time: midnight.addingTimeInterval(TimeInterval(seconds)))
            }
            let board = midnight.addingTimeInterval(TimeInterval(pattern.departure(trip: ride.trip, position: ride.boardPosition)))
            let scheduledBoard = midnight.addingTimeInterval(TimeInterval(pattern.scheduledDeparture(trip: ride.trip, position: ride.boardPosition)))
            let source = timetable.routeSources[pattern.route]
            let path = await path(feedID: source.feedID, shape: pattern.shapes[ride.trip], calls: calls)
            rides.append(Ride(
                routeName: route.name, routeColorHex: route.colorHex, routeTextColorHex: route.textColorHex, routeType: route.type,
                headsign: pattern.headsigns[ride.trip],
                boardStopName: timetable.stops[pattern.stops[ride.boardPosition]].name,
                alightStopName: timetable.stops[pattern.stops[ride.alightPosition]].name,
                scheduledBoard: scheduledBoard, board: board,
                alight: midnight.addingTimeInterval(TimeInterval(pattern.arrival(trip: ride.trip, position: ride.alightPosition))),
                isRealtime: pattern.isRealtime[ride.trip], stops: calls, walkBefore: TimeInterval(max(0, walkSeconds)), path: path
            ))

            // Alerts naming this route; when an alert also names stops, only if the ride touches one of them.
            let riddenStops = Set(pattern.stops[ride.boardPosition...ride.alightPosition].flatMap { [timetable.stops[$0].id, timetable.stops[timetable.stops[$0].station].id] })
            for alert in snapshot?.feeds[source.feedID]?.alerts ?? [] where alert.isActive(at: now) && alert.routeIDs.contains(source.routeID) {
                guard alert.stopIDs.isEmpty || !alert.stopIDs.isDisjoint(with: riddenStops) else { continue }
                if let existing = alerts.firstIndex(where: { $0.id == alert.id }) {
                    if !alerts[existing].routeNames.contains(route.name) { alerts[existing].routeNames.append(route.name) }
                } else {
                    alerts.append(ServiceAlert(id: alert.id, header: alert.header, details: alert.details,
                                               url: alert.url.flatMap { URL(string: $0) }, routeNames: [route.name]))
                }
            }
            geometry.append(contentsOf: calls.map(\.station.coordinate))
            walkingMeters += ride.walkBefore.meters
        }
        geometry.append(destination.coordinate)

        let firstBoard = rides.first?.board ?? midnight
        let lastAlight = rides.last?.alight ?? midnight
        return LegOption(
            mode: .transit,
            departure: firstBoard.addingTimeInterval(-TimeInterval(journey.rides.first?.walkBefore.seconds ?? 0)),
            arrival: lastAlight.addingTimeInterval(TimeInterval(journey.walkAfter.seconds)),
            distanceMeters: nil,
            walkingMeters: walkingMeters * Timetable.walkDetourFactor,
            geometry: geometry,
            rides: rides,
            walkAfter: TimeInterval(journey.walkAfter.seconds),
            alerts: alerts
        )
    }

    /// True when `other` is so much better a deal that nobody would pick `option`: it needs no more rides and
    /// either leaves later yet arrives no later, or leaves far later for a slightly later arrival
    /// (e.g. a roundabout night route that saves 8 minutes by leaving 40 minutes sooner).
    static func makesPointless(_ option: LegOption, _ other: LegOption) -> Bool {
        let leavesLaterBy = other.departure.timeIntervalSince(option.departure)
        let arrivesLaterBy = other.arrival.timeIntervalSince(option.arrival)
        guard other.rides.count <= option.rides.count, leavesLaterBy > 0 else { return false }
        return arrivesLaterBy <= 0 || leavesLaterBy >= 2 * arrivesLaterBy
    }

    /// Drops options whose extra rides buy too little time to be worth the hassle.
    private static func worthwhile(_ options: [LegOption]) -> [LegOption] {
        guard let simplest = options.min(by: { $0.rides.count < $1.rides.count }) else { return [] }
        return options.filter { option in
            let extraRides = option.rides.count - simplest.rides.count
            return extraRides == 0 || simplest.arrival.timeIntervalSince(option.arrival) >= Double(extraRides) * worthwhileSavingPerRide
        }
    }

    private static func signature(_ option: LegOption) -> String {
        option.rides.map { "\($0.routeName)@\($0.boardStopName)@\(Int($0.scheduledBoard.timeIntervalSince1970))" }.joined(separator: ">")
    }
}
