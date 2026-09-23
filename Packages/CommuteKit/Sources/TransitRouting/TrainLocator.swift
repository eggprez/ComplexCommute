import CommuteCore
import Foundation
import GTFSKit

/// Where a vehicle should be right now, worked out from its live times (or its schedule, without them) between stops.
public struct VehicleEstimate: Identifiable, Hashable, Sendable {
    public let trip: TripRef
    public let route: RouteBadge
    public let headsign: String?
    public let coordinate: Coordinate
    /// The stop it is at, or the one it left.
    public let lastStop: String
    public let nextStop: String
    public let nextStopTime: Date
    public let isAtStop: Bool
    public let isRealtime: Bool

    public var id: TripRef { trip }
}

extension Timetable {
    /// A pattern that picks up at one station and later lets off at another: one way of going the rider's way.
    struct Run: Hashable {
        let pattern: Int
        let board: Int
        let alight: Int
    }

    /// A scheduled trip that fits the rider's location fixes.
    struct TripFit {
        let run: Run
        let trip: Int
        /// Mean seconds between when the fixes put the rider somewhere and when this trip was there.
        let offset: Double
        let isConfident: Bool
    }

    /// Off the platform by this much before a fix says anything about which train the rider is on: standing on it
    /// fits every train that calls there.
    static let leftPlatformMeters = 200.0
    /// Seconds a fix may be out from a train's timing and still be taken as riding it.
    static let fitSeconds = 120.0
    /// Tighter, over more fixes, to act on without asking.
    static let confidentFitSeconds = 75.0
    /// The next best train has to fit this much worse for the best to count as clear of it.
    static let rivalMarginSeconds = 60.0

    /// Every pattern that picks up at `board`'s station and goes on to let off at `alight`'s, whatever the line.
    func runs(from board: (feedID: String, stopID: String), to alight: (feedID: String, stopID: String)) -> [Run] {
        let alightStations = Set(platforms(feedID: alight.feedID, stopID: alight.stopID).map { stops[$0].station })
        guard !alightStations.isEmpty else { return [] }
        var seen = Set<Int>()
        var runs: [Run] = []
        for platform in platforms(feedID: board.feedID, stopID: board.stopID) {
            for (index, position) in patternsAtStop[platform] where seen.insert(index).inserted {
                let pattern = patterns[index]
                guard pattern.canBoard[position], let end = pattern.stops.indices.dropFirst(position + 1).first(where: {
                    pattern.canAlight[$0] && alightStations.contains(stops[pattern.stops[$0]].station)
                }) else { continue }
                runs.append(Run(pattern: index, board: position, alight: end))
            }
        }
        return runs
    }

    /// Finds a trip by its identity, among `runs`.
    func locate(_ trip: TripRef, in runs: [Run]) -> (run: Run, trip: Int)? {
        for run in runs {
            if let index = patterns[run.pattern].trips.firstIndex(of: trip) { return (run, index) }
        }
        return nil
    }

    /// The trip on `runs` whose timing the fixes keep pace with, if any does.
    func fit(_ fixes: [LocationFix], to runs: [Run]) -> TripFit? {
        struct Sample {
            let time: Double
            let along: Double
            let offset: Double
        }
        var samples: [String: (run: Run, trip: Int, samples: [Sample])] = [:]

        for run in runs {
            let pattern = patterns[run.pattern]
            let points = (run.board...run.alight).map { stops[pattern.stops[$0]].coordinate }
            let boardPoint = points[0]
            for fix in fixes where fix.accuracy <= 150 && fix.coordinate.distance(to: boardPoint) > Self.leftPlatformMeters {
                guard let (segment, fraction, along) = Self.project(fix.coordinate, onto: points, accuracy: fix.accuracy),
                      along > Self.leftPlatformMeters else { continue }
                let time = fix.time.timeIntervalSince(midnight)
                let from = run.board + segment
                let length = points[segment].distance(to: points[segment + 1])
                let nearStart = fraction * length < 120
                let nearEnd = (1 - fraction) * length < 120

                for trip in 0..<pattern.tripCount {
                    let leaves = Double(pattern.departure(trip: trip, position: run.board))
                    let arrives = Double(pattern.arrival(trip: trip, position: run.alight))
                    guard leaves - 600 <= time, time <= arrives + 600 else { continue }
                    // When this trip would have been where the fix is: any time in its dwell, at a station.
                    let window: (Double, Double)
                    if nearStart {
                        window = (Double(pattern.arrival(trip: trip, position: from)), Double(pattern.departure(trip: trip, position: from)))
                    } else if nearEnd {
                        window = (Double(pattern.arrival(trip: trip, position: from + 1)), Double(pattern.departure(trip: trip, position: from + 1)))
                    } else {
                        let start = Double(pattern.departure(trip: trip, position: from))
                        let end = Double(pattern.arrival(trip: trip, position: from + 1))
                        let at = start + fraction * (end - start)
                        window = (at, at)
                    }
                    let offset = time < window.0 ? window.0 - time : time > window.1 ? time - window.1 : 0
                    let key = "\(run.pattern)/\(trip)"
                    samples[key, default: (run, trip, [])].samples.append(Sample(time: time, along: along, offset: offset))
                }
            }
        }

        let scored = samples.values.map { entry -> (run: Run, trip: Int, samples: [Sample], mean: Double) in
            (entry.run, entry.trip, entry.samples, entry.samples.map(\.offset).reduce(0, +) / Double(entry.samples.count))
        }
        .sorted { $0.mean < $1.mean }
        guard let best = scored.first, best.mean <= Self.fitSeconds else { return nil }

        // The same vehicle can show up through two runs (a platform pair); only a different trip is a rival.
        let bestTrip = patterns[best.run.pattern].trips[best.trip]
        let rival = scored.dropFirst().first { patterns[$0.run.pattern].trips[$0.trip] != bestTrip }
        let ordered = best.samples.sorted { $0.time < $1.time }
        let span = (ordered.last?.time ?? 0) - (ordered.first?.time ?? 0)
        let travelled = (ordered.last?.along ?? 0) - (ordered.first?.along ?? 0)
        let isConfident = ordered.count >= 2 && span >= 45 && travelled >= 300 && best.mean <= Self.confidentFitSeconds
            && rival.map { $0.mean >= best.mean + Self.rivalMarginSeconds } ?? true
        return TripFit(run: best.run, trip: best.trip, offset: best.mean, isConfident: isConfident)
    }

    /// Where `coordinate` lies along the straight lines between `points`, if it is on them at all:
    /// the segment, how far along it, and meters from the first point.
    static func project(_ coordinate: Coordinate, onto points: [Coordinate], accuracy: Double) -> (segment: Int, fraction: Double, along: Double)? {
        guard points.count > 1 else { return nil }
        let metersPerLatitude = 111_320.0
        let metersPerLongitude = metersPerLatitude * cos(coordinate.latitude * .pi / 180)
        func point(_ c: Coordinate) -> (x: Double, y: Double) {
            ((c.longitude - coordinate.longitude) * metersPerLongitude, (c.latitude - coordinate.latitude) * metersPerLatitude)
        }
        var best: (segment: Int, fraction: Double, distance: Double, along: Double)?
        var covered = 0.0
        for index in 0..<(points.count - 1) {
            let (a, b) = (point(points[index]), point(points[index + 1]))
            let (dx, dy) = (b.x - a.x, b.y - a.y)
            let length = hypot(dx, dy)
            let fraction = length == 0 ? 0 : max(0, min(1, (-a.x * dx - a.y * dy) / (length * length)))
            let distance = hypot(a.x + fraction * dx, a.y + fraction * dy)
            // Tracks curve between stations; the further apart they are, the further the line can stray from straight.
            let tolerance = max(250, accuracy * 1.5, min(800, length * 0.2))
            if distance <= tolerance, best.map({ distance < $0.distance }) ?? true {
                best = (index, fraction, distance, covered + fraction * length)
            }
            covered += length
        }
        return best.map { ($0.segment, $0.fraction, $0.along) }
    }

    /// Where every vehicle on `runs` is at `time`, up to where the rider gets off: the trains coming for them,
    /// and the ones ahead.
    func vehicles(on runs: [Run], at time: Int) -> [VehicleEstimate] {
        var found: [VehicleEstimate] = []
        var seen = Set<TripRef>()
        for run in runs {
            let pattern = patterns[run.pattern]
            for trip in 0..<pattern.tripCount {
                guard pattern.departure(trip: trip, position: 0) <= time, time < pattern.arrival(trip: trip, position: run.alight) else { continue }
                // The last stop it has reached by now.
                guard let at = (0...run.alight).last(where: { pattern.arrival(trip: trip, position: $0) <= time }) else { continue }
                let here = stops[pattern.stops[at]]
                let isAtStop = time <= pattern.departure(trip: trip, position: at) || at == run.alight
                let next = isAtStop ? at : at + 1
                let coordinate: Coordinate
                if isAtStop {
                    coordinate = here.coordinate
                } else {
                    let there = stops[pattern.stops[next]].coordinate
                    let start = pattern.departure(trip: trip, position: at)
                    let end = pattern.arrival(trip: trip, position: next)
                    let fraction = end > start ? Double(time - start) / Double(end - start) : 0
                    coordinate = Coordinate(latitude: here.coordinate.latitude + (there.latitude - here.coordinate.latitude) * fraction,
                                            longitude: here.coordinate.longitude + (there.longitude - here.coordinate.longitude) * fraction)
                }
                guard seen.insert(pattern.trips[trip]).inserted else { continue }
                found.append(VehicleEstimate(
                    trip: pattern.trips[trip], route: routes[pattern.route], headsign: pattern.headsigns[trip], coordinate: coordinate,
                    lastStop: here.name, nextStop: stops[pattern.stops[next]].name,
                    nextStopTime: midnight.addingTimeInterval(TimeInterval(pattern.arrival(trip: trip, position: next))),
                    isAtStop: isAtStop, isRealtime: pattern.isRealtime[trip]
                ))
            }
        }
        return found
    }
}
