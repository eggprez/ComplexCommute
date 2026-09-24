import CommuteCore
import CoreLocation
import MapKit

/// Resolves drive and walk legs from MapKit directions. MapKit exposes no transit steps, only an ETA,
/// so transit legs are a coarse estimate until the GTFS router replaces them.
nonisolated struct MapKitLegResolver: LegResolving {
    private let cache: RouteCache

    @MainActor
    init() {
        cache = RouteCache()
    }

    /// MapKit's transit estimate can't be told which services to leave out.
    @MainActor
    func options(from: Waypoint, to: Waypoint, mode: TravelMode, departingAt: Date, isWaitingAtOrigin: Bool = false,
                 excludedFeedIDs: Set<String> = []) async throws -> [LegOption] {
        if let cached = cache.option(from: from.coordinate, to: to.coordinate, mode: mode, departingAt: departingAt) {
            return [cached]
        }

        let request = MKDirections.Request()
        request.source = MKMapItem(location: from.coordinate.location, address: nil)
        request.destination = MKMapItem(location: to.coordinate.location, address: nil)
        request.departureDate = departingAt

        let option: LegOption
        switch mode {
        case .drive, .walk:
            request.transportType = mode == .drive ? .automobile : .walking
            guard let route = try await MKDirections(request: request).calculate().routes.first else { return [] }
            option = LegOption(
                mode: mode,
                departure: departingAt,
                arrival: departingAt.addingTimeInterval(route.expectedTravelTime),
                distanceMeters: route.distance,
                walkingMeters: mode == .walk ? route.distance : 0,
                geometry: route.polyline.coordinates,
                summary: route.name.isEmpty ? nil : route.name
            )
        case .transit:
            request.transportType = .transit
            let eta = try await MKDirections(request: request).calculateETA()
            option = LegOption(
                mode: .transit,
                departure: max(departingAt, eta.expectedDepartureDate),
                arrival: eta.expectedArrivalDate,
                distanceMeters: eta.distance,
                geometry: [from.coordinate, to.coordinate],
                isEstimate: true
            )
        }
        cache.store(option, from: from.coordinate, to: to.coordinate, departingAt: departingAt)
        return [option]
    }
}

/// MapKit throttles directions requests, and live re-planning asks for the same legs repeatedly.
/// Walking time doesn't depend on when you leave; driving is reused briefly, then refreshed for traffic.
/// Setting the request's departure date is what gets MapKit to price in traffic, live or predicted, so a
/// drive is only reused for departures in the same quarter hour: an arrive-by plan made the night before
/// has to ask about rush hour, not borrow tonight's empty roads.
@MainActor
private final class RouteCache {
    private struct Key: Hashable {
        var from: Coordinate
        var to: Coordinate
        var mode: TravelMode
        /// Which quarter hour a drive sets out in; nil for walks.
        var slot: Int?
    }

    private struct Entry {
        var option: LegOption
        var storedAt: Date
    }

    private var entries: [Key: Entry] = [:]

    func option(from: Coordinate, to: Coordinate, mode: TravelMode, departingAt: Date) -> LegOption? {
        guard let lifetime = lifetime(for: mode),
              let entry = entries[key(from: from, to: to, mode: mode, departingAt: departingAt)],
              Date.now.timeIntervalSince(entry.storedAt) < lifetime else { return nil }
        var option = entry.option
        option.arrival = departingAt.addingTimeInterval(option.duration)
        option.departure = departingAt
        return option
    }

    func store(_ option: LegOption, from: Coordinate, to: Coordinate, departingAt: Date) {
        guard lifetime(for: option.mode) != nil else { return }
        entries[key(from: from, to: to, mode: option.mode, departingAt: departingAt)] = Entry(option: option, storedAt: .now)
    }

    private func key(from: Coordinate, to: Coordinate, mode: TravelMode, departingAt: Date) -> Key {
        Key(from: from.rounded, to: to.rounded, mode: mode,
            slot: mode == .drive ? Int(departingAt.timeIntervalSince1970 / Self.trafficSlot) : nil)
    }

    private static let trafficSlot: TimeInterval = 15 * 60

    private func lifetime(for mode: TravelMode) -> TimeInterval? {
        switch mode {
        case .walk: 3600
        case .drive: 90
        case .transit: nil
        }
    }
}

extension Coordinate {
    nonisolated var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
    nonisolated var clCoordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }

    nonisolated init(_ coordinate: CLLocationCoordinate2D) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    /// ~11 m grid, so GPS jitter doesn't defeat the route cache.
    fileprivate nonisolated var rounded: Coordinate {
        Coordinate(latitude: (latitude * 10_000).rounded() / 10_000, longitude: (longitude * 10_000).rounded() / 10_000)
    }
}

private extension MKPolyline {
    var coordinates: [Coordinate] {
        var buffer = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: pointCount)
        getCoordinates(&buffer, range: NSRange(location: 0, length: pointCount))
        return buffer.map(Coordinate.init)
    }
}
