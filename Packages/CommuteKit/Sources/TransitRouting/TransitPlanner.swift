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
    /// - Parameter excludedFeedIDs: services the rider won't ride, left out as if they weren't installed.
    public func options(from origin: Waypoint, to destination: Waypoint, departingAt departure: Date,
                        bufferSeconds: Int = TransitPlanner.defaultBufferSeconds, isWaitingAtOrigin: Bool = false,
                        excludedFeedIDs: Set<String> = []) async -> [LegOption] {
        let accessBufferSeconds = isWaitingAtOrigin ? 0 : bufferSeconds
        guard let (scheduled, midnight, key) = await timetable(for: departure, near: [origin.coordinate, destination.coordinate],
                                                               excluding: excludedFeedIDs) else { return [] }
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
    /// - Parameter toward: only vehicles that go on to stop there, on whichever line.
    public func departures(from station: StationRef, toward: StationRef? = nil, after date: Date = .now,
                           within horizon: TimeInterval = 2 * 3_600, limit: Int = 400) async -> [StopDeparture] {
        guard let (scheduled, _, key) = await timetable(for: date, near: [station.coordinate], acceptingMore: true) else { return [] }
        let snapshot = abs(date.timeIntervalSinceNow) < Self.realtimeHorizon ? await realtime?.snapshot(for: key.feedIDs) : nil
        let timetable = snapshot.map { liveTimetable(scheduled, key: key, snapshot: $0) } ?? scheduled
        return timetable.departures(feedID: station.feedID, stopID: station.stopID, toward: toward.map { ($0.feedID, $0.stopID) },
                                    from: date, within: horizon, limit: limit)
    }

    /// Stations within a five-minute walk of `station`, nearest first, with the walk to each.
    public func stationsInSamePlace(as station: StationRef, on date: Date = .now) async -> [(station: StationRef, walk: TimeInterval)] {
        guard let (timetable, _, _) = await timetable(for: date, near: [station.coordinate]) else { return [] }
        return timetable.stationsInSamePlace(feedID: station.feedID, stopID: station.stopID).map { entry in
            (StationRef(feedID: entry.station.feedID, stopID: entry.station.id, name: entry.station.name, coordinate: entry.station.coordinate),
             TimeInterval(Timetable.walkSeconds(forMeters: entry.meters)))
        }
    }

    // MARK: Nearby

    /// What leaves next from the stations and stops around `coordinate`, nearest first. Each line to each destination
    /// is listed once, at the nearest place to board it: the stop across the street going the same way adds nothing.
    ///
    /// Reads only the trips calling at those few stops instead of building the whole network, so it fits in a
    /// widget's memory and leaves the network a trip is being planned with alone.
    /// - Parameter perLine: how many departures to keep for each line to each destination.
    public func nearbyBoards(around coordinate: Coordinate, at date: Date = .now, modes: NearbyModes = .all,
                             horizon: TimeInterval = 90 * 60, perLine: Int = 3, live: Bool = true) async -> [NearbyBoard] {
        let found = await library.stops(near: coordinate, radiusMeters: Self.nearbyStationRadius, limit: 60)
        var places: [(stop: TransitStop, meters: Double, isBus: Bool)] = []
        var (stations, busStops) = (0, 0)
        for stop in found where !stop.routes.isEmpty {
            let meters = stop.coordinate.distance(to: coordinate)
            let isBus = stop.routes.allSatisfy { Timetable.isBus(routeType: $0.type) }
            if isBus {
                guard modes != .rail, meters <= Self.nearbyBusRadius, busStops < Self.nearbyBusStopLimit else { continue }
                busStops += 1
            } else {
                guard modes != .bus, stations < Self.nearbyStationLimit else { continue }
                stations += 1
            }
            places.append((stop, meters, isBus))
        }
        guard !places.isEmpty else { return [] }

        let midnight = calendar.startOfDay(for: date)
        let earliest = Int(date.timeIntervalSince(midnight))
        let stopIDs = Dictionary(grouping: places, by: \.stop.feedID).mapValues { $0.map(\.stop.stopID) }
        let feeds = await library.timetableData(for: serviceDays(around: midnight), callingAt: stopIDs,
                                                between: earliest..<earliest + Int(horizon) + 1)
        guard !feeds.isEmpty else { return [] }
        var timetable = Timetable(feeds: feeds, midnight: midnight)
        if live, let realtime {
            let platforms = Set(places.flatMap { place in
                [place.stop.stopID] + timetable.platforms(feedID: place.stop.feedID, stopID: place.stop.stopID).map { timetable.stops[$0].id }
            })
            timetable = timetable.applying(await realtime.snapshot(for: stopIDs.keys.sorted(), servingStops: platforms).feeds)
        }

        var boards: [NearbyBoard] = []
        var listed = Set<String>()
        for place in places {
            let departures = timetable.departures(feedID: place.stop.feedID, stopID: place.stop.stopID, from: date, within: horizon, limit: 400)
            let groups = DepartureGroup.groups(departures, limit: perLine).filter { listed.insert($0.id).inserted }
            guard !groups.isEmpty else { continue }
            boards.append(NearbyBoard(station: StationRef(feedID: place.stop.feedID, stopID: place.stop.stopID, name: place.stop.name,
                                                          coordinate: place.stop.coordinate),
                                      meters: place.meters, isBus: place.isBus, groups: groups))
        }
        return boards
    }

    /// A station is worth a longer walk than a bus stop is.
    static let nearbyStationRadius = 1_000.0
    static let nearbyBusRadius = 500.0
    static let nearbyStationLimit = 4
    static let nearbyBusStopLimit = 8

    // MARK: Following a train

    /// The network for following `ride`, live where predictions exist, with every way of going its way.
    private func runs(for ride: Ride, at date: Date) async -> (Timetable, Date, [Timetable.Run])? {
        guard let board = ride.stops.first?.station, let alight = ride.stops.last?.station,
              let (scheduled, midnight, key) = await timetable(for: date, near: [board.coordinate, alight.coordinate], acceptingMore: true)
        else { return nil }
        let snapshot = abs(date.timeIntervalSinceNow) < Self.realtimeHorizon ? await realtime?.snapshot(for: key.feedIDs) : nil
        let timetable = snapshot.map { liveTimetable(scheduled, key: key, snapshot: $0) } ?? scheduled
        let runs = timetable.runs(from: (board.feedID, board.stopID), to: (alight.feedID, alight.stopID))
        return runs.isEmpty ? nil : (timetable, midnight, runs)
    }

    /// The same vehicle as `ride`, with its latest times.
    public func live(_ ride: Ride, at date: Date = .now) async -> Ride? {
        guard let trip = ride.trip, let (timetable, midnight, runs) = await runs(for: ride, at: date),
              let (run, index) = timetable.locate(trip, in: runs) else { return nil }
        return await self.ride(pattern: run.pattern, trip: index, board: run.board, alight: run.alight, in: timetable, midnight: midnight,
                               walkBefore: ride.walkBefore, freeTransfer: ride.freeTransfer)
    }

    /// The vehicle the rider's recent location fixes keep pace with, among everything going the way of any of `rides`.
    public func matchTrain(for rides: [WatchedRide], fixes: [LocationFix], leftStation: Date? = nil, at date: Date = .now) async -> TrainMatch? {
        var fits: [(match: Timetable.TripFit, watched: WatchedRide, timetable: Timetable, midnight: Date)] = []
        for watched in rides {
            guard let (timetable, midnight, runs) = await runs(for: watched.ride, at: date),
                  // The geofence is round the place the first of them leaves from; later changes have none.
                  let fit = timetable.fit(fixes, to: runs, leftStation: watched.index == rides.first?.index ? leftStation : nil) else { continue }
            fits.append((fit, watched, timetable, midnight))
        }
        // A line the rider has since turned off keeps the good fit it had while they were on it: only what
        // still fits the latest fixes counts. On a tie, the plan's own ride comes before the other way to go.
        let latest = fits.map(\.match.lastSample).max() ?? 0
        fits = fits.filter { $0.match.lastSample >= latest - Timetable.fitSeconds }
            .sorted { ($0.match.offset, $0.watched.isAlternative ? 1 : 0) < ($1.match.offset, $1.watched.isAlternative ? 1 : 0) }
        guard let best = fits.first else { return nil }
        func trip(_ fit: (match: Timetable.TripFit, watched: WatchedRide, timetable: Timetable, midnight: Date)) -> TripRef {
            fit.timetable.patterns[fit.match.run.pattern].trips[fit.match.trip]
        }
        func ride(_ fit: (match: Timetable.TripFit, watched: WatchedRide, timetable: Timetable, midnight: Date), run: Timetable.Run, trip: Int) async -> Ride {
            await self.ride(pattern: run.pattern, trip: trip, board: run.board, alight: run.alight, in: fit.timetable, midnight: fit.midnight,
                            walkBefore: fit.watched.ride.walkBefore, freeTransfer: fit.watched.ride.freeTransfer)
        }
        // Two lines that share the road out fit alike until they part: neither is clear of the other yet.
        let bestTrip = trip(best)
        let other = fits.dropFirst().first {
            $0.watched.isAlternative != best.watched.isAlternative && trip($0) != bestTrip
                && $0.match.offset <= Timetable.confidentFitSeconds && $0.match.offset < best.match.offset + Timetable.rivalMarginSeconds
        }

        var rival: Ride?
        var rivalIsAlternative = best.watched.isAlternative
        if let same = best.match.rival {
            rival = await ride(best, run: same.run, trip: same.trip)
        } else if let other, best.match.span >= Timetable.undecidedSeconds, best.match.offset <= Timetable.confidentFitSeconds {
            rival = await ride(other, run: other.match.run, trip: other.match.trip)
            rivalIsAlternative = other.watched.isAlternative
        }
        return TrainMatch(ride: await ride(best, run: best.match.run, trip: best.match.trip), rideIndex: best.watched.index,
                          offset: best.match.offset, isConfident: best.match.isConfident && other == nil,
                          leftStation: best.match.leftStation, rival: rival,
                          isAlternative: best.watched.isAlternative, rivalIsAlternative: rivalIsAlternative)
    }

    /// Trains going `ride`'s way that leave its boarding station around now, for the rider to say which one they're on.
    public func trains(like ride: Ride, around date: Date = .now, before: TimeInterval = 20 * 60, after: TimeInterval = 20 * 60) async -> [Ride] {
        guard let (timetable, midnight, runs) = await runs(for: ride, at: date) else { return [] }
        let now = Int(date.timeIntervalSince(midnight))
        var seen = Set<TripRef>()
        var found: [Ride] = []
        for run in runs {
            let pattern = timetable.patterns[run.pattern]
            for trip in 0..<pattern.tripCount {
                let leaves = pattern.departure(trip: trip, position: run.board)
                guard leaves >= now - Int(before), leaves <= now + Int(after), seen.insert(pattern.trips[trip]).inserted else { continue }
                found.append(await self.ride(pattern: run.pattern, trip: trip, board: run.board, alight: run.alight, in: timetable,
                                             midnight: midnight, walkBefore: ride.walkBefore, freeTransfer: ride.freeTransfer))
            }
        }
        return found.sorted { $0.board < $1.board }
    }

    /// Every vehicle going `ride`'s way, where it should be right now.
    public func vehicles(along ride: Ride, at date: Date = .now) async -> [VehicleEstimate] {
        guard let (timetable, midnight, runs) = await runs(for: ride, at: date) else { return [] }
        return timetable.vehicles(on: runs, at: Int(date.timeIntervalSince(midnight)))
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

    /// The service days a clock measured from `midnight` has to draw on: yesterday's trips that run past midnight,
    /// today's, and tomorrow's early ones so late-night plans can finish.
    private func serviceDays(around midnight: Date) -> [ServiceDay] {
        func serviceDay(offsetDays: Int, endingAfter: Int? = nil, startingBefore: Int? = nil) -> ServiceDay {
            let day = calendar.date(byAdding: .day, value: offsetDays, to: midnight) ?? midnight
            let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
            return ServiceDay(date: (parts.year ?? 0) * 10_000 + (parts.month ?? 0) * 100 + (parts.day ?? 0),
                              weekday: ((parts.weekday ?? 2) + 5) % 7, // Calendar: 1 = Sunday; GTFS bit order: 0 = Monday
                              offsetSeconds: offsetDays * 86_400, tripsEndingAfter: endingAfter, tripsStartingBefore: startingBefore)
        }
        return [serviceDay(offsetDays: -1, endingAfter: 86_400), serviceDay(offsetDays: 0), serviceDay(offsetDays: 1, startingBefore: 8 * 3_600)]
    }

    /// - Parameter acceptingMore: a network already built with other feeds besides will do. Boards only read it, and
    ///   rebuilding for them would throw away the one the trip in progress is being re-planned with.
    private func timetable(for date: Date, near coordinates: [Coordinate], excluding excludedFeedIDs: Set<String> = [],
                           acceptingMore: Bool = false) async -> (Timetable, Date, CacheKey)? {
        let midnight = calendar.startOfDay(for: date)
        let revision = await library.revision
        let days = serviceDays(around: midnight)
        let today = days[1]
        let feedIDs = await library.feedIDs(near: coordinates).filter { !excludedFeedIDs.contains($0) }
        let key = CacheKey(serviceDate: today.date, libraryRevision: revision, feedIDs: feedIDs)
        if let cache, cache.key == key {
            return (cache.timetable, cache.midnight, key)
        }
        if acceptingMore, let cache, cache.key.serviceDate == key.serviceDate, cache.key.libraryRevision == key.libraryRevision,
           Set(key.feedIDs).isSubset(of: cache.key.feedIDs) {
            return (cache.timetable, cache.midnight, cache.key)
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
        // A station stands for the stations a short walk from it too: Farragut North also means the Blue Line at Farragut West.
        // Any stop also stands for the other lines a short walk away, so the Q90's curb doesn't hide the Q70's.
        if case .stop(let feedID, let stopID) = waypoint.kind {
            let place = timetable.boardingPoints(feedID: feedID, stopID: stopID)
            if !place.isEmpty {
                return place.map { StopAccess(stop: $0.stop, seconds: Timetable.walkSeconds(forMeters: $0.meters) + bufferSeconds, meters: $0.meters) }
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
        var geometry = [origin.coordinate]
        var walkingMeters = journey.walkAfter.meters

        for (index, ride) in journey.rides.enumerated() {
            // The first walk was padded with the rider's buffer so the router would allow for it. It is waiting, not walking.
            let walkSeconds = ride.walkBefore.seconds - (index == 0 ? accessBufferSeconds : 0)
            let pattern = timetable.patterns[ride.pattern]
            let route = timetable.routes[pattern.route]
            let source = timetable.routeSources[pattern.route]
            let made = await self.ride(pattern: ride.pattern, trip: ride.trip, board: ride.boardPosition, alight: ride.alightPosition,
                                       in: timetable, midnight: midnight, walkBefore: TimeInterval(max(0, walkSeconds)),
                                       freeTransfer: index == 0 ? nil : timetable.freeTransfer(from: timetable.patterns[journey.rides[index - 1].pattern].stops[journey.rides[index - 1].alightPosition],
                                                                                               to: pattern.stops[ride.boardPosition])?.label)
            rides.append(made)
            let calls = made.stops
            let board = made.board

            // Alerts naming this route and in force when it is ridden (an overnight closure says nothing about
            // the morning); when an alert also names stops, only if the ride touches one of them.
            let boardsAt = Int(board.timeIntervalSince1970)
            let riddenStops = Set(pattern.stops[ride.boardPosition...ride.alightPosition].flatMap { [timetable.stops[$0].id, timetable.stops[timetable.stops[$0].station].id] })
            for alert in snapshot?.feeds[source.feedID]?.alerts ?? [] where alert.isActive(at: boardsAt) && alert.routeIDs.contains(source.routeID) {
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

    /// One trip of a pattern, ridden from one position to another, as the rider sees it.
    private func ride(pattern index: Int, trip: Int, board: Int, alight: Int, in timetable: Timetable, midnight: Date,
                      walkBefore: TimeInterval, freeTransfer: String? = nil) async -> Ride {
        let pattern = timetable.patterns[index]
        let route = timetable.routes[pattern.route]
        let calls = (board...alight).map { position in
            let stop = timetable.stops[pattern.stops[position]]
            let seconds = position == board ? pattern.departure(trip: trip, position: position) : pattern.arrival(trip: trip, position: position)
            return RideStop(station: StationRef(feedID: stop.feedID, stopID: stop.id, name: stop.name, coordinate: stop.coordinate),
                            time: midnight.addingTimeInterval(TimeInterval(seconds)))
        }
        let source = timetable.routeSources[pattern.route]
        let path = await path(feedID: source.feedID, shape: pattern.shapes[trip], calls: calls)
        return Ride(
            routeName: route.name, routeColorHex: route.colorHex, routeTextColorHex: route.textColorHex, routeType: route.type,
            headsign: pattern.headsigns[trip],
            boardStopName: timetable.stops[pattern.stops[board]].name,
            alightStopName: timetable.stops[pattern.stops[alight]].name,
            scheduledBoard: midnight.addingTimeInterval(TimeInterval(pattern.scheduledDeparture(trip: trip, position: board))),
            board: midnight.addingTimeInterval(TimeInterval(pattern.departure(trip: trip, position: board))),
            alight: midnight.addingTimeInterval(TimeInterval(pattern.arrival(trip: trip, position: alight))),
            isRealtime: pattern.isRealtime[trip], stops: calls, walkBefore: walkBefore, path: path,
            freeTransfer: freeTransfer, trip: pattern.trips[trip]
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
