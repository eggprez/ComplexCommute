import Foundation
import Testing
@testable import CommuteCore

private func waypoint(_ name: String) -> Waypoint {
    Waypoint(name: name, coordinate: Coordinate(latitude: 0, longitude: 0))
}

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// Drive/walk take a fixed time; transit departs every `headway` seconds on the clock.
private struct FakeResolver: LegResolving {
    var headway: TimeInterval = 600
    var unroutable: Set<TravelMode> = []

    func options(from: Waypoint, to: Waypoint, mode: TravelMode, departingAt: Date, isWaitingAtOrigin: Bool,
                 excludedFeedIDs: Set<String>) async throws -> [LegOption] {
        guard !unroutable.contains(mode) else { return [] }
        switch mode {
        case .drive:
            return [LegOption(mode: .drive, departure: departingAt, arrival: departingAt + 900)]
        case .walk:
            return [LegOption(mode: .walk, departure: departingAt, arrival: departingAt + 300, walkingMeters: 400)]
        case .transit:
            let elapsed = departingAt.timeIntervalSince(t0)
            let next = t0 + (elapsed / headway).rounded(.up) * headway
            return (0..<3).map { index in
                let board = next + Double(index) * headway
                let ride = Ride(routeName: "A", boardStopName: from.name, alightStopName: to.name,
                                scheduledBoard: board, board: board, alight: board + 1200)
                return LegOption(mode: .transit, departure: board, arrival: board + 1200, rides: [ride])
            }
        }
    }
}

@Suite struct TripTemplateTests {
    @Test func insertAndRemoveKeepModeInvariant() {
        var template = TripTemplate()
        template.append(waypoint("A"), mode: .drive)
        #expect(template.modes.isEmpty)
        template.append(waypoint("C"), mode: .transit)
        template.insert(waypoint("B"), at: 1, mode: .walk)
        #expect(template.waypoints.map(\.name) == ["A", "B", "C"])
        #expect(template.modes == [.transit, .walk])

        template.removeWaypoint(at: 2)
        #expect(template.modes == [.transit])
        template.removeWaypoint(at: 0)
        #expect(template.modes.isEmpty)
        #expect(!template.isPlannable)
    }

    @Test func roundTripsThroughJSON() throws {
        var template = TripTemplate(waypoints: [.currentLocation(), waypoint("Station")], modes: [.drive])
        template.append(Waypoint(name: "Stop", coordinate: Coordinate(latitude: 1, longitude: 2), kind: .stop(feedID: "mta", stopID: "127")), mode: .transit)
        template.excludedFeedIDs = ["njt-bus"]
        let decoded = try JSONDecoder().decode(TripTemplate.self, from: JSONEncoder().encode(template))
        #expect(decoded == template)
    }

    @Test func commutesSavedBeforeServiceChoicesUseEveryService() throws {
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(
            TripTemplate(waypoints: [waypoint("A"), waypoint("B")], modes: [.transit], excludedFeedIDs: ["path"]))) as? [String: Any])
        json["excludedFeedIDs"] = nil
        let decoded = try JSONDecoder().decode(TripTemplate.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.excludedFeedIDs.isEmpty)
        #expect(decoded.waypoints.map(\.name) == ["A", "B"])
    }

    @Test func theRestOfATripKeepsItsServiceChoices() {
        let template = TripTemplate(waypoints: [waypoint("A"), waypoint("B"), waypoint("C")], modes: [.walk, .transit],
                                    excludedFeedIDs: ["mta-lirr"])
        let rest = template.suffix(from: 1)
        #expect(rest.waypoints.map(\.name) == ["B", "C"])
        #expect(rest.modes == [.transit])
        #expect(rest.excludedFeedIDs == ["mta-lirr"])
    }
}

@Suite struct ChainPlannerTests {
    let template = TripTemplate(
        waypoints: [waypoint("Home"), waypoint("Apartment"), waypoint("Station"), waypoint("Downtown"), waypoint("Office")],
        modes: [.drive, .walk, .transit, .walk]
    )

    @Test func chainsLegsInOrderWithoutOverlap() async throws {
        let itineraries = try await ChainPlanner(resolver: FakeResolver()).plan(template, departingAt: t0)
        #expect(itineraries.count == 3)
        for itinerary in itineraries {
            #expect(itinerary.legs.map(\.mode) == [.drive, .walk, .transit, .walk])
            for (previous, next) in zip(itinerary.legs, itinerary.legs.dropFirst()) {
                #expect(next.departure >= previous.arrival)
            }
        }
        #expect(itineraries.map(\.arrival) == itineraries.map(\.arrival).sorted())
    }

    @Test func leadingLegsSlideToMeetTheTrain() async throws {
        let best = try #require(try await ChainPlanner(resolver: FakeResolver()).plan(template, departingAt: t0).first)
        // Drive 15 min + walk 5 min = ready at +20:00, which is exactly a departure; no waiting anywhere.
        #expect(best.departure == t0)
        #expect(best.wait(before: 2) == 0)

        let later = try #require(try await ChainPlanner(resolver: FakeResolver()).plan(template, departingAt: t0 + 60).first)
        // Ready at +21:00, next train +30:00: leave 9 min later instead of waiting on the platform.
        #expect(later.departure == t0 + 600)
        #expect(later.wait(before: 2) == 0)
        #expect(later.arrival == t0 + 1800 + 1200 + 300)
    }

    @Test func selectionIDIsStableAcrossReplans() async throws {
        let planner = ChainPlanner(resolver: FakeResolver())
        let first = try await planner.plan(template, departingAt: t0)
        let second = try await planner.plan(template, departingAt: t0 + 30)
        #expect(Set(first.map(\.id)).isSuperset(of: second.map(\.id).prefix(2)))
    }

    @Test func reportsTheSegmentThatCannotBeRouted() async {
        let planner = ChainPlanner(resolver: FakeResolver(unroutable: [.transit]))
        await #expect(throws: PlanningError.noRoute(segmentIndex: 2)) {
            try await planner.plan(template, departingAt: t0)
        }
    }

    @Test func tagsFastestOption() async throws {
        let itineraries = try await ChainPlanner(resolver: FakeResolver()).plan(template, departingAt: t0)
        let tags = ChainPlanner.tags(for: itineraries)
        #expect(tags[itineraries[0].id] == [.fastest])
    }
}

@Suite struct PathClippingTests {
    /// An L-shaped line: north along longitude -74 from 40.00 to 40.10, then east to -73.90.
    private static let shape = [
        Coordinate(latitude: 40.00, longitude: -74.00), Coordinate(latitude: 40.05, longitude: -74.00),
        Coordinate(latitude: 40.10, longitude: -74.00), Coordinate(latitude: 40.10, longitude: -73.95),
        Coordinate(latitude: 40.10, longitude: -73.90),
    ]

    @Test func followsTheShapeBetweenTheBoardingAndExitStops() throws {
        // Board a little off the line part-way up the first stretch; exit part-way along the second.
        let board = Coordinate(latitude: 40.02, longitude: -74.0003)
        let exit = Coordinate(latitude: 40.1002, longitude: -73.97)
        let path = try #require(Self.shape.clipped(passing: [board, exit]))

        #expect(path.count == 4) // snapped board, the two vertices between (40.05 and the corner), snapped exit
        #expect(abs(path[0].latitude - 40.02) < 0.0001 && abs(path[0].longitude + 74.00) < 0.0001)
        #expect(path[2] == Coordinate(latitude: 40.10, longitude: -74.00))
        #expect(abs(path[3].longitude + 73.97) < 0.0001 && abs(path[3].latitude - 40.10) < 0.0001)
    }

    @Test func refusesAShapeThatDoesNotPassTheStops() {
        let elsewhere = [Coordinate(latitude: 41, longitude: -75), Coordinate(latitude: 41.1, longitude: -75)]
        #expect(Self.shape.clipped(passing: elsewhere) == nil)
    }

    @Test func aLoopIsCutAtThePassTheStopsAreOn() throws {
        // Out along a street and back along the same street: the ride is on the way back.
        let loop = [
            Coordinate(latitude: 40.00, longitude: -74.00), Coordinate(latitude: 40.04, longitude: -74.00),
            Coordinate(latitude: 40.04, longitude: -73.99), Coordinate(latitude: 40.04, longitude: -74.00),
            Coordinate(latitude: 40.00, longitude: -74.00),
        ]
        let stops = [Coordinate(latitude: 40.04, longitude: -73.99), Coordinate(latitude: 40.03, longitude: -74.00), Coordinate(latitude: 40.01, longitude: -74.00)]
        let path = try #require(loop.clipped(passing: stops))
        #expect(path.first == Coordinate(latitude: 40.04, longitude: -73.99))
        // Heading back down: the corner, then south to the exit.
        #expect(path.count == 3)
        #expect(abs((path.last?.latitude ?? 0) - 40.01) < 0.0001)
    }

    @Test func simplifyingKeepsCornersAndDropsPointsOnTheLine() {
        let simplified = Self.shape.simplified(toleranceMeters: 4)
        #expect(simplified == [Self.shape[0], Self.shape[2], Self.shape[4]])
    }
}

@Suite struct ArriveByPlanningTests {
    // Drive 15 min, walk 5, a train every 10 minutes for 20, then a 5 minute walk: 45 minutes door to door.
    let template = TripTemplate(
        waypoints: [waypoint("Home"), waypoint("Apartment"), waypoint("Station"), waypoint("Downtown"), waypoint("Office")],
        modes: [.drive, .walk, .transit, .walk]
    )

    @Test func leavesAsLateAsTheLastTrainThatMakesItAllows() async throws {
        let target = t0 + 10_000
        let planned = try await ChainPlanner(resolver: FakeResolver()).plan(template, arrivingBy: target, notBefore: t0)
        let best = try #require(planned.first)
        #expect(best.arrival <= target)
        // The 2:20 train is the last one that gets there in time, and the drive meets it.
        #expect(best.legs[2].departure == t0 + 8_400)
        #expect(best.departure == t0 + 7_200)
        #expect(planned.allSatisfy { $0.arrival <= target || $0.departure > best.departure })
    }

    @Test func ordersTheOnesThatMakeItByHowLateTheyLetYouLeave() async throws {
        let planned = try await ChainPlanner(resolver: FakeResolver()).plan(template, arrivingBy: t0 + 10_000, notBefore: t0)
        let makesIt = planned.filter { $0.arrival <= t0 + 10_000 }
        #expect(makesIt.count > 1)
        #expect(makesIt.map(\.departure) == makesIt.map(\.departure).sorted(by: >))
    }

    @Test func neverLeavesBeforeTheRiderCan() async throws {
        let planned = try await ChainPlanner(resolver: FakeResolver()).plan(template, arrivingBy: t0 + 10_000, notBefore: t0 + 6_000)
        #expect(planned.allSatisfy { $0.departure >= t0 + 6_000 })
        #expect(planned.first?.arrival ?? .distantFuture <= t0 + 10_000)
    }

    @Test func showsTheLeastLateOptionWhenTheTargetCannotBeMet() async throws {
        let planned = try await ChainPlanner(resolver: FakeResolver()).plan(template, arrivingBy: t0 + 1_000, notBefore: t0)
        let best = try #require(planned.first)
        #expect(best.arrival > t0 + 1_000)
        #expect(best.arrival == t0 + 2_700) // the soonest it can be done at all
        #expect(planned.map(\.arrival) == planned.map(\.arrival).sorted())
    }

    @Test func stillPlansWhenOnlyPartOfTheTripCanBeRouted() async throws {
        let planner = ChainPlanner(resolver: FakeResolver(unroutable: [.transit]))
        await #expect(throws: PlanningError.noRoute(segmentIndex: 2)) {
            try await planner.plan(template, arrivingBy: t0 + 10_000, notBefore: t0)
        }
    }
}

@Suite struct ArriveByConvergenceTests {
    let template = TripTemplate(
        waypoints: [waypoint("Home"), waypoint("Apartment"), waypoint("Station"), waypoint("Downtown"), waypoint("Office")],
        modes: [.drive, .walk, .transit, .walk]
    )

    /// A target a minute before a train gets in: aiming straight at it would keep landing on the same
    /// train, so the search has to work its way back to an earlier one.
    @Test func closesOnAnEarlierTrainWhenTheIdealOneJustMissesIt() async throws {
        let target = t0 + 9_899
        let planned = try await ChainPlanner(resolver: FakeResolver()).plan(template, arrivingBy: target, notBefore: t0)
        let best = try #require(planned.first)
        #expect(best.arrival <= target)
        // Better than giving up on the first pass, which would have left at t0 + 1,200.
        #expect(best.departure >= t0 + 4_200)
    }

    @Test func stopsAtTheEarliestDepartureWhenTheTargetIsAlreadyPast() async throws {
        let planned = try await ChainPlanner(resolver: FakeResolver()).plan(template, arrivingBy: t0 - 3_600, notBefore: t0)
        #expect(planned.allSatisfy { $0.departure >= t0 })
        #expect(planned.first?.arrival == t0 + 2_700)
    }
}
