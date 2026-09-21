import Foundation

/// One maneuver of a drive or walk leg. `geometry` is the stretch travelled before the maneuver,
/// so the instruction happens at its last coordinate.
public struct RouteStep: Codable, Hashable, Sendable {
    public var instruction: String
    public var distanceMeters: Double
    public var geometry: [Coordinate]

    public init(instruction: String, distanceMeters: Double, geometry: [Coordinate]) {
        self.instruction = instruction
        self.distanceMeters = distanceMeters
        self.geometry = geometry
    }
}

/// Where a position falls along a leg's steps. Stateless, so it survives the route being re-planned underfoot.
public struct RouteProgress: Hashable, Sendable {
    /// The step whose maneuver comes next.
    public let stepIndex: Int
    public let metersToManeuver: Double
    /// Distance left on the whole leg.
    public let metersRemaining: Double
    /// How far the position is from the nearest part of the route.
    public let metersOffRoute: Double

    /// Past this close to a maneuver, it counts as done and the following one comes up.
    static let completionMeters = 15.0

    public init?(steps: [RouteStep], location: Coordinate) {
        var nearest: (index: Int, offRoute: Double, toEnd: Double)?
        for (index, step) in steps.enumerated() {
            guard let projection = Self.project(location, onto: step.geometry) else { continue }
            if nearest.map({ projection.distance < $0.offRoute }) ?? true {
                nearest = (index, projection.distance, projection.metersToEnd)
            }
        }
        guard var nearest else { return nil }

        while nearest.toEnd < Self.completionMeters, nearest.index + 1 < steps.count {
            nearest.index += 1
            nearest.toEnd += steps[nearest.index].distanceMeters
        }
        stepIndex = nearest.index
        metersToManeuver = nearest.toEnd
        metersOffRoute = nearest.offRoute
        metersRemaining = nearest.toEnd + steps[(nearest.index + 1)...].reduce(0) { $0 + $1.distanceMeters }
    }

    /// Closest point on a path, as its distance from `location` and the path length left after it.
    private static func project(_ location: Coordinate, onto path: [Coordinate]) -> (distance: Double, metersToEnd: Double)? {
        guard let first = path.first else { return nil }
        guard path.count > 1 else { return (location.distance(to: first), 0) }

        // Flat-earth meters around the position; steps are far too short for curvature to matter.
        let metersPerLatitude = 111_320.0
        let metersPerLongitude = metersPerLatitude * cos(location.latitude * .pi / 180)
        let points = path.map { (x: ($0.longitude - location.longitude) * metersPerLongitude, y: ($0.latitude - location.latitude) * metersPerLatitude) }

        var lengthAfter = [Double](repeating: 0, count: points.count)
        for index in stride(from: points.count - 2, through: 0, by: -1) {
            lengthAfter[index] = lengthAfter[index + 1] + hypot(points[index + 1].x - points[index].x, points[index + 1].y - points[index].y)
        }

        var best: (distance: Double, metersToEnd: Double)?
        for index in 0..<(points.count - 1) {
            let (a, b) = (points[index], points[index + 1])
            let (dx, dy) = (b.x - a.x, b.y - a.y)
            let lengthSquared = dx * dx + dy * dy
            let t = lengthSquared == 0 ? 0 : max(0, min(1, -(a.x * dx + a.y * dy) / lengthSquared))
            let distance = hypot(a.x + t * dx, a.y + t * dy)
            if best.map({ distance < $0.distance }) ?? true {
                best = (distance, (1 - t) * lengthSquared.squareRoot() + lengthAfter[index + 1])
            }
        }
        return best
    }
}
