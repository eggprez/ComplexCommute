import CommuteCore
import GTFSKit
import MapKit
import SwiftUI

struct TripMapView: View {
    let planner: TripPlannerModel
    let sheetIsCollapsed: Bool
    let router: SheetRouter

    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    /// Last direction of travel, kept while stopped, when GPS reports no course.
    @State private var heading = 0.0

    var body: some View {
        GeometryReader { proxy in
            Map(position: $position) {
                UserAnnotation()

                let waypoints = planner.template.waypoints
                ForEach(waypoints.filter { $0.kind != .currentLocation }) { waypoint in
                    Marker(waypoint.name, systemImage: waypoint.symbol, coordinate: waypoint.coordinate.clCoordinate)
                        .tint(waypoint.id == waypoints.last?.id ? Color.red : Color.gray)
                }

                if let itinerary = planner.displayedItinerary {
                    ForEach(itinerary.legs) { leg in
                        if leg.option.rides.isEmpty {
                            if leg.mode != .walk {
                                MapPolyline(coordinates: leg.option.geometry.map(\.clCoordinate))
                                    .stroke(Self.casing(for: leg.mode.tint), style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
                            }
                            MapPolyline(coordinates: leg.option.geometry.map(\.clCoordinate))
                                .stroke(leg.mode.tint, style: strokeStyle(for: leg))
                        } else {
                            ForEach(Array(Self.walks(in: leg).enumerated()), id: \.offset) { _, walk in
                                MapPolyline(coordinates: walk.map(\.clCoordinate))
                                    .stroke(TravelMode.walk.tint, style: StrokeStyle(lineWidth: 5, lineCap: .round, dash: [1, 9]))
                            }
                            // Each ride follows the line's own tracks or streets, in the line's own color.
                            ForEach(Array(leg.option.rides.enumerated()), id: \.offset) { _, ride in
                                MapPolyline(coordinates: ride.path.map(\.clCoordinate))
                                    .stroke(.white, style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
                                MapPolyline(coordinates: ride.path.map(\.clCoordinate))
                                    .stroke(Color(hex: ride.routeColorHex) ?? leg.mode.tint, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                            }
                            ForEach(Self.stationMarks(for: leg)) { mark in
                                Annotation(mark.title, coordinate: mark.station.coordinate.clCoordinate, anchor: .center) {
                                    Button {
                                        router.station = mark.station
                                    } label: {
                                        StationMarkView(mark: mark)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(mark.accessibilityLabel)
                                }
                            }
                        }
                    }
                }
            }
            // On the road the map is for the road: traffic on, shops and sights off.
            .mapStyle(planner.isNavigating && planner.guidedLeg?.mode == .drive
                      ? .standard(elevation: .flat, pointsOfInterest: .excludingAll, showsTraffic: true) : .standard)
            .mapControls {
                MapUserLocationButton()
                MapCompass()
            }
            // Keep fitted content clear of the sheet.
            .safeAreaPadding(.bottom, sheetIsCollapsed ? 88 : proxy.size.height * 0.45)
            .safeAreaInset(edge: .top) {
                if let leg = planner.guidedLeg, let progress = planner.guidance, planner.isNavigating {
                    GuidanceBanner(leg: leg, progress: progress, voice: planner.voice)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: planner.isNavigating)
            .onChange(of: planner.displayedItinerary?.id) { fitTrip() }
            .onChange(of: planner.isNavigating) { fitTrip() }
            .onChange(of: planner.location.location) { followTraveller() }
            .onChange(of: planner.template.waypoints) { fitTrip() }
        }
        .ignoresSafeArea(.keyboard)
    }

    private func strokeStyle(for leg: Leg) -> StrokeStyle {
        switch leg.mode {
        case .drive:
            StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round)
        case .walk:
            StrokeStyle(lineWidth: 5, lineCap: .round, dash: [1, 9])
        case .transit:
            StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round, dash: leg.option.isEstimate ? [10, 10] : [])
        }
    }

    /// Navigating a drive or walk: stay on the traveller, looking the way they are heading, until they pan away.
    /// (The location button brings the camera back.) Placed by hand because the built-in follow mode ignores the sheet.
    private func followTraveller(force: Bool = false) {
        guard planner.isNavigating, force || !position.positionedByUser, let location = planner.location.location else { return }
        if location.course >= 0, location.speed > 0.5 {
            heading = location.course
        }
        let isDriving = planner.guidedLeg?.mode == .drive
        // Tilted enough to see the road ahead, but not so far that buildings stand in front of the route line.
        let camera = MapCamera(centerCoordinate: location.coordinate, distance: isDriving ? 900 : 450, heading: heading, pitch: 30)
        withAnimation(.linear(duration: 1)) { position = .camera(camera) }
    }

    private func fitTrip() {
        guard !planner.isNavigating else {
            followTraveller(force: true)
            return
        }
        let fixed = planner.template.waypoints.filter { $0.kind != .currentLocation }.map(\.coordinate)
        let route = planner.displayedItinerary?.legs.flatMap { $0.option.geometry + $0.option.rides.flatMap(\.path) } ?? []
        let coordinates = fixed + route
        guard !coordinates.isEmpty else {
            withAnimation { position = .userLocation(fallback: .automatic) }
            return
        }

        let rect = coordinates.reduce(MKMapRect.null) { rect, coordinate in
            rect.union(MKMapRect(origin: MKMapPoint(coordinate.clCoordinate), size: MKMapSize(width: 0, height: 0)))
        }
        let padded = rect.insetBy(dx: -max(rect.width * 0.2, 1500), dy: -max(rect.height * 0.2, 1500))
        withAnimation { position = .rect(padded) }
    }
}

/// A stop worth calling out on the map: where a ride is boarded, passed through, changed or left.
struct StationMark: Identifiable {
    enum Role {
        case board
        case transfer
        case pass
        case exit
    }

    let id: String
    let station: StationRef
    let role: Role
    /// Lines involved: the one boarded, preceded by the one left when changing here.
    let badges: [RouteBadge]
    let colorHex: String?

    var title: String { role == .pass ? "" : station.name }

    var accessibilityLabel: String {
        let lines = badges.map(\.name).joined(separator: " to ")
        return switch role {
        case .board: "Board \(lines) at \(station.name)"
        case .transfer: "Transfer \(lines) at \(station.name)"
        case .pass: station.name
        case .exit: "Exit at \(station.name)"
        }
    }
}

extension TripMapView {
    /// Changing within a couple of blocks (platforms of one complex are often that far apart) reads as one
    /// transfer point rather than an exit and a separate boarding.
    static let sameStationMeters = 250.0

    /// The darker edge Maps gives a route line so it reads over any terrain.
    static func casing(for color: Color) -> Color {
        color.mix(with: .black, by: 0.35)
    }

    /// The stretches of a transit leg covered on foot: to the first platform, between rides, and from the last one.
    static func walks(in leg: Leg) -> [[Coordinate]] {
        let rides = leg.option.rides
        var ends = [leg.from.coordinate]
        var walks: [[Coordinate]] = []
        for ride in rides {
            guard let start = ride.path.first, let end = ride.path.last else { continue }
            walks.append([ends[ends.count - 1], start])
            ends.append(end)
        }
        walks.append([ends[ends.count - 1], leg.to.coordinate])
        return walks.filter { $0[0].distance(to: $0[1]) > 15 }
    }

    static func stationMarks(for leg: Leg) -> [StationMark] {
        let rides = leg.option.rides
        var marks: [StationMark] = []
        for (index, ride) in rides.enumerated() {
            guard let board = ride.stops.first?.station, let exit = ride.stops.last?.station else { continue }
            let previous = index > 0 ? rides[index - 1] : nil
            let changesHere = previous?.stops.last.map { $0.station.coordinate.distance(to: board.coordinate) <= sameStationMeters } ?? false
            let key = "\(leg.segmentIndex).\(index)"

            marks.append(StationMark(id: "\(key).board", station: board, role: changesHere ? .transfer : .board,
                                     badges: (changesHere ? [previous?.badge].compactMap { $0 } : []) + [ride.badge], colorHex: ride.routeColorHex))
            for (offset, stop) in ride.intermediateStops.enumerated() {
                marks.append(StationMark(id: "\(key).pass\(offset)", station: stop.station, role: .pass, badges: [], colorHex: ride.routeColorHex))
            }
            let next = index + 1 < rides.count ? rides[index + 1].stops.first?.station : nil
            if next.map({ $0.coordinate.distance(to: exit.coordinate) > sameStationMeters }) ?? true {
                marks.append(StationMark(id: "\(key).exit", station: exit, role: .exit, badges: [], colorHex: ride.routeColorHex))
            }
        }
        return marks
    }
}

private struct StationMarkView: View {
    let mark: StationMark

    var body: some View {
        let color = Color(hex: mark.colorHex) ?? TravelMode.transit.tint
        switch mark.role {
        case .board, .transfer:
            HStack(spacing: 2) {
                ForEach(Array(mark.badges.enumerated()), id: \.offset) { index, badge in
                    if index > 0 {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(Color.secondary)
                    }
                    RouteBadgeView(route: badge, size: .regular)
                }
            }
            .padding(3)
            .background(.background, in: .capsule)
            .shadow(radius: 1.5)
        case .pass:
            Circle()
                .fill(.white)
                .stroke(color, lineWidth: 2.5)
                .frame(width: 10, height: 10)
                .frame(width: 28, height: 28)
                .contentShape(.circle)
        case .exit:
            Circle()
                .fill(.white)
                .stroke(color, lineWidth: 4)
                .frame(width: 16, height: 16)
                .shadow(radius: 1.5)
        }
    }
}
