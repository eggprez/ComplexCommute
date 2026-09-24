import Foundation
import Testing
@testable import CommuteCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private let home = Waypoint(name: "Home", coordinate: Coordinate(latitude: 40.70, longitude: -74.10))
private let stationA = Waypoint(name: "Station A", coordinate: Coordinate(latitude: 40.72, longitude: -74.05), kind: .stop(feedID: "f", stopID: "A"))
private let stationC = Waypoint(name: "Station C", coordinate: Coordinate(latitude: 40.75, longitude: -73.99), kind: .stop(feedID: "f", stopID: "C"))
private let office = Waypoint(name: "Office", coordinate: Coordinate(latitude: 40.755, longitude: -73.985))
private let template = TripTemplate(waypoints: [home, stationA, stationC, office], modes: [.drive, .transit, .walk])

private func stop(_ name: String, _ offset: TimeInterval) -> RideStop {
    RideStop(station: StationRef(feedID: "f", stopID: name, name: name, coordinate: stationA.coordinate), time: t0 + offset)
}

/// Drive 5–15 min, the A at +20 to Station B (two stops), change to the B at +35 to Station C, walk 5 min.
private func itinerary() -> Itinerary {
    let first = Ride(routeName: "A", colorHex: "0039A6", headsign: "Uptown", boardStopName: "Station A", alightStopName: "Station B",
                     scheduledBoard: t0 + 1200, board: t0 + 1200, alight: t0 + 1800,
                     stops: [stop("Station A", 1200), stop("Midway", 1500), stop("Station B", 1800)])
    let second = Ride(routeName: "B", boardStopName: "Station B", alightStopName: "Station C",
                      scheduledBoard: t0 + 2100, board: t0 + 2220, alight: t0 + 2700, isRealtime: true, walkBefore: 180)
    return Itinerary(legs: [
        Leg(segmentIndex: 0, from: home, to: stationA, option: LegOption(mode: .drive, departure: t0 + 300, arrival: t0 + 900)),
        Leg(segmentIndex: 1, from: stationA, to: stationC, option: LegOption(mode: .transit, departure: t0 + 1200, arrival: t0 + 2700, rides: [first, second])),
        Leg(segmentIndex: 2, from: stationC, to: office, option: LegOption(mode: .walk, departure: t0 + 2700, arrival: t0 + 3000)),
    ])
}

/// The same trip with the second ride's stops filled in, which is what a change needs to be looked up from.
private func withStops(_ itinerary: Itinerary) -> Itinerary {
    var legs = itinerary.legs
    var option = legs[1].option
    option.rides[1].stops = [stop("Station B", 2220), stop("Station C", 2700)]
    legs[1] = Leg(segmentIndex: legs[1].segmentIndex, from: legs[1].from, to: legs[1].to, option: option)
    return Itinerary(legs: legs)
}

private extension Ride {
    init(routeName: String, colorHex: String?, headsign: String?, boardStopName: String, alightStopName: String,
         scheduledBoard: Date, board: Date, alight: Date, stops: [RideStop]) {
        self.init(routeName: routeName, routeColorHex: colorHex, headsign: headsign, boardStopName: boardStopName,
                  alightStopName: alightStopName, scheduledBoard: scheduledBoard, board: board, alight: alight, stops: stops)
    }
}

@Suite struct TripGlanceTests {
    @Test func waitsToLeaveThenNamesTheTrainTheDriveIsFor() throws {
        var trip = try #require(ActiveTrip(template: template, itinerary: itinerary()))
        let waiting = trip.instruction(at: t0)
        #expect(waiting.kind == .leave)
        #expect(waiting.deadline == t0 + 300)
        #expect(waiting.detail?.hasPrefix("Drive to Station A") == true)

        trip.update(location: home.coordinate, now: t0)
        trip.update(location: Coordinate(latitude: 40.71, longitude: -74.08), now: t0 + 400)
        let driving = trip.instruction(at: t0 + 400)
        #expect(driving.kind == .travel)
        #expect(driving.title == "Drive to Station A")
        #expect(driving.deadline == t0 + 900)
        #expect(driving.detail?.hasPrefix("Then A ") == true)
        #expect(driving.detail?.hasSuffix("to spare") == true)
    }

    @Test func walksThroughBoardingRidingAndChanging() throws {
        var trip = try #require(ActiveTrip(template: template, itinerary: itinerary()))
        trip.markArrived(now: t0 + 900)

        let boarding = trip.instruction(at: t0 + 900)
        #expect(boarding.kind == .board)
        #expect(boarding.title == "Board at Station A")
        #expect(boarding.spokenTitle == "Board A at Station A")
        #expect(boarding.route == RouteLabel(name: "A", colorHex: "0039A6"))
        #expect(boarding.detail == "toward Uptown")
        #expect(boarding.deadline == t0 + 1200)

        trip.update(location: nil, now: t0 + 1300)
        let riding = trip.instruction(at: t0 + 1300)
        #expect(riding.kind == .ride)
        #expect(riding.title == "Exit at Station B")
        #expect(riding.detail == "2 stops · then B")
        #expect(riding.deadline == t0 + 1800)

        // Off the first train, not yet on the second: a change, with the walk across and how late it is running.
        let changing = trip.instruction(at: t0 + 1900)
        #expect(changing.kind == .change)
        #expect(changing.spokenTitle == "Change to B at Station B")
        #expect(changing.detail == "3 min walk · 2 min late")
        #expect(changing.deadline == t0 + 2220)

        // A change between separate stations the agency lets riders make for free says so, so they don't pay twice.
        var legs = itinerary().legs
        legs[1].option.rides[1].freeTransfer = "Farragut Crossing: free with SmarTrip within 30 min"
        var crossing = try #require(ActiveTrip(template: template, itinerary: Itinerary(legs: legs)))
        crossing.markArrived(now: t0 + 900)
        crossing.update(location: nil, now: t0 + 1300)
        #expect(crossing.instruction(at: t0 + 1900).detail == "3 min walk · free transfer · 2 min late")

        let last = trip.instruction(at: t0 + 2300)
        #expect(last.kind == .ride)
        #expect(last.detail == "then walk to Office")
    }

    @Test func looksAtTheNextBoardingOnlyWithinFiveMinutesOfIt() throws {
        var trip = try #require(ActiveTrip(template: template, itinerary: withStops(itinerary())))
        // Leaving home: the drive reaches Station A at +15 min, far off.
        #expect(trip.upcomingChange(at: t0) == nil)

        // Four minutes out on the drive: the A from Station A to Station B, catchable once parked (no walk here).
        trip.update(location: home.coordinate, now: t0)
        trip.update(location: Coordinate(latitude: 40.71, longitude: -74.08), now: t0 + 660)
        let driving = try #require(trip.upcomingChange(at: t0 + 660))
        #expect(driving.station.stopID == "Station A")
        #expect(driving.toward.stopID == "Station B")
        #expect(driving.catchableFrom == t0 + 900)

        // Aboard the A: nothing until five minutes before getting off, then the B toward Station C,
        // counting the three-minute walk across.
        trip.markArrived(now: t0 + 900)
        trip.update(location: nil, now: t0 + 1300)
        #expect(trip.upcomingChange(at: t0 + 1300) == nil)
        let aboard = try #require(trip.upcomingChange(at: t0 + 1560))
        #expect(aboard.station.stopID == "Station B")
        #expect(aboard.toward.stopID == "Station C")
        #expect(aboard.catchableFrom == t0 + 1800 + 180)

        // Off and changing: whatever leaves from now on.
        let changing = try #require(trip.upcomingChange(at: t0 + 1900))
        #expect(changing.catchableFrom == t0 + 1900)

        // On the last vehicle, with only a walk after it: nothing to change to.
        #expect(trip.upcomingChange(at: t0 + 2600) == nil)
    }

    @Test func aStreetCrossingBetweenStationsCountsAsAChange() throws {
        // Red Line to Farragut North, a 4-minute walk leg to Farragut West, then the Blue Line.
        let north = Waypoint(name: "Farragut North", coordinate: Coordinate(latitude: 38.9032, longitude: -77.0397), kind: .stop(feedID: "f", stopID: "FN"))
        let west = Waypoint(name: "Farragut West", coordinate: Coordinate(latitude: 38.9013, longitude: -77.0420), kind: .stop(feedID: "f", stopID: "FW"))
        let crossing = TripTemplate(waypoints: [stationA, north, west, stationC], modes: [.transit, .walk, .transit])
        let red = Ride(routeName: "RD", boardStopName: "Station A", alightStopName: "Farragut North",
                       scheduledBoard: t0, board: t0, alight: t0 + 900, stops: [stop("Station A", 0), stop("Farragut North", 900)])
        let blue = Ride(routeName: "BL", boardStopName: "Farragut West", alightStopName: "Station C",
                        scheduledBoard: t0 + 1500, board: t0 + 1500, alight: t0 + 2100, stops: [stop("FW", 1500), stop("Station C", 2100)])
        let plan = Itinerary(legs: [
            Leg(segmentIndex: 0, from: stationA, to: north, option: LegOption(mode: .transit, departure: t0, arrival: t0 + 900, rides: [red])),
            Leg(segmentIndex: 1, from: north, to: west, option: LegOption(mode: .walk, departure: t0 + 900, arrival: t0 + 1140)),
            Leg(segmentIndex: 2, from: west, to: stationC, option: LegOption(mode: .transit, departure: t0 + 1500, arrival: t0 + 2100, rides: [blue])),
        ])
        var trip = try #require(ActiveTrip(template: crossing, itinerary: plan))
        trip.update(location: nil, now: t0 + 60)
        let aboard = try #require(trip.upcomingChange(at: t0 + 700))
        #expect(aboard.station.stopID == "FW")
        #expect(aboard.catchableFrom == t0 + 900 + 240)

        trip.markArrived(now: t0 + 900)
        let walking = try #require(trip.upcomingChange(at: t0 + 950))
        #expect(walking.station.stopID == "FW")
        #expect(walking.catchableFrom == t0 + 1140)
    }

    @Test func theBoardMarksThePlannedVehicleAndDropsWhatHasGone() throws {
        let planned = withStops(itinerary()).legs[1].option.rides[1]
        let change = UpcomingChange(station: planned.stops[0].station, toward: planned.stops[1].station, catchableFrom: t0 + 1980, planned: planned)
        let b = RouteLabel(name: "B")
        let board = change.board([
            .init(route: b, time: t0 + 2000), .init(route: b, time: t0 + 2220, isRealtime: true),
            .init(route: RouteLabel(name: "X"), time: t0 + 2220), .init(route: b, time: t0 + 2600),
        ])
        #expect(board.station == "Station B")
        #expect(board.toward == "Station C")
        #expect(board.departures.map(\.isPlanned) == [false, true, false, false])
        #expect(board.catchable(from: t0 + 2100)?.departures.map(\.time) == [t0 + 2220, t0 + 2220, t0 + 2600])
        #expect(board.catchable(from: t0 + 2700) == nil)
    }

    @Test func theGlanceCarriesTheBarAndSettlesOnceArrived() throws {
        var trip = try #require(ActiveTrip(template: template, itinerary: itinerary(), arriveBy: t0 + 3300))
        let early = try #require(trip.glance(at: t0).progress)
        #expect(early.standing == .onTime)
        #expect(early.delta == -300)
        #expect(trip.glance(at: t0).destination == "Office")

        // A plan whose arrival has passed keeps sliding with the clock, a minute at a time.
        let overdue = trip.glance(at: t0 + 3000 + 61)
        #expect(overdue.arrival == t0 + 3000 + 120)
        #expect(trip.glance(at: t0 + 3000 + 90) == overdue)

        trip.markArrived(now: t0 + 900)
        trip.markArrived(now: t0 + 2700)
        trip.markArrived(now: t0 + 2950)
        let done = trip.glance(at: t0 + 4000)
        #expect(done.isFinished)
        #expect(done.instruction.kind == .arrived)
        #expect(done.arrival == t0 + 2950)
        #expect(done.progress?.isFinal == true)

        var untimed = try #require(ActiveTrip(template: template, itinerary: itinerary()))
        untimed.update(location: nil, now: t0)
        #expect(untimed.glance(at: t0).progress == nil)
    }

    @Test func aTripSurvivesBeingWrittenDownAndReadBack() throws {
        var trip = try #require(ActiveTrip(template: template, itinerary: itinerary(), arriveBy: t0 + 3300))
        trip.update(location: home.coordinate, now: t0)
        trip.markArrived(now: t0 + 900)
        trip.update(location: nil, now: t0 + 1300)

        let restored = try JSONDecoder().decode(ActiveTrip.self, from: JSONEncoder().encode(trip))
        #expect(restored.currentSegment == 1)
        #expect(restored.hasBoarded)
        #expect(restored.isMoving)
        #expect(restored.arriveBy == t0 + 3300)
        #expect(restored.legs == trip.legs)
        #expect(restored.glance(at: t0 + 1300) == trip.glance(at: t0 + 1300))
    }
}
