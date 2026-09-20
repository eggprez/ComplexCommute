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
            data.trips.append(.init(route: data.routes.count - 1, headsign: stops.last?.0, stopTimes: first..<data.stopTimes.count))
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
