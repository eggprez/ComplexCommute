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

    func options(from: Waypoint, to: Waypoint, mode: TravelMode, departingAt: Date) async throws -> [LegOption] {
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
        let decoded = try JSONDecoder().decode(TripTemplate.self, from: JSONEncoder().encode(template))
        #expect(decoded == template)
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
