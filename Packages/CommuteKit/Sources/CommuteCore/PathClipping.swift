import Foundation

/// A position along a path: part-way through one of its segments.
private struct PathMatch {
    var segment: Int
    var fraction: Double
}

extension Array where Element == Coordinate {
    /// A point further along the path than this, once a stop has been found, belongs to the path's next pass.
    private static var leavingMeters: Double { 150 }

    /// The stretch of this path (a whole route's shape, in travel order) that runs from the first of `stops` to the
    /// last. The stops between are followed in order so a route that loops back on itself is cut at the right pass.
    /// Nil when the path doesn't go by the first or last stop, in which case straight lines are the honest drawing.
    public func clipped(passing stops: [Coordinate]) -> [Coordinate]? {
        guard count > 1, stops.count > 1, let origin = first, let firstStop = stops.first, let lastStop = stops.last else { return nil }

        // Flat-earth meters around the path's start; a transit line is far too short for curvature to matter.
        let metersPerLatitude = 111_320.0
        let metersPerLongitude = metersPerLatitude * cos(origin.latitude * .pi / 180)
        func point(_ coordinate: Coordinate) -> (x: Double, y: Double) {
            ((coordinate.longitude - origin.longitude) * metersPerLongitude, (coordinate.latitude - origin.latitude) * metersPerLatitude)
        }
        let points = map(point)

        /// The first place at or after `start` where the path comes within `tolerance` of `stop`.
        func match(_ stop: Coordinate, after start: PathMatch, within tolerance: Double) -> PathMatch? {
            let target = point(stop)
            var best: (match: PathMatch, distance: Double)?
            for segment in start.segment..<(points.count - 1) {
                let (a, b) = (points[segment], points[segment + 1])
                let (dx, dy) = (b.x - a.x, b.y - a.y)
                let lengthSquared = dx * dx + dy * dy
                var fraction = lengthSquared == 0 ? 0 : Swift.max(0, Swift.min(1, ((target.x - a.x) * dx + (target.y - a.y) * dy) / lengthSquared))
                if segment == start.segment { fraction = Swift.max(fraction, start.fraction) }
                let distance = hypot(a.x + fraction * dx - target.x, a.y + fraction * dy - target.y)
                if let best, best.distance <= tolerance, distance > best.distance + Self.leavingMeters { break }
                if best.map({ distance < $0.distance }) ?? true {
                    best = (PathMatch(segment: segment, fraction: fraction), distance)
                }
            }
            guard let best, best.distance <= tolerance else { return nil }
            return best.match
        }
        /// Platforms sit on the line; station centroids of big terminals can be a couple of blocks off it.
        func locate(_ stop: Coordinate, after start: PathMatch) -> PathMatch? {
            match(stop, after: start, within: 60) ?? match(stop, after: start, within: 300)
        }

        guard let board = locate(firstStop, after: PathMatch(segment: 0, fraction: 0)) else { return nil }
        var cursor = board
        for stop in stops.dropFirst().dropLast() {
            cursor = locate(stop, after: cursor) ?? cursor
        }
        guard let alight = locate(lastStop, after: cursor) ?? locate(lastStop, after: board) else { return nil }

        func coordinate(at match: PathMatch) -> Coordinate {
            let (a, b) = (self[match.segment], self[match.segment + 1])
            return Coordinate(latitude: a.latitude + (b.latitude - a.latitude) * match.fraction,
                              longitude: a.longitude + (b.longitude - a.longitude) * match.fraction)
        }
        let between = alight.segment > board.segment ? Array(self[(board.segment + 1)...alight.segment]) : []
        // A stop sitting exactly on a vertex would otherwise appear twice.
        return ([coordinate(at: board)] + between + [coordinate(at: alight)]).reduce(into: []) { path, next in
            if path.last != next { path.append(next) }
        }
    }

    /// Douglas–Peucker: drops points that lie within `toleranceMeters` of the line through their neighbours.
    public func simplified(toleranceMeters: Double) -> [Coordinate] {
        guard count > 2, let origin = first else { return self }
        let metersPerLatitude = 111_320.0
        let metersPerLongitude = metersPerLatitude * cos(origin.latitude * .pi / 180)
        let points = map { (x: ($0.longitude - origin.longitude) * metersPerLongitude, y: ($0.latitude - origin.latitude) * metersPerLatitude) }

        var keep = [Bool](repeating: false, count: count)
        keep[0] = true
        keep[count - 1] = true
        var ranges = [(0, count - 1)]
        while let (start, end) = ranges.popLast() {
            guard end > start + 1 else { continue }
            let (a, b) = (points[start], points[end])
            let (dx, dy) = (b.x - a.x, b.y - a.y)
            let length = hypot(dx, dy)
            var farthest = (index: start, distance: 0.0)
            for index in (start + 1)..<end {
                let p = points[index]
                let distance = length == 0 ? hypot(p.x - a.x, p.y - a.y) : abs(dy * (p.x - a.x) - dx * (p.y - a.y)) / length
                if distance > farthest.distance { farthest = (index, distance) }
            }
            if farthest.distance > toleranceMeters {
                keep[farthest.index] = true
                ranges.append((start, farthest.index))
                ranges.append((farthest.index, end))
            }
        }
        return indices.filter { keep[$0] }.map { self[$0] }
    }
}
