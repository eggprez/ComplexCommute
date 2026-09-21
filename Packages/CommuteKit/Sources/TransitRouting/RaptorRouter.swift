import Foundation

/// A way onto or off the network: a stop plus the walk between it and the trip's endpoint.
public struct StopAccess: Sendable {
    public let stop: Int
    public let seconds: Int
    public let meters: Double

    public init(stop: Int, seconds: Int = 0, meters: Double = 0) {
        self.stop = stop
        self.seconds = seconds
        self.meters = meters
    }
}

/// A routed trip through the timetable. Times are seconds on the timetable's clock.
public struct Journey: Sendable {
    public struct Ride: Sendable {
        let pattern: Int
        public internal(set) var trip: Int
        let boardPosition: Int
        let alightPosition: Int
        /// Walk from the previous ride's exit (or the origin) to this ride's boarding stop.
        public internal(set) var walkBefore: Walk
    }

    public struct Walk: Sendable {
        public var seconds: Int = 0
        public var meters: Double = 0
        /// Along the street to another station, rather than inside one.
        public var isStreet = false
    }

    public internal(set) var rides: [Ride]
    /// Walk from the last ride's exit to the destination.
    public let walkAfter: Walk
}

/// Round-based public transit routing (Delling, Pajor & Werneck). Round k finds the earliest arrival
/// at every stop using at most k rides, which yields the arrival-time / transfer-count trade-off for free.
public struct RaptorRouter: Sendable {
    public let timetable: Timetable
    public var maxRides = 5
    /// The rider's buffer at every change of vehicles: the least time between stepping off one and the next leaving,
    /// and the slack added on top of a street walk to another station.
    public var changeSeconds = 60

    /// Time a connection over `seconds` of footpath needs. An in-station time is already the agency's minimum for
    /// the connection, so the buffer only raises it; a street walk is just the walking, so the buffer comes on top.
    func connectionSeconds(walking seconds: Int, isStreet: Bool) -> Int {
        isStreet ? seconds + changeSeconds : max(seconds, changeSeconds)
    }

    public init(timetable: Timetable) {
        self.timetable = timetable
    }

    private enum Parent {
        case none
        case access(Int)
        case walk(from: Int, seconds: Int, meters: Double, isStreet: Bool)
        case ride(pattern: Int, trip: Int, boardPosition: Int, alightPosition: Int)
    }

    /// Pareto-optimal journeys leaving at or after `departure`: each uses more rides than the last only if it arrives sooner.
    public func journeys(from access: [StopAccess], to egress: [StopAccess], departure: Int) -> [Journey] {
        let stopCount = timetable.stops.count
        let unreached = Int.max
        var best = [Int](repeating: unreached, count: stopCount)
        var arrivals = [[Int](repeating: unreached, count: stopCount)]
        var parents = [[Parent](repeating: .none, count: stopCount)]
        /// Time still owed at each stop before a vehicle may be boarded there. Nothing in round 0: the walk in already allows for it.
        var slack = [[Int](repeating: 0, count: stopCount)]
        var marked: [Int] = []
        var isMarked = [Bool](repeating: false, count: stopCount)
        var targetBest = unreached

        func mark(_ stop: Int) {
            if !isMarked[stop] {
                isMarked[stop] = true
                marked.append(stop)
            }
        }

        /// Walks onward from the stops reached by vehicle (or by the initial access) in `round`.
        func relaxFootpaths(round: Int) {
            let sources = marked.map { ($0, arrivals[round][$0]) }
            for (stop, arrival) in sources {
                for path in timetable.footpaths[stop] {
                    let time = arrival + path.seconds
                    if time < min(best[path.to], targetBest) {
                        arrivals[round][path.to] = time
                        best[path.to] = time
                        parents[round][path.to] = .walk(from: stop, seconds: path.seconds, meters: path.meters, isStreet: path.isStreet)
                        slack[round][path.to] = round == 0 ? 0 : connectionSeconds(walking: path.seconds, isStreet: path.isStreet) - path.seconds
                        mark(path.to)
                    }
                }
            }
        }

        for (index, entry) in access.enumerated() {
            let time = departure + entry.seconds
            if time < arrivals[0][entry.stop] {
                arrivals[0][entry.stop] = time
                best[entry.stop] = time
                parents[0][entry.stop] = .access(index)
                mark(entry.stop)
            }
        }
        relaxFootpaths(round: 0)

        var queuedPosition = [Int](repeating: -1, count: timetable.patterns.count)
        for round in 1...maxRides {
            arrivals.append(arrivals[round - 1])
            parents.append([Parent](repeating: .none, count: stopCount))
            slack.append(slack[round - 1])

            // Patterns through any improved stop, scanned from the first such stop.
            var queue: [Int] = []
            for stop in marked {
                for (pattern, position) in timetable.patternsAtStop[stop] {
                    if queuedPosition[pattern] < 0 {
                        queue.append(pattern)
                        queuedPosition[pattern] = position
                    } else if position < queuedPosition[pattern] {
                        queuedPosition[pattern] = position
                    }
                }
                isMarked[stop] = false
            }
            marked.removeAll(keepingCapacity: true)

            for patternIndex in queue {
                let pattern = timetable.patterns[patternIndex]
                let start = queuedPosition[patternIndex]
                queuedPosition[patternIndex] = -1
                var trip: Int?
                var boardPosition = 0

                for position in start..<pattern.stops.count {
                    let stop = pattern.stops[position]
                    if let trip, pattern.canAlight[position] {
                        let arrival = pattern.arrival(trip: trip, position: position)
                        if arrival < min(best[stop], targetBest) {
                            arrivals[round][stop] = arrival
                            best[stop] = arrival
                            parents[round][stop] = .ride(pattern: patternIndex, trip: trip, boardPosition: boardPosition, alightPosition: position)
                            slack[round][stop] = changeSeconds
                            mark(stop)
                        }
                    }
                    // Could an earlier trip be caught here than the one we're riding?
                    let ready = arrivals[round - 1][stop]
                    guard ready != unreached, pattern.canBoard[position] else { continue }
                    let readyToBoard = ready + slack[round - 1][stop]
                    if trip.map({ readyToBoard <= pattern.departure(trip: $0, position: position) }) ?? true,
                       let earlier = pattern.earliestTrip(at: position, notBefore: readyToBoard, limit: trip ?? pattern.tripCount) {
                        trip = earlier
                        boardPosition = position
                    }
                }
            }

            relaxFootpaths(round: round)
            for entry in egress where arrivals[round][entry.stop] != unreached {
                targetBest = min(targetBest, arrivals[round][entry.stop] + entry.seconds)
            }
            if marked.isEmpty { break }
        }

        // One journey per round that improved on every round before it.
        var journeys: [Journey] = []
        var bestArrival = unreached
        for round in 1..<arrivals.count {
            let candidates = egress.filter { arrivals[round][$0.stop] != unreached }
            guard let exit = candidates.min(by: { arrivals[round][$0.stop] + $0.seconds < arrivals[round][$1.stop] + $1.seconds }) else { continue }
            let arrival = arrivals[round][exit.stop] + exit.seconds
            guard arrival < bestArrival else { continue }
            bestArrival = arrival
            if let journey = reconstruct(round: round, exit: exit, parents: parents, access: access) {
                journeys.append(departingLate(journey))
            }
        }
        return journeys
    }

    private func reconstruct(round: Int, exit: StopAccess, parents: [[Parent]], access: [StopAccess]) -> Journey? {
        var rides: [Journey.Ride] = []
        var pendingWalk = Journey.Walk()
        var walkAfter = Journey.Walk(seconds: exit.seconds, meters: exit.meters)
        var round = round
        var stop = exit.stop

        while true {
            // A label inherited from an earlier round has its parent recorded there.
            while round > 0, case .none = parents[round][stop] { round -= 1 }
            switch parents[round][stop] {
            case .none:
                return nil
            case .access(let index):
                pendingWalk.seconds += access[index].seconds
                pendingWalk.meters += access[index].meters
                guard !rides.isEmpty else { return nil }
                rides[0].walkBefore = pendingWalk
                return Journey(rides: rides, walkAfter: walkAfter)
            case .walk(let from, let seconds, let meters, let isStreet):
                if rides.isEmpty {
                    walkAfter.seconds += seconds
                    walkAfter.meters += meters
                } else {
                    pendingWalk.seconds += seconds
                    pendingWalk.meters += meters
                    pendingWalk.isStreet = pendingWalk.isStreet || isStreet
                }
                stop = from
            case .ride(let pattern, let trip, let boardPosition, let alightPosition):
                if !rides.isEmpty {
                    rides[0].walkBefore = pendingWalk
                }
                pendingWalk = Journey.Walk()
                rides.insert(Journey.Ride(pattern: pattern, trip: trip, boardPosition: boardPosition, alightPosition: alightPosition,
                                          walkBefore: Journey.Walk()), at: 0)
                stop = timetable.patterns[pattern].stops[boardPosition]
                round -= 1
            }
        }
    }

    /// RAPTOR boards the first possible vehicle, which can mean a long wait at a connection. Working
    /// backwards from the final ride, switch each earlier ride to the latest trip that still connects.
    private func departingLate(_ journey: Journey) -> Journey {
        var journey = journey
        guard journey.rides.count > 1 else { return journey }
        for index in stride(from: journey.rides.count - 2, through: 0, by: -1) {
            let next = journey.rides[index + 1]
            let nextBoard = timetable.patterns[next.pattern].departure(trip: next.trip, position: next.boardPosition)
            let deadline = nextBoard - connectionSeconds(walking: next.walkBefore.seconds, isStreet: next.walkBefore.isStreet)

            let ride = journey.rides[index]
            let pattern = timetable.patterns[ride.pattern]
            var trip = ride.trip
            while trip + 1 < pattern.tripCount, pattern.arrival(trip: trip + 1, position: ride.alightPosition) <= deadline {
                trip += 1
            }
            journey.rides[index].trip = trip
        }
        return journey
    }
}
