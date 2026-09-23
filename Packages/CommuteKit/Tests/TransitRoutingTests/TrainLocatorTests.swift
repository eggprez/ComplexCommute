import CommuteCore
import Foundation
import GTFSKit
import Testing
@testable import TransitRouting

private let eight = 8 * 3600
private let north = 1_000.0 / 111_320

/// A line due north, a stop every kilometre: A B C D E. Locals every 5 min from 8:00 take 2 min a stop;
/// an express leaves A at 8:02 and runs to E in 5 min without stopping.
private func line() -> Timetable {
    var data = FeedTimetableData(feedID: "f", stops: [], routes: [], trips: [], stopTimes: [])
    for (index, id) in ["A", "B", "C", "D", "E"].enumerated() {
        data.stops.append(.init(id: id, name: id, coordinate: Coordinate(latitude: 40 + Double(index) * north, longitude: -74)))
    }
    data.routes = [RouteBadge(name: "Local"), RouteBadge(name: "Express")]
    func trip(_ id: String, route: Int, calls: [(Int, Int)]) {
        let first = data.stopTimes.count
        for (stop, time) in calls { data.stopTimes.append(.init(stop: stop, arrival: time, departure: time)) }
        data.trips.append(.init(id: id, serviceDate: 20260922, route: route, headsign: "E", stopTimes: first..<data.stopTimes.count))
    }
    for start in stride(from: eight, through: eight + 1_800, by: 300) {
        trip("local-\(start - eight)", route: 0, calls: (0..<5).map { ($0, start + $0 * 120) })
    }
    trip("express", route: 1, calls: [(0, eight + 120), (4, eight + 420)])
    return Timetable(feeds: [data])
}

/// Where the line is `meters` north of A, at `seconds` after 8:00.
private func fix(_ meters: Double, at seconds: Int, accuracy: Double = 30) -> LocationFix {
    LocationFix(coordinate: Coordinate(latitude: 40 + meters / 111_320, longitude: -74),
                time: Date(timeIntervalSince1970: TimeInterval(eight + seconds)), accuracy: accuracy)
}

@Suite struct TrainLocatorTests {
    @Test func findsEveryWayOfGoingTheRidersWay() {
        let timetable = line()
        #expect(timetable.runs(from: ("f", "A"), to: ("f", "C")).map { timetable.routes[timetable.patterns[$0.pattern].route].name } == ["Local"])
        #expect(Set(timetable.runs(from: ("f", "A"), to: ("f", "E")).map { timetable.routes[timetable.patterns[$0.pattern].route].name }) == ["Local", "Express"])
        #expect(timetable.runs(from: ("f", "C"), to: ("f", "A")).isEmpty)
    }

    @Test func picksTheTrainTheFixesKeepPaceWith() throws {
        let timetable = line()
        let runs = timetable.runs(from: ("f", "A"), to: ("f", "E"))
        // Left A on the 8:05 local: half way to B a minute later, half way to C a minute after passing B.
        let fitted = try #require(timetable.fit([fix(500, at: 360), fix(1_500, at: 480)], to: runs))
        #expect(timetable.patterns[fitted.run.pattern].trips[fitted.trip].tripID == "local-300")
        #expect(fitted.offset < 5)
        #expect(fitted.isConfident)
    }

    @Test func tellsTheExpressFromTheLocal() throws {
        let timetable = line()
        let runs = timetable.runs(from: ("f", "A"), to: ("f", "E"))
        // 800 m a minute from 8:02, gaining on the 8:00 local.
        let fitted = try #require(timetable.fit([fix(400, at: 150), fix(1_200, at: 210)], to: runs))
        #expect(timetable.patterns[fitted.run.pattern].trips[fitted.trip].tripID == "express")
        #expect(fitted.isConfident)
    }

    @Test func oneFixIsOnlyASuggestion() throws {
        let timetable = line()
        let fitted = try #require(timetable.fit([fix(500, at: 360)], to: timetable.runs(from: ("f", "A"), to: ("f", "E"))))
        #expect(timetable.patterns[fitted.run.pattern].trips[fitted.trip].tripID == "local-300")
        #expect(!fitted.isConfident)
    }

    @Test func standingOnThePlatformOrOffTheLineSaysNothing() {
        let timetable = line()
        let runs = timetable.runs(from: ("f", "A"), to: ("f", "E"))
        #expect(timetable.fit([fix(50, at: 300), fix(0, at: 400)], to: runs) == nil)
        let offTheLine = LocationFix(coordinate: Coordinate(latitude: 40.005, longitude: -73.98), time: Date(timeIntervalSince1970: TimeInterval(eight + 360)), accuracy: 20)
        #expect(timetable.fit([offTheLine], to: runs) == nil)
        // On the line, but nowhere near where any train was: walking along the tracks.
        #expect(timetable.fit([fix(500, at: 3_600 * 3)], to: runs) == nil)
    }

    @Test func placesEachTrainBetweenItsStops() throws {
        let timetable = line()
        let vehicles = timetable.vehicles(on: timetable.runs(from: ("f", "A"), to: ("f", "E")), at: eight + 360)
        let byTrip = Dictionary(uniqueKeysWithValues: vehicles.map { ($0.trip.tripID, $0) })

        let justLeft = try #require(byTrip["local-300"])
        #expect(!justLeft.isAtStop)
        #expect(justLeft.lastStop == "A" && justLeft.nextStop == "B")
        #expect(abs(justLeft.coordinate.latitude - (40 + 0.5 * north)) < 1e-6)

        let calling = try #require(byTrip["local-0"])
        #expect(calling.isAtStop)
        #expect(calling.lastStop == "D")

        let express = try #require(byTrip["express"])
        #expect(abs(express.coordinate.latitude - (40 + 3.2 * north)) < 1e-6)
        // Not yet left, or already done.
        #expect(byTrip["local-600"] == nil)
        #expect(vehicles.count == 3)
    }
}
