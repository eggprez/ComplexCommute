import Foundation
import Testing
@testable import CommuteCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let home = Waypoint(name: "Home", coordinate: Coordinate(latitude: 40.70, longitude: -74.10))
private let stationA = Waypoint(name: "Station A", coordinate: Coordinate(latitude: 40.72, longitude: -74.05), kind: .stop(feedID: "f", stopID: "A"))
private let platformA = StationRef(feedID: "f", stopID: "A", name: "Station A", coordinate: stationA.coordinate)
private let stationB = Waypoint(name: "Station B", coordinate: Coordinate(latitude: 40.75, longitude: -73.99), kind: .stop(feedID: "f", stopID: "B"))
private let platformB = StationRef(feedID: "f", stopID: "B", name: "Station B", coordinate: stationB.coordinate)
private let office = Waypoint(name: "Office", coordinate: Coordinate(latitude: 40.755, longitude: -73.985))

/// A car park 700 m from the platform: too far for the platform radius, near enough to have parked for it.
private let carPark = Coordinate(latitude: 40.72 - 700 / 111_320, longitude: -74.05)

/// `first` to Station A 10 min from +5, the 8 train at +15 (20 min), walk 5 min.
private func trip(first: TravelMode = .drive) throws -> ActiveTrip {
    let ride = Ride(routeName: "A", boardStopName: "Station A", alightStopName: "Station B", scheduledBoard: t0 + 900, board: t0 + 900,
                    alight: t0 + 2_100, stops: [RideStop(station: platformA, time: t0 + 900), RideStop(station: platformB, time: t0 + 2_100)],
                    trip: TripRef(feedID: "f", tripID: "8", serviceDate: 20270115))
    let itinerary = Itinerary(legs: [
        Leg(segmentIndex: 0, from: home, to: stationA, option: LegOption(mode: first, departure: t0 + 300, arrival: t0 + 900)),
        Leg(segmentIndex: 1, from: stationA, to: stationB, option: LegOption(mode: .transit, departure: t0 + 900, arrival: t0 + 2_100, rides: [ride])),
        Leg(segmentIndex: 2, from: stationB, to: office, option: LegOption(mode: .walk, departure: t0 + 2_100, arrival: t0 + 2_400)),
    ])
    let template = TripTemplate(waypoints: [home, stationA, stationB, office], modes: [first, .transit, .walk])
    return try #require(ActiveTrip(template: template, itinerary: itinerary))
}

@Suite struct ModeSensingTests {
    @Test func walkingAwayFromTheCarNearTheStationEndsTheDrive() throws {
        var trip = try trip()
        trip.update(location: home.coordinate, now: t0 + 300)
        trip.update(motion: .automotive, location: home.coordinate, now: t0 + 400)
        let moved1 = trip.update(location: carPark, now: t0 + 800)
        #expect(!moved1)
        let moved2 = trip.update(motion: .walking, location: carPark, now: t0 + 820)
        #expect(moved2)
        #expect(trip.currentLeg?.mode == .transit)
    }

    @Test func walkingSomewhereElseOnTheWayDoesNot() throws {
        var trip = try trip()
        trip.update(motion: .automotive, location: home.coordinate, now: t0 + 400)
        // A coffee stop halfway there.
        trip.update(motion: .walking, location: Coordinate(latitude: 40.71, longitude: -74.075), now: t0 + 600)
        #expect(trip.currentSegment == 0)
    }

    @Test func movingOffFromThePlatformWhenTheTrainIsDueIsBoarding() throws {
        var trip = try trip()
        trip.update(location: home.coordinate, now: t0 + 300)
        trip.update(location: platformA.coordinate, now: t0 + 840)
        #expect(trip.currentSegment == 1)
        trip.update(motion: .stationary, location: platformA.coordinate, now: t0 + 850)
        trip.update(motion: .automotive, location: nil, now: t0 + 880)
        #expect(trip.hasBoarded)
        #expect(trip.boardedBy == .movement)
        #expect(trip.actions(at: t0 + 900).actions.isEmpty)
    }

    @Test func movingOffLongBeforeThePlannedTrainAsksWhichTrain() throws {
        var trip = try trip()
        trip.update(location: home.coordinate, now: t0 + 100)
        trip.update(location: platformA.coordinate, now: t0 + 300)
        trip.update(motion: .automotive, location: nil, now: t0 + 400)
        #expect(!trip.hasBoarded)
        #expect(trip.isAskingAboutTrain)
        let asked = trip.actions(at: t0 + 400)
        #expect(asked.prompt == "On a train?")
        #expect(asked.actions == [.aboard, .rejectTrain])

        trip.markAboard(now: t0 + 420)
        #expect(trip.hasBoarded)
        #expect(trip.boardedBy == .riderAboard)
        #expect(!trip.isAskingAboutTrain)
    }

    @Test func theGeofencesFollowTheTrip() throws {
        var trip = try trip()
        #expect(trip.placesToWatch.map(\.id) == ["board.1", "end.0"])
        let moved3 = trip.crossed("board.1", entered: true, now: t0 + 800)
        #expect(moved3)
        #expect(trip.currentSegment == 1)
        #expect(trip.placesToWatch.map(\.id) == ["board.1", "end.1"])

        // Leaving on foot: still waiting.
        trip.update(motion: .walking, location: nil, now: t0 + 850)
        trip.crossed("board.1", entered: false, now: t0 + 860)
        #expect(!trip.hasBoarded)

        trip.crossed("board.1", entered: true, now: t0 + 870)
        trip.update(motion: .automotive, location: nil, now: t0 + 890)
        trip.crossed("board.1", entered: false, now: t0 + 900)
        #expect(trip.hasBoarded)
        #expect(trip.placesToWatch.map(\.id) == ["end.1"])

        // Through the exit station's fence well before arriving: not there yet.
        let moved4 = trip.crossed("end.1", entered: true, now: t0 + 1_000)
        #expect(!moved4)
        let moved5 = trip.crossed("end.1", entered: true, now: t0 + 2_000)
        #expect(moved5)
        #expect(trip.currentLeg?.mode == .walk)
        // A stale fence for a leg already done is ignored.
        let moved6 = trip.crossed("end.0", entered: true, now: t0 + 2_050)
        #expect(!moved6)
    }

    @Test func steppingOffTheTrainAtTheFarEndEndsTheRide() throws {
        var trip = try trip()
        trip.crossed("board.1", entered: true, now: t0 + 800)
        trip.update(motion: .automotive, location: nil, now: t0 + 900)
        #expect(trip.hasBoarded)
        let moved7 = trip.update(motion: .walking, location: stationB.coordinate, now: t0 + 2_080)
        #expect(moved7)
        #expect(trip.currentLeg?.mode == .walk)
    }

    @Test func aWalkThatBecomesATrainRideCatchesUp() throws {
        var trip = try trip(first: .walk)
        trip.update(location: home.coordinate, now: t0 + 300)
        trip.update(motion: .walking, location: home.coordinate, now: t0 + 310)
        let moved8 = trip.update(motion: .automotive, location: Coordinate(latitude: 40.72 - 300 / 111_320, longitude: -74.05), now: t0 + 880)
        #expect(moved8)
        #expect(trip.currentLeg?.mode == .transit)
        #expect(trip.hasBoarded)
    }

    @Test func theLockScreenOffersWhatFitsTheMoment() throws {
        var trip = try trip()
        trip.update(location: home.coordinate, now: t0 + 300)
        trip.update(location: Coordinate(latitude: 40.71, longitude: -74.08), now: t0 + 400)
        #expect(trip.glance(at: t0 + 400).actions == [.arrived, .aboard])
        trip.markAboard(now: t0 + 500)
        #expect(trip.currentSegment == 1)
        #expect(trip.boardedBy == .riderAboard)
        #expect(trip.glance(at: t0 + 950).actions.isEmpty)
    }
}
