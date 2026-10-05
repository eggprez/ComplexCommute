import CommuteCore
import Foundation

/// One calendar day of service to load. Trip times are shifted by `offsetSeconds` so that several
/// service days share one clock measured from the base day's midnight.
public struct ServiceDay: Hashable, Sendable {
    /// yyyymmdd, as GTFS writes dates.
    public let date: Int
    /// 0 = Monday ... 6 = Sunday.
    public let weekday: Int
    public let offsetSeconds: Int
    /// Only trips running at or after this service-day time (e.g. 24:00 for yesterday's late trips).
    public let tripsEndingAfter: Int?
    /// Only trips starting before this service-day time (e.g. 08:00 for tomorrow's early trips).
    public let tripsStartingBefore: Int?

    public init(date: Int, weekday: Int, offsetSeconds: Int, tripsEndingAfter: Int? = nil, tripsStartingBefore: Int? = nil) {
        self.date = date
        self.weekday = weekday
        self.offsetSeconds = offsetSeconds
        self.tripsEndingAfter = tripsEndingAfter
        self.tripsStartingBefore = tripsStartingBefore
    }
}

/// The schedule of one feed for a set of service days, as flat arrays ready for a router to index.
public struct FeedTimetableData: Sendable {
    public struct Stop: Sendable {
        public var id: String
        public var name: String
        public var coordinate: Coordinate
        /// Index of the parent station in `stops`, for platforms.
        public var parent: Int?

        public init(id: String, name: String, coordinate: Coordinate, parent: Int? = nil) {
            self.id = id
            self.name = name
            self.coordinate = coordinate
            self.parent = parent
        }
    }

    public struct Trip: Sendable {
        /// The feed's trip_id, which realtime updates refer to.
        public var id: String
        /// The requested service day (yyyymmdd) this instance of the trip runs on.
        public var serviceDate: Int
        public var route: Int
        public var headsign: String?
        /// Index of the feed's shape this trip follows, fetched from the library when a ride is drawn.
        public var shape: Int?
        /// Range of this trip's calls in `stopTimes`.
        public var stopTimes: Range<Int>

        public init(id: String = "", serviceDate: Int = 0, route: Int, headsign: String? = nil, shape: Int? = nil, stopTimes: Range<Int>) {
            self.id = id
            self.serviceDate = serviceDate
            self.route = route
            self.headsign = headsign
            self.shape = shape
            self.stopTimes = stopTimes
        }
    }

    public struct StopTime: Sendable {
        public var stop: Int
        /// Seconds from the base day's midnight (already shifted by the service day's offset).
        public var arrival: Int
        public var departure: Int
        public var canBoard: Bool
        public var canAlight: Bool

        public init(stop: Int, arrival: Int, departure: Int, canBoard: Bool = true, canAlight: Bool = true) {
            self.stop = stop
            self.arrival = arrival
            self.departure = departure
            self.canBoard = canBoard
            self.canAlight = canAlight
        }
    }

    public struct Transfer: Sendable {
        public var from: Int
        public var to: Int
        public var seconds: Int?

        public init(from: Int, to: Int, seconds: Int? = nil) {
            self.from = from
            self.to = to
            self.seconds = seconds
        }
    }

    public var feedID: String
    public var stops: [Stop]
    public var routes: [RouteBadge]
    /// The feed's route_id for each entry of `routes`, which alerts refer to.
    public var routeIDs: [String]
    public var trips: [Trip]
    public var stopTimes: [StopTime]
    public var transfers: [Transfer]

    public init(feedID: String, stops: [Stop], routes: [RouteBadge], routeIDs: [String]? = nil, trips: [Trip], stopTimes: [StopTime], transfers: [Transfer] = []) {
        self.feedID = feedID
        self.stops = stops
        self.routes = routes
        self.routeIDs = routeIDs ?? routes.map(\.name)
        self.trips = trips
        self.stopTimes = stopTimes
        self.transfers = transfers
    }
}

extension FeedDatabase {
    /// True if `coordinate` is within `marginMeters` of the feed's service area (bounding-box test).
    func covers(_ coordinate: Coordinate, marginMeters: Double) -> Bool {
        guard let box = boundingBox else { return false }
        let latitudeMargin = marginMeters / 111_000
        let longitudeMargin = latitudeMargin / max(0.1, cos(coordinate.latitude * .pi / 180))
        return coordinate.latitude >= box.minLatitude - latitudeMargin && coordinate.latitude <= box.maxLatitude + latitudeMargin
            && coordinate.longitude >= box.minLongitude - longitudeMargin && coordinate.longitude <= box.maxLongitude + longitudeMargin
    }

    func loadBoundingBox() -> BoundingBox? {
        guard let statement = try? database.prepare("SELECT MIN(lat), MAX(lat), MIN(lon), MAX(lon) FROM stops WHERE searchable = 1"),
              (try? statement.step()) == true, statement.optionalInt(0) != nil else { return nil }
        return BoundingBox(minLatitude: statement.double(0), maxLatitude: statement.double(1),
                           minLongitude: statement.double(2), maxLongitude: statement.double(3))
    }

    /// The last day the feed's calendar covers (yyyymmdd).
    func lastServiceDate() throws -> Int? {
        let statement = try database.prepare("SELECT MAX(d) FROM (SELECT MAX(end_date) AS d FROM calendar UNION ALL SELECT MAX(date) FROM calendar_dates)")
        return try statement.step() ? statement.optionalInt(0) : nil
    }

    /// `date` itself while the calendar covers it; otherwise the latest covered date on the same weekday.
    static func fallbackDate(for date: Int, lastServiceDate: Int) -> Int {
        guard date > lastServiceDate else { return date }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func day(_ value: Int) -> Date? {
            calendar.date(from: DateComponents(year: value / 10_000, month: value / 100 % 100, day: value % 100))
        }
        guard let target = day(date), let last = day(lastServiceDate),
              let daysPast = calendar.dateComponents([.day], from: last, to: target).day,
              let fallback = calendar.date(byAdding: .day, value: -((daysPast + 6) / 7) * 7, to: target) else { return date }
        let parts = calendar.dateComponents([.year, .month, .day], from: fallback)
        return (parts.year ?? 0) * 10_000 + (parts.month ?? 0) * 100 + (parts.day ?? 0)
    }

    private func routeTable() throws -> (routes: [RouteBadge], ids: [String]) {
        var routes: [RouteBadge] = []
        var routeIDs: [String] = []
        let routeRows = try database.prepare("SELECT short_name, long_name, color, text_color, type, route_id FROM routes ORDER BY route_idx")
        while try routeRows.step() {
            routeIDs.append(routeRows.string(5) ?? "")
            routes.append(RouteBadge(name: routeRows.string(0) ?? routeRows.string(1) ?? "", colorHex: routeRows.string(2),
                                     textColorHex: routeRows.string(3), type: routeRows.int(4)))
        }
        return (routes, routeIDs)
    }

    /// Which of `days` each service runs on.
    private func daysByService(_ days: [ServiceDay]) throws -> [Int: [ServiceDay]] {
        var daysByService: [Int: [ServiceDay]] = [:]
        let activeServices = try database.prepare("""
            SELECT service_idx FROM calendar WHERE start_date <= ?1 AND end_date >= ?1 AND (weekdays & ?2) != 0
                AND service_idx NOT IN (SELECT service_idx FROM calendar_dates WHERE date = ?1 AND exception_type = 2)
            UNION SELECT service_idx FROM calendar_dates WHERE date = ?1 AND exception_type = 1
            """)
        let lastDate = try lastServiceDate()
        for day in days {
            activeServices.reset()
            // Agencies sometimes let a feed's calendar lapse while the trains keep running to it.
            // Past the end, plan with the same weekday from the last published week.
            activeServices.bind(lastDate.map { Self.fallbackDate(for: day.date, lastServiceDate: $0) } ?? day.date, at: 1)
            activeServices.bind(1 << day.weekday, at: 2)
            while try activeServices.step() {
                daysByService[activeServices.int(0), default: []].append(day)
            }
        }
        return daysByService
    }

    var hasBoardIndex: Bool {
        guard let statement = try? database.prepare("SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = 'stop_times_by_stop'") else { return false }
        return (try? statement.step()) == true
    }

    /// The schedule cut down to the trips that call at `stopIDs` (stations, or stops in their own right) within
    /// `window`, in seconds from the base day's midnight. Those trips are whole, so a board can say where each is
    /// going; everything else about the feed is left on disk. A departure board near the rider needs no more, and a
    /// widget has the memory for no more.
    func timetableData(for days: [ServiceDay], callingAt stopIDs: [String], between window: Range<Int>) throws -> FeedTimetableData {
        let (routes, routeIDs) = try routeTable()
        let daysByService = try daysByService(days)

        // The stops asked for, and the platforms of the ones that are stations.
        var wanted = Set<Int>()
        let platforms = try database.prepare("SELECT stop_idx FROM stops WHERE stop_id = ?1 OR parent_id = ?1")
        for id in stopIDs {
            platforms.reset()
            platforms.bind(id, at: 1)
            while try platforms.step() { wanted.insert(platforms.int(0)) }
        }

        struct TripRow {
            var id: String
            var route: Int
            var service: Int
            var headsign: String?
            var shape: Int?
        }
        var tripRows: [Int: TripRow?] = [:]
        let tripStatement = try database.prepare("SELECT route_idx, service_idx, headsign, trip_id, \(hasShapes ? "shape_idx" : "NULL") FROM trips WHERE trip_idx = ?")
        func tripRow(_ index: Int) throws -> TripRow? {
            if let known = tripRows[index] { return known }
            tripStatement.reset()
            tripStatement.bind(index, at: 1)
            let row = try tripStatement.step()
                ? TripRow(id: tripStatement.string(3) ?? "", route: tripStatement.int(0), service: tripStatement.int(1),
                          headsign: tripStatement.string(2), shape: tripStatement.optionalInt(4))
                : nil
            tripRows[index] = .some(row)
            return row
        }

        // Every call at those stops, on any day; which of them fall in the window depends on the day each trip runs.
        var tripDays: [Int: [ServiceDay]] = [:]
        if !wanted.isEmpty {
            let calls = try database.prepare("""
                SELECT trip_idx, departure FROM stop_times
                WHERE stop_idx IN (\(wanted.sorted().map(String.init).joined(separator: ","))) AND departure IS NOT NULL
                """)
            while try calls.step() {
                let (trip, departure) = (calls.int(0), calls.int(1))
                guard let row = try tripRow(trip), let running = daysByService[row.service] else { continue }
                for day in running where window.contains(departure + day.offsetSeconds) && !(tripDays[trip]?.contains(day) ?? false) {
                    tripDays[trip, default: []].append(day)
                }
            }
        }

        var trips: [FeedTimetableData.Trip] = []
        var stopTimes: [FeedTimetableData.StopTime] = []
        let callRows = try database.prepare("SELECT stop_idx, arrival, departure, pickup_type, drop_off_type FROM stop_times WHERE trip_idx = ? ORDER BY seq")
        for (trip, days) in tripDays.sorted(by: { $0.key < $1.key }) {
            guard let row = try tripRow(trip) else { continue }
            callRows.reset()
            callRows.bind(trip, at: 1)
            var calls: [FeedTimetableData.StopTime] = []
            while try callRows.step() {
                guard let arrival = callRows.optionalInt(1), let departure = callRows.optionalInt(2) else { continue }
                calls.append(.init(stop: callRows.int(0), arrival: arrival, departure: departure,
                                   canBoard: callRows.int(3) != 1, canAlight: callRows.int(4) != 1))
            }
            guard calls.count >= 2 else { continue }
            for day in days {
                let start = stopTimes.count
                for call in calls {
                    var shifted = call
                    shifted.arrival += day.offsetSeconds
                    shifted.departure += day.offsetSeconds
                    stopTimes.append(shifted)
                }
                trips.append(.init(id: row.id, serviceDate: day.date, route: row.route, headsign: row.headsign, shape: row.shape, stopTimes: start..<stopTimes.count))
            }
        }

        // Only the stops those trips touch, their stations, and what was asked for, renumbered to stand alone.
        var used = wanted.union(stopTimes.map(\.stop))
        var rows: [Int: FeedTimetableData.Stop] = [:]
        let stopRow = try database.prepare("SELECT stop_id, name, lat, lon, parent_idx FROM stops WHERE stop_idx = ?")
        var pending = Array(used)
        while let index = pending.popLast() {
            stopRow.reset()
            stopRow.bind(index, at: 1)
            guard try stopRow.step() else { continue }
            let parent = stopRow.optionalInt(4)
            rows[index] = .init(id: stopRow.string(0) ?? "", name: stopRow.string(1) ?? "",
                                coordinate: Coordinate(latitude: stopRow.double(2), longitude: stopRow.double(3)), parent: parent)
            if let parent, used.insert(parent).inserted { pending.append(parent) }
        }
        let order = rows.keys.sorted()
        let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        let stops = order.compactMap { index -> FeedTimetableData.Stop? in
            guard var stop = rows[index] else { return nil }
            stop.parent = stop.parent.flatMap { position[$0] }
            return stop
        }
        // A call at a stop the feed never defined can't be drawn or boarded; the importer keeps none, but be safe.
        guard stopTimes.allSatisfy({ position[$0.stop] != nil }) else {
            return FeedTimetableData(feedID: feedID, stops: [], routes: routes, routeIDs: routeIDs, trips: [], stopTimes: [])
        }
        for index in stopTimes.indices {
            stopTimes[index].stop = position[stopTimes[index].stop] ?? 0
        }
        return FeedTimetableData(feedID: feedID, stops: stops, routes: routes, routeIDs: routeIDs, trips: trips, stopTimes: stopTimes)
    }

    func timetableData(for days: [ServiceDay]) throws -> FeedTimetableData {
        var stops: [FeedTimetableData.Stop] = []
        let stopRows = try database.prepare("SELECT stop_id, name, lat, lon, parent_idx FROM stops ORDER BY stop_idx")
        while try stopRows.step() {
            stops.append(.init(id: stopRows.string(0) ?? "", name: stopRows.string(1) ?? "",
                               coordinate: Coordinate(latitude: stopRows.double(2), longitude: stopRows.double(3)),
                               parent: stopRows.optionalInt(4)))
        }

        let (routes, routeIDs) = try routeTable()

        var transfers: [FeedTimetableData.Transfer] = []
        let transferRows = try database.prepare("SELECT from_stop_idx, to_stop_idx, min_time FROM transfers WHERE type != 3")
        while try transferRows.step() {
            transfers.append(.init(from: transferRows.int(0), to: transferRows.int(1), seconds: transferRows.optionalInt(2)))
        }

        let daysByService = try daysByService(days)

        struct TripRow {
            var id: String
            var route: Int
            var headsign: String?
            var shape: Int?
            var days: [ServiceDay]
        }
        var tripRows: [Int: TripRow] = [:]
        let tripStatement = try database.prepare("SELECT trip_idx, route_idx, service_idx, headsign, trip_id, \(hasShapes ? "shape_idx" : "NULL") FROM trips")
        while try tripStatement.step() {
            guard let days = daysByService[tripStatement.int(2)] else { continue }
            tripRows[tripStatement.int(0)] = TripRow(id: tripStatement.string(4) ?? "", route: tripStatement.int(1), headsign: tripStatement.string(3),
                                                       shape: tripStatement.optionalInt(5), days: days)
        }

        var trips: [FeedTimetableData.Trip] = []
        var stopTimes: [FeedTimetableData.StopTime] = []
        var calls: [FeedTimetableData.StopTime] = []
        var currentTrip = -1

        func flush() {
            defer { calls.removeAll(keepingCapacity: true) }
            guard calls.count >= 2, let row = tripRows[currentTrip], let first = calls.first, let last = calls.last else { return }
            for day in row.days {
                if let after = day.tripsEndingAfter, last.arrival < after { continue }
                if let before = day.tripsStartingBefore, first.departure >= before { continue }
                let start = stopTimes.count
                for call in calls {
                    var shifted = call
                    shifted.arrival += day.offsetSeconds
                    shifted.departure += day.offsetSeconds
                    stopTimes.append(shifted)
                }
                trips.append(.init(id: row.id, serviceDate: day.date, route: row.route, headsign: row.headsign, shape: row.shape, stopTimes: start..<stopTimes.count))
            }
        }

        // Primary-key order is (trip, sequence), so each trip's calls arrive together and in order.
        let callRows = try database.prepare("SELECT trip_idx, stop_idx, arrival, departure, pickup_type, drop_off_type FROM stop_times ORDER BY trip_idx, seq")
        while try callRows.step() {
            let trip = callRows.int(0)
            if trip != currentTrip {
                flush()
                currentTrip = trip
            }
            // Calls without times (non-timepoints) can't be boarded against a clock; skip them.
            guard tripRows[trip] != nil, let arrival = callRows.optionalInt(2), let departure = callRows.optionalInt(3) else { continue }
            calls.append(.init(stop: callRows.int(1), arrival: arrival, departure: departure,
                               canBoard: callRows.int(4) != 1, canAlight: callRows.int(5) != 1))
        }
        flush()

        return FeedTimetableData(feedID: feedID, stops: stops, routes: routes, routeIDs: routeIDs, trips: trips, stopTimes: stopTimes, transfers: transfers)
    }
}
