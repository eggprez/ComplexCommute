import CommuteCore
import MapKit
import SwiftUI

struct TripMapView: View {
    let planner: TripPlannerModel
    let sheetIsCollapsed: Bool

    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)

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
                            MapPolyline(coordinates: leg.option.geometry.map(\.clCoordinate))
                                .stroke(leg.mode.tint, style: strokeStyle(for: leg))
                        } else {
                            // The full path shows through as dotted walking wherever no ride covers it.
                            MapPolyline(coordinates: leg.option.geometry.map(\.clCoordinate))
                                .stroke(TravelMode.walk.tint, style: StrokeStyle(lineWidth: 5, lineCap: .round, dash: [1, 9]))
                            ForEach(Array(leg.option.rides.enumerated()), id: \.offset) { _, ride in
                                MapPolyline(coordinates: ride.path.map(\.clCoordinate))
                                    .stroke(Color(hex: ride.routeColorHex) ?? leg.mode.tint, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                            }
                        }
                    }
                }
            }
            .mapControls {
                MapUserLocationButton()
                MapCompass()
            }
            // Keep fitted content clear of the sheet.
            .safeAreaPadding(.bottom, sheetIsCollapsed ? 88 : proxy.size.height * 0.45)
            .onChange(of: planner.displayedItinerary?.id) { fitTrip() }
            .onChange(of: planner.template.waypoints) { fitTrip() }
        }
        .ignoresSafeArea(.keyboard)
    }

    private func strokeStyle(for leg: Leg) -> StrokeStyle {
        switch leg.mode {
        case .drive:
            StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)
        case .walk:
            StrokeStyle(lineWidth: 5, lineCap: .round, dash: [1, 9])
        case .transit:
            StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round, dash: leg.option.isEstimate ? [10, 10] : [])
        }
    }

    private func fitTrip() {
        let fixed = planner.template.waypoints.filter { $0.kind != .currentLocation }.map(\.coordinate)
        let route = planner.displayedItinerary?.legs.flatMap(\.option.geometry) ?? []
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
