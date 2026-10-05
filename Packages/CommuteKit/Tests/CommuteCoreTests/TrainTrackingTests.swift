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
        trip.apply(TrainMatch(ride: earlier, rideIndex: 0, offset: 10, isConfident: true, leftStation: true), segment: watch.segment, now: t0 + 700)

        #expect(trip.currentSegment == 1)
        #expect(trip.hasBoarded)
        #expect(trip.boardedBy == .location)
        #expect(trip.currentLeg?.option.rides.first?.trip?.tripID == "7")
        #expect(trip.currentLeg?.arrival == t0 + 1_800)
        // Nobody saw the drive end, so it teaches nothing about how long reaching the platform takes.
        #expect(trip.drainRecords().isEmpty)
    }

    @Test func anUnclearMatchIsTakenWithoutAsking() throws {
        var trip = try #require(ActiveTrip(template: template, itinerary: itinerary()))
        trip.markArrived(now: t0 + 800)
        let later = ride("9", board: 1_200, alight: 2_400)
        trip.apply(TrainMatch(ride: later, rideIndex: 0, offset: 80, isConfident: false), segment: 1, now: t0 + 1_300)
        #expect(trip.boardedBy == .likely)
        #expect(trip.currentLeg?.option.rides.first?.trip?.tripID == "9")
        #expect(trip.currentLeg?.arrival == t0 + 2_400)
        #expect(trip.actions(at: t0 + 1_300).isEmpty)

        // Later fixes fit another train better: it moves over.
        let other = ride("10", board: 1_250, alight: 2_450)
        trip.apply(TrainMatch(ride: other, rideIndex: 0, offset: 40, isConfident: false), segment: 1, now: t0 + 1_400)
        #expect(trip.currentLeg?.option.rides.first?.trip?.tripID == "10")
        trip.apply(TrainMatch(ride: other, rideIndex: 0, offset: 10, isConfident: true), segment: 1, now: t0 + 1_500)
        #expect(trip.boardedBy == .location)

        // Once sure, a vaguer fit to another train doesn't undo it.
        trip.apply(TrainMatch(ride: later, rideIndex: 0, offset: 60, isConfident: false), segment: 1, now: t0 + 1_600)
        #expect(trip.currentLeg?.option.rides.first?.trip?.tripID == "10")
    }

    @Test func aCarBesideTheTracksDoesNotCatchTheTripUp() throws {
        var trip = try #require(ActiveTrip(template: template, itinerary: itinerary()))
        trip.update(location: home.coordinate, now: t0 + 300)
        let earlier = ride("7", board: 600, alight: 1_800)
        trip.apply(TrainMatch(ride: earlier, rideIndex: 0, offset: 30, isConfident: false), segment: 1, now: t0 + 700)
        trip.apply(TrainMatch(ride: earlier, rideIndex: 0, offset: 10, isConfident: true, leftStation: false), segment: 1, now: t0 + 700)
        #expect(trip.currentSegment == 0)
        #expect(!trip.hasBoarded)
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

    @Test func seenAtTheStopToChangeAtTheRiderIsOffHoweverEarlyItGotIn() throws {
        let first = ride("8", from: platformA, to: stationM, board: 900, alight: 1_500)
        let second = ride("X1", "X", from: stationM, to: platformB, board: 1_700, alight: 2_100)
        var trip = try #require(ActiveTrip(template: template, itinerary: itinerary(rides: [first, second])))
        trip.markArrived(now: t0 + 800)
        trip.update(location: nil, now: t0 + 1_000)
        #expect(trip.hasBoarded)

        // Passing a stop on the way at speed isn't getting off anywhere.
        let onTheWay = Coordinate(latitude: 40.729, longitude: -74.035)
        trip.update(fix: LocationFix(coordinate: onTheWay, time: t0 + 1_100, accuracy: 10, speed: 14), now: t0 + 1_100)
        #expect(trip.hasBoarded)

        // In four minutes early, and standing at Station M: off the 8, with everything from there open again.
        trip.update(location: stationM.coordinate, now: t0 + 1_260)
        #expect(!trip.hasBoarded)
        #expect(trip.isChangingVehicles)
        #expect(trip.currentLeg?.option.rides.map(\.routeName) == ["X"])
        #expect(trip.instruction(at: t0 + 1_260).kind == .change)
        let request = try #require(trip.replanRequest(location: stationM.coordinate, now: t0 + 1_260))
        #expect(request.firstSegment == 1)
        #expect(request.keptRides.isEmpty)
        #expect(request.template.waypoints.first?.name == "Station M")
        #expect(request.departure == t0 + 1_260)
        #expect(request.isWaitingAtOrigin)
    }

    @Test func stillMovingWhenItWasDueInTheRiderIsOnAVehicleRunningLate() throws {
        let first = ride("8", from: platformA, to: stationM, board: 900, alight: 1_500)
        let second = ride("X1", "X", from: stationM, to: platformB, board: 1_700, alight: 2_100)
        var trip = try #require(ActiveTrip(template: template, itinerary: itinerary(rides: [first, second])))
        trip.markArrived(now: t0 + 800)
        trip.update(location: nil, now: t0 + 1_000)

        let onTheWay = Coordinate(latitude: 40.729, longitude: -74.035)
        trip.update(fix: LocationFix(coordinate: onTheWay, time: t0 + 1_520, accuracy: 10, speed: 14), now: t0 + 1_520)
        #expect(trip.hasBoarded)
        #expect(trip.currentLeg?.option.rides.count == 2)
        #expect(try #require(trip.currentRide(at: t0 + 1_520)).alight > t0 + 1_520)

        // With nothing to see (underground), the clock decides, and by the clock alone the change still needs its time.
        var unseen = try #require(ActiveTrip(template: template, itinerary: itinerary(rides: [first, second])))
        unseen.markArrived(now: t0 + 800)
        unseen.update(location: nil, now: t0 + 1_000)
        unseen.update(location: nil, now: t0 + 1_510)
        #expect(!unseen.hasBoarded)
        #expect(try #require(unseen.replanRequest(location: nil, now: t0 + 1_510)).isWaitingAtOrigin == false)
    }

    @Test func boardingTheOtherWayMovesTheTripOntoIt() throws {
        var trip = try #require(ActiveTrip(template: template, itinerary: itinerary()))
        trip.markArrived(now: t0 + 800)
        let request = try #require(trip.replanRequest(location: nil, now: t0 + 800))
        let bus = ride("Q1", "Q", from: platformA, to: stationM, board: 960, alight: 1_500)
        let onward = ride("X1", "X", from: stationM, to: platformB, board: 1_700, alight: 2_000)
        func rest(_ itinerary: Itinerary) -> Itinerary {
            Itinerary(legs: itinerary.legs.dropFirst().enumerated().map { offset, leg in
                var leg = leg
                leg.segmentIndex = offset
                return leg
            })
        }
        trip.apply([rest(itinerary()), rest(itinerary(rides: [bus, onward]))], for: request)
        #expect(trip.branches.map(\.ride.routeName) == ["Q", "A"])
        #expect(trip.currentRide(at: t0 + 800)?.routeName == "A")
        let watched = try #require(trip.ridesToWatch(at: t0 + 800))
        #expect(watched.rides.map(\.ride.routeName) == ["A", "Q"])
        #expect(watched.rides.map(\.isAlternative) == [false, true])

        // A fix or two that fit the bus don't move the trip: it flipped between plans on less, once.
        trip.apply(TrainMatch(ride: bus, rideIndex: 0, offset: 30, isConfident: false, isAlternative: true), segment: 1, now: t0 + 1_000)
        #expect(!trip.hasBoarded)
        #expect(trip.currentRide(at: t0 + 1_000)?.routeName == "A")

        // Clearly on it: the trip is on the bus, and what follows is planned from where it lets off.
        trip.apply(TrainMatch(ride: bus, rideIndex: 0, offset: 10, isConfident: true, isAlternative: true), segment: 1, now: t0 + 1_100)
        #expect(trip.hasBoarded)
        #expect(trip.boardedBy == .location)
        #expect(trip.branches.isEmpty)
        #expect(trip.currentLeg?.option.rides.map(\.routeName) == ["Q"])
        let next = try #require(trip.replanRequest(location: nil, now: t0 + 1_100))
        #expect(next.keptRides.map(\.routeName) == ["Q"])
        #expect(next.template.waypoints.first?.name == "Station M")

        let fromM = Waypoint(name: "Station M", coordinate: stationM.coordinate, kind: .stop(feedID: "f", stopID: "M"))
        trip.apply([Itinerary(legs: [
            Leg(segmentIndex: 0, from: fromM, to: stationB, option: LegOption(mode: .transit, departure: t0 + 1_700, arrival: t0 + 2_000, rides: [onward])),
            Leg(segmentIndex: 1, from: stationB, to: office, option: LegOption(mode: .walk, departure: t0 + 2_000, arrival: t0 + 2_300)),
        ])], for: next)
        #expect(trip.currentLeg?.option.rides.map(\.routeName) == ["Q", "X"])
        #expect(trip.notice == nil)
        #expect(trip.arrival == t0 + 2_300)
    }

    @Test func twoLinesThatShareTheRoadOutAreAskedAbout() throws {
        var trip = try #require(ActiveTrip(template: template, itinerary: itinerary()))
        trip.markArrived(now: t0 + 800)
        let bus = ride("Q1", "Q", from: platformA, to: stationM, board: 960, alight: 1_500)
        trip.apply(TrainMatch(ride: bus, rideIndex: 0, offset: 20, isConfident: false, rival: ride("8", board: 900, alight: 2_100),
                              isAlternative: true, rivalIsAlternative: false), segment: 1, now: t0 + 1_150)
        let question = try #require(trip.trainQuestion)
        #expect(question.options.map(\.routeName) == ["A", "Q"])
        trip.answerTrainQuestion(1, now: t0 + 1_160)
        #expect(trip.boardedBy == .rider)
        #expect(trip.currentLeg?.option.rides.map(\.routeName) == ["Q"])
        #expect(try #require(trip.replanRequest(location: nil, now: t0 + 1_160)).keptRides.count == 1)
    }

    @Test func buttonsAreNamedForWhatIsBeingCaught() {
        var bus = ride("Q1", "Q70", board: 900, alight: 1_500)
        bus.routeType = 3
        #expect(bus.vehicle == .bus)
        #expect(ride("8", board: 900, alight: 1_500).vehicle == .train)
        #expect(TripAction.aboard.title(for: .bus) == "On Bus")
        #expect(TripAction.arrived.title(for: .bus) == "At Stop")
        #expect(TripAction.aboard.title(for: nil) == "On Train")
    }

    @Test func twoTrainsThatFitAlikeAreAskedAboutOnce() throws {
        var trip = try #require(ActiveTrip(template: template, itinerary: itinerary()))
        trip.markArrived(now: t0 + 800)
        let eight = ride("8", board: 900, alight: 2_100)
        let express = ride("8X", "AX", board: 960, alight: 2_000)
        trip.apply(TrainMatch(ride: eight, rideIndex: 0, offset: 20, isConfident: false, rival: express), segment: 1, now: t0 + 1_100)
        let question = try #require(trip.trainQuestion)
        #expect(question.options.map { $0.trip?.tripID } == ["8", "8X"])
        #expect(trip.boardedBy == .likely)

        trip.answerTrainQuestion(1, now: t0 + 1_150)
        #expect(trip.trainQuestion == nil)
        #expect(trip.boardedBy == .rider)
        #expect(trip.currentLeg?.option.rides.first?.trip?.tripID == "8X")

        // Answered: never asked again on this ride.
        trip.apply(TrainMatch(ride: eight, rideIndex: 0, offset: 20, isConfident: false, rival: express), segment: 1, now: t0 + 1_300)
        #expect(trip.trainQuestion == nil)
    }

    @Test func aClearMatchSettlesTheQuestion() throws {
        var trip = try #require(ActiveTrip(template: template, itinerary: itinerary()))
        trip.markArrived(now: t0 + 800)
        let eight = ride("8", board: 900, alight: 2_100)
        trip.apply(TrainMatch(ride: eight, rideIndex: 0, offset: 20, isConfident: false, rival: ride("9", board: 960, alight: 2_160)),
                   segment: 1, now: t0 + 1_100)
        #expect(trip.trainQuestion != nil)
        trip.apply(TrainMatch(ride: eight, rideIndex: 0, offset: 5, isConfident: true), segment: 1, now: t0 + 1_200)
        #expect(trip.trainQuestion == nil)
        #expect(trip.boardedBy == .location)
    }

    @Test func passingUnderTheDestinationOnTheTrainIsNotArriving() throws {
        // The office is 350 m short of Station B, along the line: the train runs right under it on the way in.
        let office = Waypoint(name: "Office", coordinate: Coordinate(latitude: 40.75 - 350 / 111_320, longitude: -73.99))
        let template = TripTemplate(waypoints: [home, stationA, stationB, office], modes: [.drive, .transit, .walk])
        var plan = itinerary()
        var walk = plan.legs[2]
        walk.to = office
        plan = Itinerary(legs: [plan.legs[0], plan.legs[1], walk])
        var trip = try #require(ActiveTrip(template: template, itinerary: plan))
        trip.markArrived(now: t0 + 800)
        trip.update(location: nil, now: t0 + 1_000)
        #expect(trip.hasBoarded)

        // A minute out, under the office: a cell-tower fix, then one with the train's speed.
        trip.update(fix: LocationFix(coordinate: office.coordinate, time: t0 + 2_040, accuracy: 400), now: t0 + 2_040)
        trip.update(fix: LocationFix(coordinate: office.coordinate, time: t0 + 2_050, accuracy: 30, speed: 12), now: t0 + 2_050)
        #expect(trip.currentSegment == 1)

        // In at B; the same stale fix, heard again, isn't walking there either.
        trip.update(fix: LocationFix(coordinate: stationB.coordinate, time: t0 + 2_110, accuracy: 30, speed: 0), now: t0 + 2_110)
        #expect(trip.currentSegment == 2)
        trip.update(fix: LocationFix(coordinate: office.coordinate, time: t0 + 2_050, accuracy: 30, speed: 12), now: t0 + 2_120)
        trip.update(fix: LocationFix(coordinate: office.coordinate, time: t0 + 2_115, accuracy: 30, speed: 1.4), now: t0 + 2_115)
        #expect(!trip.isFinished)
        trip.crossed("end.2", entered: true, now: t0 + 2_120)
        #expect(!trip.isFinished)

        // Up to the street and back along it: there.
        trip.update(fix: LocationFix(coordinate: office.coordinate, time: t0 + 2_300, accuracy: 15, speed: 1.3), now: t0 + 2_300)
        #expect(trip.isFinished)
    }
}
