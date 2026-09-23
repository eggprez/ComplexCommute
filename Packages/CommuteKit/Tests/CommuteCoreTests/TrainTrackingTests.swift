import Foundation
import Testing
@testable import CommuteCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let home = Waypoint(name: "Home", coordinate: Coordinate(latitude: 40.70, longitude: -74.10))
/// The station's pin is on the street; the platform is 400 m along it.
private let stationA = Waypoint(name: "Station A", coordinate: Coordinate(latitude: 40.72, longitude: -74.05), kind: .stop(feedID: "f", stopID: "A"))
private let platformA = StationRef(feedID: "f", stopID: "A1", name: "Station A", coordinate: Coordinate(latitude: 40.7236, longitude: -74.05))
private let stationM = StationRef(feedID: "f", stopID: "M", name: "Station M", coordinate: Coordinate(latitude: 40.735, longitude: -74.02))
private let stationB = Waypoint(name: "Station B", coordinate: Coordinate(latitude: 40.75, longitude: -73.99), kind: .stop(feedID: "f", stopID: "B"))
private let platformB = StationRef(feedID: "f", stopID: "B", name: "Station B", coordinate: stationB.coordinate)
private let office = Waypoint(name: "Office", coordinate: Coordinate(latitude: 40.755, longitude: -73.985))
private let template = TripTemplate(waypoints: [home, stationA, stationB, office], modes: [.drive, .transit, .walk])

private func ride(_ tripID: String, _ route: String = "A", from: StationRef = platformA, to: StationRef = platformB,
                  board: TimeInterval, alight: TimeInterval) -> Ride {
    Ride(routeName: route, boardStopName: from.name, alightStopName: to.name, scheduledBoard: t0 + board, board: t0 + board,
         alight: t0 + alight, stops: [RideStop(station: from, time: t0 + board), RideStop(station: to, time: t0 + alight)],
         trip: TripRef(feedID: "f", tripID: tripID, serviceDate: 20270115))
}

/// Drive 10 min from +5, the 8 train at +15 (20 min), walk 5 min.
private func itinerary(rides: [Ride]? = nil) -> Itinerary {
    let rides = rides ?? [ride("8", board: 900, alight: 2_100)]
    let arrival = rides.last!.alight + 300
    return Itinerary(legs: [
        Leg(segmentIndex: 0, from: home, to: stationA, option: LegOption(mode: .drive, departure: t0 + 300, arrival: t0 + 900)),
        Leg(segmentIndex: 1, from: stationA, to: stationB, option: LegOption(mode: .transit, departure: rides[0].board, arrival: rides.last!.alight + 0,
                                                                           rides: rides)),
        Leg(segmentIndex: 2, from: stationB, to: office, option: LegOption(mode: .walk, departure: rides.last!.alight, arrival: arrival)),
    ])
}

@Suite struct TrainTrackingTests {
    @Test func reachingThePlatformEndsTheDriveEvenFarFromTheStationsPin() throws {
        var trip = try #require(ActiveTrip(template: template, itinerary: itinerary()))
        trip.update(location: home.coordinate, now: t0 + 300)
        #expect(platformA.coordinate.distance(to: stationA.coordinate) > 300)
        let moved = trip.update(location: platformA.coordinate, now: t0 + 800)
        #expect(moved)
        #expect(trip.currentSegment == 1)
    }

    @Test func aTrainMatchedFromTheCarCatchesTheTripUp() throws {
        var trip = try #require(ActiveTrip(template: template, itinerary: itinerary()))
        trip.update(location: home.coordinate, now: t0 + 300)
        // The drive ended unseen, and the rider made the earlier 7 train.
        let watch = try #require(trip.ridesToWatch(at: t0 + 700))
        #expect(watch.segment == 1)
        let earlier = ride("7", board: 600, alight: 1_800)
        trip.apply(TrainMatch(ride: earlier, rideIndex: 0, offset: 10, isConfident: true), segment: watch.segment, now: t0 + 700)

        #expect(trip.currentSegment == 1)
        #expect(trip.hasBoarded)
        #expect(trip.boardedBy == .location)
        #expect(trip.currentLeg?.option.rides.first?.trip?.tripID == "7")
        #expect(trip.currentLeg?.arrival == t0 + 1_800)
        // Nobody saw the drive end, so it teaches nothing about how long reaching the platform takes.
        #expect(trip.drainRecords().isEmpty)
    }

    @Test func anUnclearMatchIsPutToTheRider() throws {
        var trip = try #require(ActiveTrip(template: template, itinerary: itinerary()))
        trip.markArrived(now: t0 + 800)
        let later = ride("9", board: 1_200, alight: 2_400)
        trip.apply(TrainMatch(ride: later, rideIndex: 0, offset: 80, isConfident: false), segment: 1, now: t0 + 1_300)
        #expect(trip.suggestedTrain?.ride.trip?.tripID == "9")

        trip.rejectSuggestedTrain()
        #expect(trip.suggestedTrain == nil)
        // Said no once: not asked again, however well it fits.
        trip.apply(TrainMatch(ride: later, rideIndex: 0, offset: 5, isConfident: true), segment: 1, now: t0 + 1_400)
        #expect(trip.currentLeg?.option.rides.first?.trip?.tripID == "8")

        let other = ride("10", board: 1_500, alight: 2_700)
        trip.apply(TrainMatch(ride: other, rideIndex: 0, offset: 80, isConfident: false), segment: 1, now: t0 + 1_600)
        trip.acceptSuggestedTrain(now: t0 + 1_600)
        #expect(trip.boardedBy == .rider)
        #expect(trip.currentLeg?.option.rides.first?.trip?.tripID == "10")
        #expect(trip.currentLeg?.arrival == t0 + 2_700)
    }

    @Test func theRiderHasTheLastWord() throws {
        var trip = try #require(ActiveTrip(template: template, itinerary: itinerary()))
        trip.markArrived(now: t0 + 800)
        trip.board(ride("8", board: 900, alight: 2_100), segment: 1, rideIndex: 0, evidence: .rider, now: t0 + 950)
        trip.apply(TrainMatch(ride: ride("9", board: 1_200, alight: 2_400), rideIndex: 0, offset: 5, isConfident: true), segment: 1, now: t0 + 1_300)
        #expect(trip.currentLeg?.option.rides.first?.trip?.tripID == "8")
        #expect(trip.boardedBy == .rider)
        #expect(trip.ridesToWatch(at: t0 + 1_300) == nil)
    }

    @Test func theScheduleIsTheWeakestReasonToThinkSo() throws {
        var trip = try #require(ActiveTrip(template: template, itinerary: itinerary()))
        trip.markArrived(now: t0 + 800)
        trip.update(location: nil, now: t0 + 1_000)
        #expect(trip.boardedBy == .schedule)
        trip.apply(TrainMatch(ride: ride("8", board: 900, alight: 2_100), rideIndex: 0, offset: 5, isConfident: true), segment: 1, now: t0 + 1_100)
        #expect(trip.boardedBy == .location)
    }

    @Test func liveTimesForTheTrainAboardMoveTheArrival() throws {
        var trip = try #require(ActiveTrip(template: template, itinerary: itinerary()))
        trip.markArrived(now: t0 + 800)
        trip.update(location: nil, now: t0 + 1_000)
        trip.refreshRide(ride("8", board: 900, alight: 2_400))
        #expect(trip.currentLeg?.arrival == t0 + 2_400)
        let request = try #require(trip.replanRequest(location: nil, now: t0 + 1_000))
        #expect(request.firstSegment == 2)
        #expect(request.departure == t0 + 2_400)
    }

    @Test func aboardWithAChangeToComeTheRestOfTheLegIsReplanned() throws {
        let first = ride("8", from: platformA, to: stationM, board: 900, alight: 1_500)
        let second = ride("X1", "X", from: stationM, to: platformB, board: 1_700, alight: 2_100)
        var trip = try #require(ActiveTrip(template: template, itinerary: itinerary(rides: [first, second])))
        trip.markArrived(now: t0 + 800)
        trip.update(location: nil, now: t0 + 1_000)

        let request = try #require(trip.replanRequest(location: nil, now: t0 + 1_000))
        #expect(request.firstSegment == 1)
        #expect(request.keptRides.count == 1)
        #expect(request.template.waypoints.first?.name == "Station M")
        #expect(request.template.modes == [.transit, .walk])
        #expect(request.departure == t0 + 1_500)

        // The 8 runs late; the next X gets there sooner than waiting on the planned one would.
        let later = ride("X2", "X", from: stationM, to: platformB, board: 1_900, alight: 2_300)
        let fromM = Waypoint(name: "Station M", coordinate: stationM.coordinate, kind: .stop(feedID: "f", stopID: "M"))
        let plan = Itinerary(legs: [
            Leg(segmentIndex: 0, from: fromM, to: stationB, option: LegOption(mode: .transit, departure: t0 + 1_900, arrival: t0 + 2_300, rides: [later])),
            Leg(segmentIndex: 1, from: stationB, to: office, option: LegOption(mode: .walk, departure: t0 + 2_300, arrival: t0 + 2_600)),
        ])
        trip.apply([plan], for: request)
        let leg = try #require(trip.currentLeg)
        #expect(leg.option.rides.map(\.routeName) == ["A", "X"])
        #expect(leg.option.rides.last?.trip?.tripID == "X2")
        #expect(leg.from == stationA)
        #expect(trip.arrival == t0 + 2_600)
    }
}
