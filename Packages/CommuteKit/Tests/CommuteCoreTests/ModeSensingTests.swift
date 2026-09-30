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
    @Test func theGeofencesFollowTheTrip() throws {
        var trip = try trip()
        #expect(trip.placesToWatch.map(\.id) == ["board.1", "end.0"])
        let moved3 = trip.crossed("board.1", entered: true, now: t0 + 800)
        #expect(moved3)
        #expect(trip.currentSegment == 1)
        #expect(trip.placesToWatch.map(\.id) == ["board.1", "end.1"])

        // Leaving the station isn't boarding by itself: it's only when, for the matcher to weigh.
        trip.crossed("board.1", entered: false, now: t0 + 860)
        #expect(!trip.hasBoarded)
        #expect(trip.leftStationAt == t0 + 860)
        trip.crossed("board.1", entered: true, now: t0 + 870)
        #expect(trip.leftStationAt == nil)
        trip.crossed("board.1", entered: false, now: t0 + 910)
        #expect(trip.leftStationAt == t0 + 910)

        trip.apply(TrainMatch(ride: trip.currentLeg!.option.rides[0], rideIndex: 0, offset: 10, isConfident: true, leftStation: true),
                   segment: 1, now: t0 + 960)
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

    @Test func theDynamicIslandOffersWhatFitsTheMoment() throws {
        var trip = try trip()
        trip.update(location: home.coordinate, now: t0 + 300)
        trip.update(location: Coordinate(latitude: 40.71, longitude: -74.08), now: t0 + 400)
        #expect(trip.glance(at: t0 + 400).actions == [.arrived, .aboard])
        trip.markAboard(now: t0 + 500)
        #expect(trip.currentSegment == 1)
        #expect(trip.boardedBy == .riderAboard)
        #expect(trip.glance(at: t0 + 950).actions.isEmpty)
    }

    @Test func secondsAreCountedOnlyRightBeforeATrainLeaves() throws {
        var trip = try trip()
        trip.update(location: home.coordinate, now: t0 + 300)
        trip.update(location: Coordinate(latitude: 40.71, longitude: -74.08), now: t0 + 400)
        #expect(trip.glance(at: t0 + 400).instruction.kind == .travel)
        #expect(!trip.glance(at: t0 + 400).instruction.countsSeconds)
        trip.markArrived(now: t0 + 700)
        #expect(trip.glance(at: t0 + 700).instruction.kind == .board)
        #expect(!trip.glance(at: t0 + 700).instruction.countsSeconds)
        #expect(trip.glance(at: t0 + 790).instruction.countsSeconds)
    }
}
