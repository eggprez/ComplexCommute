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

    @Test func listsOnlyVehiclesThatStopWhereTheRiderIsGoing() {
        let timetable = Self.network()
        let start = Date(timeIntervalSince1970: TimeInterval(eight + 60))
        // The express runs A to D without stopping at C, so only locals go "toward" C; both lines go to D.
        let toC = timetable.departures(feedID: "test", stopID: "A", toward: ("test", "C"), from: start, within: 1_800, limit: 10)
        #expect(toC.map { "\($0.route.name) @\(Int($0.time.timeIntervalSince1970) - eight)" } == ["Local @600", "Local @1200", "Local @1800"])
        let toD = timetable.departures(feedID: "test", stopID: "A", toward: ("test", "D"), from: start, within: 1_800, limit: 10)
        #expect(toD.map(\.route.name) == ["Local", "Express", "Local", "Local"])
        // Nothing from B goes back to A, and a station nobody serves has no departures toward it.
        #expect(timetable.departures(feedID: "test", stopID: "B", toward: ("test", "A"), from: start, within: 3_600, limit: 10).isEmpty)
        #expect(timetable.departures(feedID: "test", stopID: "A", toward: ("test", "nowhere"), from: start, within: 3_600, limit: 10).isEmpty)
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

    /// Red and Blue share X-W-Y, then part: Red to P, Blue to Z. Red comes first, Blue three minutes behind it.
    private static func sharedTrunk() -> Timetable {
        var feed = FeedBuilder()
        for id in ["O", "X", "W", "Y", "P", "Z"] { feed.stop(id, latitude: 40 + Double(feed.data.stops.count)) }
        feed.line("Feeder", starts: [eight], stops: [("O", 0), ("X", 300)])
        feed.line("Red", starts: every(600, from: eight + 600, count: 4), stops: [("X", 0), ("W", 200), ("Y", 400), ("P", 900)])
        feed.line("Blue", starts: every(600, from: eight + 780, count: 4), stops: [("X", 0), ("W", 200), ("Y", 400), ("Z", 900)])
        return Timetable(feeds: [feed.data])
    }

    @Test func waitsForTheThroughTrainRatherThanRidingTheOneAheadOfItToWhereTheyPart() {
        let timetable = Self.sharedTrunk()
        let router = RaptorRouter(timetable: timetable)
        let journeys = router.journeys(from: [StopAccess(stop: timetable.stop("X"))], to: [StopAccess(stop: timetable.stop("Z"))], departure: eight + 500)
        #expect(journeys.map(timetable.describe) == [["Blue X>Z @780"]])

        // The same holds for a change further into the trip: off the feeder, onto Blue, not Red-then-Blue.
        let fromAfar = router.journeys(from: [StopAccess(stop: timetable.stop("O"))], to: [StopAccess(stop: timetable.stop("Z"))], departure: eight)
        #expect(fromAfar.map(timetable.describe) == [["Feeder O>X @0", "Blue X>Z @780"]])
    }

    @Test func aChangeOntoTheTrainBehindIsFoldedIntoWaitingForIt() throws {
        let timetable = Self.sharedTrunk()
        let router = RaptorRouter(timetable: timetable)
        func pattern(_ name: String) throws -> Int {
            try #require(timetable.patterns.firstIndex { timetable.routes[$0.route].name == name })
        }
        let feeder = Journey.Ride(pattern: try pattern("Feeder"), trip: 0, boardPosition: 0, alightPosition: 1, walkBefore: Journey.Walk(seconds: 120, meters: 150))
        let red = Journey.Ride(pattern: try pattern("Red"), trip: 0, boardPosition: 0, alightPosition: 2, walkBefore: Journey.Walk())
        let blue = Journey.Ride(pattern: try pattern("Blue"), trip: 0, boardPosition: 2, alightPosition: 3, walkBefore: Journey.Walk())

        let folded = router.stayingAboard(Journey(rides: [feeder, red, blue], walkAfter: Journey.Walk()))
        #expect(timetable.describe(folded) == ["Feeder O>X @0", "Blue X>Z @780"])

        // The walk to the first train becomes the walk to the one waited for.
        let direct = router.stayingAboard(Journey(rides: [Journey.Ride(pattern: red.pattern, trip: 0, boardPosition: 0, alightPosition: 2, walkBefore: feeder.walkBefore), blue],
                                                  walkAfter: Journey.Walk()))
        #expect(timetable.describe(direct) == ["Blue X>Z @780"])
        #expect(direct.rides.first?.walkBefore.seconds == 120)

        // A Blue that came through before the Red being ridden is a real connection (Red overtook it), and stays.
        let earlierBlue = Journey.Ride(pattern: blue.pattern, trip: 0, boardPosition: 2, alightPosition: 3, walkBefore: Journey.Walk())
        let laterRed = Journey.Ride(pattern: red.pattern, trip: 1, boardPosition: 0, alightPosition: 2, walkBefore: Journey.Walk())
        let kept = router.stayingAboard(Journey(rides: [laterRed, earlierBlue], walkAfter: Journey.Walk()))
        #expect(kept.rides.count == 2)
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

    /// Farragut North and Farragut West: two stations ~200 m apart, with a street corner of bus stops between them.
    private static func farragut() -> Timetable {
        var metro = FeedBuilder(feedID: "metro")
        metro.stop("North", latitude: 38.9031, longitude: -77.0397)
        metro.stop("NorthP", latitude: 38.9031, longitude: -77.0397, parent: "North")
        metro.stop("West", latitude: 38.9013, longitude: -77.0405)
        metro.stop("WestP1", latitude: 38.9013, longitude: -77.0405, parent: "West")
        metro.stop("WestP2", latitude: 38.9013, longitude: -77.0405, parent: "West")
        metro.stop("Far", latitude: 38.9031, longitude: -77.0320) // ~670 m east: not the same place
        for id in ["Red1", "Blue1", "Blue2", "Far1"] { metro.stop(id, latitude: 39 + Double(metro.data.stops.count) / 10) }
        metro.line("Red", starts: every(600, from: eight, count: 6), stops: [("Red1", 0), ("NorthP", 600)])
        metro.line("Blue", starts: every(600, from: eight, count: 6), stops: [("WestP1", 0), ("Blue1", 600)])
        metro.line("Blue back", starts: every(600, from: eight, count: 6), stops: [("Blue2", 0), ("WestP2", 600)])
        metro.line("Far", starts: every(600, from: eight, count: 6), stops: [("Far", 0), ("Far1", 600)])

        // A dozen bus stops, all nearer Farragut North than Farragut West is, and all on one route.
        var bus = FeedBuilder(feedID: "bus")
        for index in 0..<12 { bus.stop("B\(index)", latitude: 38.9031 + Double(index) * 0.0001, longitude: -77.0395) }
        bus.data.routes.append(RouteBadge(name: "Bus", type: 3))
        let calls = (0..<12).map { FeedTimetableData.StopTime(stop: $0, arrival: eight + $0 * 60, departure: eight + $0 * 60) }
        bus.data.stopTimes = calls
        bus.data.trips = [.init(id: "bus", serviceDate: 20260921, route: 0, headsign: nil, stopTimes: 0..<calls.count)]
        return Timetable(feeds: [metro.data, bus.data])
    }

    @Test func aCrowdOfBusStopsCannotHideTheStationAcrossTheStreet() {
        let timetable = Self.farragut()
        let north = timetable.stop("NorthP")
        let linked = timetable.footpaths[north].map { timetable.stops[$0.to].id }
        // Both Farragut West platforms, and of the bus stops only the one nearest: the rest lead nowhere new.
        #expect(linked.contains("WestP1") && linked.contains("WestP2"))
        #expect(linked.filter { $0.hasPrefix("B") }.count == 1)

        let journeys = RaptorRouter(timetable: timetable).journeys(
            from: [StopAccess(stop: timetable.stop("Red1"))], to: [StopAccess(stop: timetable.stop("Blue1"))], departure: eight)
        #expect(journeys.map(timetable.describe).first == ["Red Red1>NorthP @0", "Blue WestP1>Blue1 @1200"])
    }

    @Test func aStationAlsoMeansTheStationsAFiveMinuteWalkAway() {
        let timetable = Self.farragut()
        let place = timetable.samePlace(feedID: "metro", stopID: "North")
        #expect(place.map { timetable.stops[$0.stop].id } == ["NorthP", "WestP1", "WestP2"])
        #expect(place[0].meters == 0)
        #expect(place[1].meters > 150 && place[1].meters < Timetable.samePlaceMeters)

        let neighbors = timetable.stationsInSamePlace(feedID: "metro", stopID: "North")
        #expect(neighbors.map(\.station.id) == ["West"])
        #expect(timetable.stationsInSamePlace(feedID: "metro", stopID: "Far").isEmpty)
    }

    @Test func aStopAlsoMeansTheOtherLinesAShortWalkAway() {
        // LaGuardia Terminal B: the Q90 and Q70 stop at separate curbs 30 m apart; another Q90 stop is further along.
        var bus = FeedBuilder(feedID: "bus")
        bus.stop("Q90-B", latitude: 40.7730, longitude: -73.8710)
        bus.stop("Q70-B", latitude: 40.7733, longitude: -73.8710)
        bus.stop("Q90-C", latitude: 40.7736, longitude: -73.8710)
        bus.stop("Q72-Far", latitude: 40.7800, longitude: -73.8710) // ~780 m: not a short walk
        for id in ["Q90-End", "Woodside", "Q72-End"] { bus.stop(id, latitude: 41 + Double(bus.data.stops.count) / 10) }
        bus.line("Q90", starts: [eight], stops: [("Q90-B", 0), ("Q90-C", 60), ("Q90-End", 1200)])
        bus.line("Q70", starts: [eight], stops: [("Q70-B", 0), ("Woodside", 600)])
        bus.line("Q72", starts: [eight], stops: [("Q72-Far", 0), ("Q72-End", 600)])
        bus.data.routes = bus.data.routes.map { RouteBadge(name: $0.name, type: 3) }
        let timetable = Timetable(feeds: [bus.data])

        let points = timetable.boardingPoints(feedID: "bus", stopID: "Q90-B")
        // The Q70's curb, but not the Q90's own next stop (nothing new) or the Q72 (too far).
        #expect(points.map { timetable.stops[$0.stop].id } == ["Q90-B", "Q70-B"])
        #expect(points[1].meters > 20 && points[1].meters < 50)
        // Station boards still only look for other stations.
        #expect(timetable.samePlace(feedID: "bus", stopID: "Q90-B").map { timetable.stops[$0.stop].id } == ["Q90-B"])
    }

    @Test func namesTheAgencysFreeTransferBetweenSeparateStations() {
        var metro = FeedBuilder(feedID: "wmata-rail")
        metro.stop("STN_A02", latitude: 38.9031, longitude: -77.0397)
        metro.stop("PF_A02_C", latitude: 38.9031, longitude: -77.0397, parent: "STN_A02")
        metro.stop("STN_C03", latitude: 38.9013, longitude: -77.0405)
        metro.stop("PF_C03_1", latitude: 38.9013, longitude: -77.0405, parent: "STN_C03")
        metro.stop("STN_C02", latitude: 38.9013, longitude: -77.0335)
        metro.stop("PF_C02_1", latitude: 38.9013, longitude: -77.0335, parent: "STN_C02")
        metro.line("Red", starts: [eight], stops: [("PF_A02_C", 0), ("PF_C02_1", 600)])
        let timetable = Timetable(feeds: [metro.data])
        let (north, west, mcpherson) = (timetable.stop("PF_A02_C"), timetable.stop("PF_C03_1"), timetable.stop("PF_C02_1"))

        #expect(timetable.freeTransfer(from: north, to: west)?.label == "Farragut Crossing: free with SmarTrip within 30 min")
        #expect(timetable.freeTransfer(from: west, to: north)?.name == "Farragut Crossing")
        #expect(timetable.freeTransfer(from: north, to: mcpherson) == nil)
        #expect(timetable.freeTransfer(from: north, to: north) == nil)
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

@Test func loganShuttlesTakeTheBlueLineToTheTerminalsDayAndNight() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("logan-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let feedID = "boston-airport-links"
    let library = FeedLibrary(directory: directory)
    _ = try await library.install(feedID: feedID, files: BuiltInFeeds.files(for: feedID))
    let day = ServiceDay(date: 20260921, weekday: 0, offsetSeconds: 0)
    let timetable = Timetable(feeds: await library.timetableData(for: [day], feedIDs: [feedID]))

    func next(at hour: Double) -> [String] {
        timetable.departures(feedID: feedID, stopID: "bos-blue", toward: (feedID, "bos-a"),
                             from: Date(timeIntervalSince1970: hour * 3600), within: 900, limit: 20).map(\.route.name)
    }
    // By day the 22 and the 88; late at night the 55 stands in for the 22. The 33 never goes to Terminal A.
    #expect(Set(next(at: 10)) == ["22", "88"])
    #expect(Set(next(at: 23)) == ["55", "88"])
    #expect(timetable.departures(feedID: feedID, stopID: "bos-blue", toward: (feedID, "bos-e"),
                                 from: Date(timeIntervalSince1970: 10 * 3600), within: 900, limit: 20).contains { $0.route.name == "33" })
}
