import CommuteCore
import Foundation
import GTFSKit
import Testing
@testable import TransitRouting

/// Builds feeds tersely: `line("L", every: 600, from: 8 * 3600, stops: [("A", 0), ("B", 300)])`.
private struct FeedBuilder {
    var data: FeedTimetableData

    init(feedID: String = "test") {
        data = FeedTimetableData(feedID: feedID, stops: [], routes: [], trips: [], stopTimes: [])
    }

    @discardableResult
    mutating func stop(_ id: String, latitude: Double = 40, longitude: Double = -74, parent: String? = nil) -> Int {
        data.stops.append(.init(id: id, name: id, coordinate: Coordinate(latitude: latitude, longitude: longitude),
                                parent: parent.flatMap { name in data.stops.firstIndex { $0.id == name } }))
        return data.stops.count - 1
    }

    private func index(_ id: String) -> Int {
        data.stops.firstIndex { $0.id == id }!
    }

    /// `stops` are (stop id, seconds after the trip's start). Trips start at each of `starts`.
    mutating func line(_ name: String, starts: [Int], stops: [(String, Int)], noBoarding: Set<String> = []) {
        data.routes.append(RouteBadge(name: name))
        for start in starts {
            let first = data.stopTimes.count
            for (id, offset) in stops {
                data.stopTimes.append(.init(stop: index(id), arrival: start + offset, departure: start + offset, canBoard: !noBoarding.contains(id)))
            }
            data.trips.append(.init(id: "\(name)-\(start - eight)", serviceDate: 20260921, route: data.routes.count - 1,
                                    headsign: stops.last?.0, stopTimes: first..<data.stopTimes.count))
        }
    }

    mutating func transfer(_ from: String, _ to: String, seconds: Int) {
        data.transfers.append(.init(from: index(from), to: index(to), seconds: seconds))
    }
}

private let eight = 8 * 3600

private func every(_ headway: Int, from start: Int, count: Int) -> [Int] {
    (0..<count).map { start + $0 * headway }
}

private extension Timetable {
    func stop(_ id: String) -> Int { stops.firstIndex { $0.id == id }! }

    func describe(_ journey: Journey) -> [String] {
        journey.rides.map { ride in
            let pattern = patterns[ride.pattern]
            let board = pattern.departure(trip: ride.trip, position: ride.boardPosition) - eight
            return "\(routes[pattern.route].name) \(stops[pattern.stops[ride.boardPosition]].id)>\(stops[pattern.stops[ride.alightPosition]].id) @\(board)"
        }
    }

    func arrival(_ journey: Journey) -> Int {
        let last = journey.rides.last!
        return patterns[last.pattern].arrival(trip: last.trip, position: last.alightPosition) + journey.walkAfter.seconds - eight
    }
}

@Suite struct RaptorRouterTests {
    /// Local A-B-C-D every 10 min (20 min end to end); express A-D every 30 min (10 min); branch C2-E from a platform beside C.
    private static func network() -> Timetable {
        var feed = FeedBuilder()
        for id in ["A", "B", "C", "D", "E"] { feed.stop(id, latitude: 40 + Double(feed.data.stops.count)) }
        feed.stop("C2", latitude: 50)
        feed.line("Local", starts: every(600, from: eight, count: 12), stops: [("A", 0), ("B", 300), ("C", 600), ("D", 1200)])
        feed.line("Express", starts: every(1800, from: eight + 900, count: 4), stops: [("A", 0), ("D", 600)])
        feed.line("Branch", starts: every(900, from: eight, count: 8), stops: [("C2", 0), ("E", 600)])
        feed.transfer("C", "C2", seconds: 180)
        return Timetable(feeds: [feed.data])
    }

    @Test func listsUpcomingDeparturesButNotTerminatingTrips() {
        let timetable = Self.network()
        let start = Date(timeIntervalSince1970: TimeInterval(eight + 60))
        let board = timetable.departures(feedID: "test", stopID: "A", from: start, within: 1_800, limit: 10)
        #expect(board.map { "\($0.route.name)>\($0.destination) @\(Int($0.time.timeIntervalSince1970) - eight)" }
                == ["Local>D @600", "Express>D @900", "Local>D @1200", "Local>D @1800"])
        #expect(board.allSatisfy { !$0.isRealtime })
        // Everything reaching D ends there, so nothing departs.
        #expect(timetable.departures(feedID: "test", stopID: "D", from: start, within: 3_600, limit: 10).isEmpty)
    }

    @Test func takesTheNextDirectTrain() {
        let timetable = Self.network()
        let journeys = RaptorRouter(timetable: timetable).journeys(
            from: [StopAccess(stop: timetable.stop("A"))], to: [StopAccess(stop: timetable.stop("C"))], departure: eight + 60)
        #expect(journeys.map(timetable.describe) == [["Local A>C @600"]])
        #expect(timetable.arrival(journeys[0]) == 1200)
    }

    @Test func prefersTheExpressWhenItArrivesFirst() {
        let timetable = Self.network()
        let router = RaptorRouter(timetable: timetable)
        let (a, d) = (timetable.stop("A"), timetable.stop("D"))
        // At 8:10 a local is leaving (arr 8:30), but waiting for the 8:15 express gets there first (8:25).
        let early = router.journeys(from: [StopAccess(stop: a)], to: [StopAccess(stop: d)], departure: eight + 600)
        #expect(early.map(timetable.describe) == [["Express A>D @900"]])
        // At 8:16 the express is gone; the 8:20 local is the only sensible choice.
        let late = router.journeys(from: [StopAccess(stop: a)], to: [StopAccess(stop: d)], departure: eight + 960)
        #expect(late.map(timetable.describe) == [["Local A>D @1200"]])
    }

    @Test func transfersOnFootAndDelaysTheFirstRideToShortenTheWait() {
        let timetable = Self.network()
        let journeys = RaptorRouter(timetable: timetable).journeys(
            from: [StopAccess(stop: timetable.stop("A"))], to: [StopAccess(stop: timetable.stop("E"))], departure: eight)
        // Earliest: 8:00 local reaches C 8:10, walk 3 min, Branch leaves C2 at 8:15. The 8:10 local would reach C
        // at 8:20, too late for 8:15, so the first ride stays put.
        #expect(journeys.map(timetable.describe) == [["Local A>C @0", "Branch C2>E @900"]])
        #expect(journeys[0].rides[1].walkBefore.seconds == 180)
        #expect(timetable.arrival(journeys[0]) == 1500)

        // Boarding mid-line at B: the 8:05 local (C 8:10) is both the first and the last that makes the 8:15 Branch.
        let fromB = RaptorRouter(timetable: timetable).journeys(
            from: [StopAccess(stop: timetable.stop("B"))], to: [StopAccess(stop: timetable.stop("E"))], departure: eight + 60)
        #expect(fromB.map(timetable.describe) == [["Local B>C @300", "Branch C2>E @900"]])
    }

    @Test func aLongerBufferSkipsTightConnections() {
        let timetable = Self.network()
        var router = RaptorRouter(timetable: timetable)
        let (a, e) = (timetable.stop("A"), timetable.stop("E"))

        // The published 3 min C→C2 change already satisfies a 3 min buffer: reach C 8:10, Branch at 8:15.
        router.changeSeconds = 180
        let comfortable = router.journeys(from: [StopAccess(stop: a)], to: [StopAccess(stop: e)], departure: eight)
        #expect(comfortable.map(timetable.describe) == [["Local A>C @0", "Branch C2>E @900"]])

        // Wanting 6 min in hand rules the 8:15 out (only 5 to spare), so ride the later local to meet the 8:30.
        router.changeSeconds = 360
        let cautious = router.journeys(from: [StopAccess(stop: a)], to: [StopAccess(stop: e)], departure: eight)
        #expect(cautious.map(timetable.describe) == [["Local A>C @600", "Branch C2>E @1800"]])
    }

    @Test func theBufferAppliesWhenChangingAtTheSamePlatform() {
        var feed = FeedBuilder()
        for id in ["A", "B", "C"] { feed.stop(id, latitude: 40 + Double(feed.data.stops.count)) }
        feed.line("First", starts: [eight], stops: [("A", 0), ("B", 600)])
        feed.line("Second", starts: every(120, from: eight + 600, count: 5), stops: [("B", 0), ("C", 300)])
        let timetable = Timetable(feeds: [feed.data])
        var router = RaptorRouter(timetable: timetable)
        router.changeSeconds = 180

        let journeys = router.journeys(from: [StopAccess(stop: timetable.stop("A"))], to: [StopAccess(stop: timetable.stop("C"))], departure: eight)
        // Off at B at 8:10. Trains leave B at 8:10, 8:12, 8:14…; the first with 3 min in hand is the 8:14.
        #expect(journeys.map(timetable.describe) == [["First A>B @0", "Second B>C @840"]])
    }

    @Test func groupsDeparturesByLineAndDestinationKeepingTheNextThree() {
        let timetable = Self.network()
        let start = Date(timeIntervalSince1970: TimeInterval(eight + 60))
        let board = timetable.departures(feedID: "test", stopID: "A", from: start, within: 2 * 3_600, limit: 100)
        let groups = DepartureGroup.groups(board)
        #expect(groups.map(\.id) == ["Local|D", "Express|D"])
        #expect(groups.map { $0.departures.map { Int($0.time.timeIntervalSince1970) - eight } } == [[600, 1200, 1800], [900, 2700, 4500]])
    }

    @Test func departingLateSwitchesToALaterFeederTrip() {
        var feed = FeedBuilder()
        for id in ["A", "B", "C"] { feed.stop(id, latitude: 40 + Double(feed.data.stops.count)) }
        feed.line("Feeder", starts: every(300, from: eight, count: 6), stops: [("A", 0), ("B", 300)])
        feed.line("Trunk", starts: [eight + 1500], stops: [("B", 0), ("C", 600)])
        let timetable = Timetable(feeds: [feed.data])
        let journeys = RaptorRouter(timetable: timetable).journeys(
            from: [StopAccess(stop: timetable.stop("A"))], to: [StopAccess(stop: timetable.stop("C"))], departure: eight)
        // The trunk leaves B at 8:25. Feeders reach B at 8:05, 8:10, ... ; with a 60 s change the 8:15 feeder (B 8:20) is the latest that connects.
        #expect(journeys.map(timetable.describe) == [["Feeder A>B @900", "Trunk B>C @1500"]])
    }

    @Test func offersMoreRidesOnlyWhenTheyArriveSooner() {
        var feed = FeedBuilder()
        for id in ["A", "B", "C"] { feed.stop(id, latitude: 40 + Double(feed.data.stops.count)) }
        feed.line("Slow", starts: [eight], stops: [("A", 0), ("C", 3000)])
        feed.line("Hop1", starts: [eight + 60], stops: [("A", 0), ("B", 600)])
        feed.line("Hop2", starts: [eight + 900], stops: [("B", 0), ("C", 600)])
        let timetable = Timetable(feeds: [feed.data])
        let journeys = RaptorRouter(timetable: timetable).journeys(
            from: [StopAccess(stop: timetable.stop("A"))], to: [StopAccess(stop: timetable.stop("C"))], departure: eight)
        #expect(journeys.map(timetable.describe) == [["Slow A>C @0"], ["Hop1 A>B @60", "Hop2 B>C @900"]])
        #expect(journeys.map(timetable.arrival) == [3000, 1500])
    }

    @Test func respectsAccessWalksAndBoardingRestrictions() {
        var feed = FeedBuilder()
        for id in ["A", "B", "C"] { feed.stop(id, latitude: 40 + Double(feed.data.stops.count)) }
        feed.line("L", starts: every(600, from: eight, count: 6), stops: [("A", 0), ("B", 300), ("C", 600)], noBoarding: ["B"])
        let timetable = Timetable(feeds: [feed.data])
        let router = RaptorRouter(timetable: timetable)
        let c = [StopAccess(stop: timetable.stop("C"), seconds: 120, meters: 150)]

        // B is drop-off only, so a rider next to B must use A (7 min walk): misses 8:00, takes 8:10.
        let journeys = router.journeys(from: [StopAccess(stop: timetable.stop("B"), seconds: 60), StopAccess(stop: timetable.stop("A"), seconds: 420, meters: 500)],
                                       to: c, departure: eight)
        #expect(journeys.map(timetable.describe) == [["L A>C @600"]])
        #expect(journeys[0].rides[0].walkBefore.seconds == 420)
        #expect(timetable.arrival(journeys[0]) == 1200 + 120)
        #expect(router.journeys(from: [StopAccess(stop: timetable.stop("C"))], to: [StopAccess(stop: timetable.stop("A"))], departure: eight).isEmpty)
    }

    @Test func linksNearbyStopsOfDifferentFeedsAndStationPlatforms() {
        var rail = FeedBuilder(feedID: "rail")
        rail.stop("R1", latitude: 40.70)
        rail.stop("R2", latitude: 40.75, longitude: -73.99)
        rail.line("Rail", starts: [eight], stops: [("R1", 0), ("R2", 900)])

        var subway = FeedBuilder(feedID: "subway")
        subway.stop("Hub", latitude: 40.7512, longitude: -73.99)
        subway.stop("HubN", latitude: 40.7512, longitude: -73.99, parent: "Hub") // ~130 m from R2
        subway.stop("HubS", latitude: 40.7512, longitude: -73.99, parent: "Hub")
        subway.stop("End", latitude: 40.80)
        subway.line("Sub", starts: every(300, from: eight, count: 12), stops: [("HubN", 0), ("End", 600)])
        subway.line("Other", starts: [eight], stops: [("End", 0), ("HubS", 600)])

        let timetable = Timetable(feeds: [rail.data, subway.data])
        #expect(timetable.platforms(feedID: "subway", stopID: "Hub").map { timetable.stops[$0].id }.sorted() == ["HubN", "HubS"])

        let journeys = RaptorRouter(timetable: timetable).journeys(
            from: [StopAccess(stop: timetable.stop("R1"))], to: [StopAccess(stop: timetable.stop("End"))], departure: eight)
        // Rail arrives 8:15; ~133 m walk ≈ 133 s + 60 s margin -> ready ~8:18:13; next subway 8:20.
        #expect(journeys.map(timetable.describe) == [["Rail R1>R2 @0", "Sub HubN>End @1200"]])
        #expect(journeys[0].rides[1].walkBefore.meters > 100)
    }

    @Test func separatesOvertakingTripsIntoLanes() {
        let slow = Timetable.TripTimes(headsign: nil, arrivals: [0, 1000], departures: [0, 1000])
        let fast = Timetable.TripTimes(headsign: nil, arrivals: [100, 500], departures: [100, 500])
        let later = Timetable.TripTimes(headsign: nil, arrivals: [2000, 3000], departures: [2000, 3000])
        let lanes = Timetable.nonOvertakingLanes([later, fast, slow])
        #expect(lanes.map { $0.map(\.departures[0]) } == [[0, 2000], [100]])
    }

    @Test func dropsOptionsThatLeaveMuchEarlierForLittleGain() {
        func option(leave: TimeInterval, arrive: TimeInterval, rides: Int) -> LegOption {
            let ride = Ride(routeName: "X", boardStopName: "A", alightStopName: "B", scheduledBoard: .distantPast, board: .distantPast, alight: .distantPast)
            return LegOption(mode: .transit, departure: Date(timeIntervalSince1970: leave * 60), arrival: Date(timeIntervalSince1970: arrive * 60),
                             rides: Array(repeating: ride, count: rides))
        }
        let roundabout = option(leave: 52, arrive: 124, rides: 3)
        let nextDirect = option(leave: 91, arrive: 132, rides: 2)
        #expect(TransitPlanner.makesPointless(roundabout, nextDirect))
        #expect(!TransitPlanner.makesPointless(nextDirect, roundabout))
        // Successive trains on a normal headway are all worth showing.
        #expect(!TransitPlanner.makesPointless(option(leave: 10, arrive: 49, rides: 2), option(leave: 18, arrive: 55, rides: 2)))
        // Leaving later and arriving at the same time always wins.
        #expect(TransitPlanner.makesPointless(option(leave: 10, arrive: 49, rides: 2), option(leave: 14, arrive: 49, rides: 2)))
        // ...unless it costs an extra transfer.
        #expect(!TransitPlanner.makesPointless(option(leave: 10, arrive: 49, rides: 1), option(leave: 14, arrive: 49, rides: 2)))
    }
}

@Suite struct RealtimeOverlayTests {
    private static let source = FeedCatalog.feed(id: "mta-lirr")!.realtime!
    private static let midnight = Date(timeIntervalSince1970: 1_800_000_000)

    /// Line L: A -> B -> C every 10 minutes from 8:00, 5 minutes between stops. Trip ids are "L-<seconds after 8:00>".
    private static func network() -> Timetable {
        var feed = FeedBuilder()
        for id in ["A", "B", "C"] { feed.stop(id, latitude: 40 + Double(feed.data.stops.count)) }
        feed.line("L", starts: every(600, from: eight, count: 6), stops: [("A", 0), ("B", 300), ("C", 600)])
        return Timetable(feeds: [feed.data], midnight: midnight)
    }

    private static func update(_ tripID: String, date: Int? = 20260921, canceled: Bool = false, _ stops: [(String, Int)]) -> RealtimeFeed.TripUpdate {
        var update = RealtimeFeed.TripUpdate(tripID: tripID)
        update.startDate = date
        update.isCanceled = canceled
        update.stopTimes = stops.map { stop, time in
            var stopTime = RealtimeFeed.StopTimeUpdate()
            stopTime.stopID = stop
            stopTime.departure = Int(midnight.timeIntervalSince1970) + eight + time
            stopTime.arrival = stopTime.departure
            return stopTime
        }
        return update
    }

    private func firstRide(_ timetable: Timetable, from: String = "A", departure: Int = eight) -> (board: Int, scheduled: Int, arrive: Int, live: Bool)? {
        let journeys = RaptorRouter(timetable: timetable).journeys(
            from: [StopAccess(stop: timetable.stop(from))], to: [StopAccess(stop: timetable.stop("C"))], departure: departure)
        guard let ride = journeys.first?.rides.first else { return nil }
        let pattern = timetable.patterns[ride.pattern]
        return (pattern.departure(trip: ride.trip, position: ride.boardPosition) - eight,
                pattern.scheduledDeparture(trip: ride.trip, position: ride.boardPosition) - eight,
                pattern.arrival(trip: ride.trip, position: ride.alightPosition) - eight, pattern.isRealtime[ride.trip])
    }

    @Test func delaysCarryDownTheLineAndKeepTheScheduledIdentity() throws {
        // The 8:00 train is predicted at B 4 minutes late; C isn't mentioned and inherits the delay.
        let live = Self.network().applying(["test": FeedRealtime(source: Self.source, tripUpdates: [Self.update("L-0", [("B", 540)])])])
        let ride = try #require(firstRide(live, from: "B", departure: eight + 400))
        #expect(ride.board == 540)
        #expect(ride.scheduled == 300)
        #expect(ride.arrive == 840)
        #expect(ride.live)
        // A was already behind the train when the update was issued, so it keeps its scheduled time.
        #expect(firstRide(live)?.board == 0)
    }

    @Test func aLateTrainCanStillBeCaught() throws {
        // Arriving at A at 8:01 misses the 8:00 on paper, but it's running 3 minutes late.
        let scheduled = Self.network()
        #expect(firstRide(scheduled, departure: eight + 60)?.board == 600)
        let live = scheduled.applying(["test": FeedRealtime(source: Self.source, tripUpdates: [Self.update("L-0", [("A", 180), ("B", 480), ("C", 780)])])])
        let ride = try #require(firstRide(live, departure: eight + 60))
        #expect(ride.board == 180)
        #expect(ride.arrive == 780)
    }

    @Test func cancelledTripsDisappearAndOtherDaysAreIgnored() {
        let scheduled = Self.network()
        let cancelled = scheduled.applying(["test": FeedRealtime(source: Self.source, tripUpdates: [Self.update("L-0", canceled: true, [])])])
        #expect(firstRide(cancelled)?.board == 600)
        // Same trip_id but yesterday's run: not this train.
        let yesterday = scheduled.applying(["test": FeedRealtime(source: Self.source, tripUpdates: [Self.update("L-0", date: 20260920, canceled: true, [])])])
        #expect(firstRide(yesterday)?.board == 0)
        // An update whose stops aren't on the trip changes nothing and isn't flagged live.
        let unrelated = scheduled.applying(["test": FeedRealtime(source: Self.source, tripUpdates: [Self.update("L-0", [("Z", 999)])])])
        #expect(firstRide(unrelated)?.live == false)
    }

    @Test func aTrainOvertakenMidRouteStillRoutesCorrectly() throws {
        // The 8:00 leaves A on time but is held before B until 8:16:40, so the 8:10 (B at 8:15) passes it.
        // Binary search needs trips ordered at every stop, so the two must land in separate lanes.
        let live = Self.network().applying(["test": FeedRealtime(source: Self.source, tripUpdates: [Self.update("L-0", [("A", 0), ("B", 1000), ("C", 1300)])])])
        #expect(live.patterns.count == 2)
        // From A at 8:01 the held train is gone; the 8:10 is next and is not slowed by the train it passes.
        let fromA = try #require(firstRide(live, departure: eight + 60))
        #expect(fromA.board == 600)
        #expect(fromA.arrive == 1200)
        // At B at 8:15:30 the 8:10 has just left; the held 8:00 comes next, well before the 8:20's 8:25 call.
        let fromB = try #require(firstRide(live, from: "B", departure: eight + 930))
        #expect(fromB.board == 1000)
        #expect(fromB.arrive == 1300)
    }
}
