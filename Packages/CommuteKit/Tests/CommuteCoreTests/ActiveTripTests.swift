import Foundation
import Testing
@testable import CommuteCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

// Home --drive--> Station A --transit--> Station B --walk--> Office, spaced far apart.
private let home = Waypoint(name: "Home", coordinate: Coordinate(latitude: 40.70, longitude: -74.10))
private let stationA = Waypoint(name: "Station A", coordinate: Coordinate(latitude: 40.72, longitude: -74.05), kind: .stop(feedID: "f", stopID: "A"))
private let stationB = Waypoint(name: "Station B", coordinate: Coordinate(latitude: 40.75, longitude: -73.99), kind: .stop(feedID: "f", stopID: "B"))
private let office = Waypoint(name: "Office", coordinate: Coordinate(latitude: 40.755, longitude: -73.985))
private let template = TripTemplate(waypoints: [home, stationA, stationB, office], modes: [.drive, .transit, .walk])

private func ride(_ route: String, board: TimeInterval, alight: TimeInterval, delay: TimeInterval = 0) -> Ride {
    Ride(routeName: route, boardStopName: "Station A", alightStopName: "Station B",
         scheduledBoard: t0 + board, board: t0 + board + delay, alight: t0 + alight + delay)
}

/// Drive 10 min, train at +15 (20 min ride), walk 5 min. Legs are numbered from `first`, as the planner does for a partial template.
private func itinerary(train: TimeInterval = 900, route: String = "A", delay: TimeInterval = 0, from first: Int = 0, driveStart: TimeInterval = 300) -> Itinerary {
    let all = [
        Leg(segmentIndex: 0, from: home, to: stationA, option: LegOption(mode: .drive, departure: t0 + driveStart, arrival: t0 + driveStart + 600)),
        Leg(segmentIndex: 1, from: stationA, to: stationB, option: LegOption(mode: .transit, departure: t0 + train + delay, arrival: t0 + train + 1200 + delay,
                                                                           rides: [ride(route, board: train, alight: train + 1200, delay: delay)])),
        Leg(segmentIndex: 2, from: stationB, to: office, option: LegOption(mode: .walk, departure: t0 + train + 1200 + delay, arrival: t0 + train + 1500 + delay)),
    ]
    return Itinerary(legs: all[first...].enumerated().map { offset, leg in
        var leg = leg
        leg.segmentIndex = offset
        return leg
    })
}

@Suite struct ActiveTripTests {
    @Test func requiresAnItineraryThatCoversTheTemplate() {
        #expect(ActiveTrip(template: template, itinerary: itinerary()) != nil)
        #expect(ActiveTrip(template: template, itinerary: itinerary(from: 1)) == nil)
    }

    @Test func replansTheDriveFromTheCurrentLocationAndStopsDelayingOnceMoving() throws {
        var trip = try #require(ActiveTrip(template: template, itinerary: itinerary()))
        trip.update(location: home.coordinate, now: t0)
        let waiting = try #require(trip.replanRequest(location: home.coordinate, now: t0))
        #expect(waiting.firstSegment == 0)
        #expect(waiting.canDelayDeparture)
        #expect(waiting.template.modes == [.drive, .transit, .walk])
        #expect(waiting.template.waypoints.first?.kind == .currentLocation)

        let onTheRoad = Coordinate(latitude: 40.71, longitude: -74.08)
        let moved1 = trip.update(location: onTheRoad, now: t0 + 400)
        #expect(!moved1)
        #expect(trip.isMoving)
        let driving = try #require(trip.replanRequest(location: onTheRoad, now: t0 + 400))
        #expect(!driving.canDelayDeparture)
        #expect(driving.template.waypoints.first?.coordinate == onTheRoad)
    }

    @Test func advancesByProximityAndAssumesBoardingWhenTheTrainLeaves() throws {
        var trip = try #require(ActiveTrip(template: template, itinerary: itinerary()))
        let moved2 = trip.update(location: stationA.coordinate, now: t0 + 850)
        #expect(moved2)
        #expect(trip.currentSegment == 1)
        #expect(!trip.hasBoarded)

        // Waiting on the platform: the whole rest of the trip is still open, starting from this station.
        let waiting = try #require(trip.replanRequest(location: stationA.coordinate, now: t0 + 850))
        #expect(waiting.firstSegment == 1)
        #expect(waiting.template.waypoints.map(\.name) == ["Station A", "Station B", "Office"])

        // Underground with no fix: the clock says the train has gone, so the ride is fixed and only the walk re-plans.
        trip.update(location: nil, now: t0 + 940)
        #expect(trip.hasBoarded)
        #expect(trip.currentRide(at: t0 + 940)?.routeName == "A")
        let riding = try #require(trip.replanRequest(location: nil, now: t0 + 940))
        #expect(riding.firstSegment == 2)
        #expect(riding.departure == t0 + 2100)
        #expect(riding.template.modes == [.walk])
    }

    @Test func aGenerousRadiusAppliesOnlyWhenTheTrainIsDueIn() throws {
        var trip = try #require(ActiveTrip(template: template, itinerary: itinerary()))
        trip.update(location: stationA.coordinate, now: t0 + 850)
        trip.update(location: nil, now: t0 + 940)
        let surfaced = Coordinate(latitude: 40.7535, longitude: -73.99) // ~390 m from Station B's pin
        let moved3 = trip.update(location: surfaced, now: t0 + 1500)
        #expect(!moved3)
        let moved4 = trip.update(location: surfaced, now: t0 + 2050)
        #expect(moved4)
        #expect(trip.currentLeg?.mode == .walk)
    }

    @Test func keepsFollowingTheSameTrainAndPicksUpItsDelay() throws {
        var trip = try #require(ActiveTrip(template: template, itinerary: itinerary()))
        let request = try #require(trip.replanRequest(location: home.coordinate, now: t0))
        trip.apply([itinerary(delay: 120), itinerary(train: 1500)], for: request)
        #expect(trip.notice == nil)
        #expect(trip.legs[1].option.rides.first?.board == t0 + 1020)
        #expect(trip.arrival == t0 + 900 + 1500 + 120)
    }

    @Test func switchesPlansWhenTheTrainCanNoLongerBeCaught() throws {
        var trip = try #require(ActiveTrip(template: template, itinerary: itinerary()))
        let request = try #require(trip.replanRequest(location: home.coordinate, now: t0 + 700))
        trip.apply([itinerary(train: 1500)], for: request)
        guard case .planChanged(let previousArrival) = trip.notice else {
            Issue.record("expected a plan change notice")
            return
        }
        #expect(previousArrival == t0 + 2400)
        #expect(trip.arrival == t0 + 3000)
        trip.dismissNotice()
        #expect(trip.notice == nil)
    }

    @Test func offersAFasterOptionOnlyWhenItSavesRealTime() throws {
        var trip = try #require(ActiveTrip(template: template, itinerary: itinerary(train: 1500)))
        let request = try #require(trip.replanRequest(location: home.coordinate, now: t0))

        // An express that arrives 3 minutes sooner isn't worth an interruption.
        var marginal = itinerary(train: 1500, route: "X")
        marginal.legs[1].option.arrival -= 180
        marginal.legs[2].option.arrival -= 180
        trip.apply([marginal, itinerary(train: 1500)], for: request)
        #expect(trip.notice == nil)

        // The earlier train turning out to be catchable (10 minutes sooner) is.
        trip.apply([itinerary(train: 900), itinerary(train: 1500)], for: request)
        guard case .fasterOption(let faster) = trip.notice else {
            Issue.record("expected a faster option")
            return
        }
        trip.follow(faster)
        #expect(trip.notice == nil)
        #expect(trip.arrival == t0 + 2400)
    }

    @Test func aMissedTrainReplansFromTheStationAndPartialPlansSliceIn() throws {
        var trip = try #require(ActiveTrip(template: template, itinerary: itinerary()))
        trip.update(location: stationA.coordinate, now: t0 + 880)
        trip.update(location: nil, now: t0 + 960)
        #expect(trip.hasBoarded)

        trip.markMissed()
        trip.update(location: nil, now: t0 + 970)
        #expect(!trip.hasBoarded)
        let request = try #require(trip.replanRequest(location: nil, now: t0 + 970))
        #expect(request.firstSegment == 1)

        trip.apply([itinerary(train: 1500, from: 1)], for: request)
        #expect(trip.legs.map(\.segmentIndex) == [0, 1, 2])
        #expect(trip.legs[0].mode == .drive)
        #expect(trip.legs[1].option.rides.first?.board == t0 + 1500)
        guard case .planChanged = trip.notice else {
            Issue.record("expected a plan change notice")
            return
        }
    }

    @Test func ignoresPlansThatArriveAfterTheRiderMovedOnAndFinishesAtTheEnd() throws {
        var trip = try #require(ActiveTrip(template: template, itinerary: itinerary()))
        let stale = try #require(trip.replanRequest(location: home.coordinate, now: t0))
        trip.update(location: stationA.coordinate, now: t0 + 850)
        trip.apply([itinerary(train: 1500)], for: stale)
        #expect(trip.legs[1].option.rides.first?.board == t0 + 900)

        trip.markArrived()
        trip.markArrived()
        #expect(trip.isFinished)
        #expect(trip.currentLeg == nil)
        #expect(trip.replanRequest(location: nil, now: t0) == nil)
        trip.markArrived()
        #expect(trip.currentSegment == 3)
    }
}

extension ActiveTrip.Notice: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.planChanged(let a), .planChanged(let b)): a == b
        case (.fasterOption(let a), .fasterOption(let b)): a.id == b.id
        default: false
        }
    }
}

extension ActiveTrip.ReplanRequest: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.template == rhs.template && lhs.departure == rhs.departure && lhs.firstSegment == rhs.firstSegment
    }
}
