import CommuteCore
import GTFSKit
import SwiftUI

struct TransitStopRow: View {
    let stop: TransitStop
    var distanceMeters: Double?

    var body: some View {
        Label {
            Text(stop.name)
            // As many bullets as fit whole: a squeezed one reads as "…".
            ViewThatFits(in: .horizontal) {
                ForEach([Self.maxBadges, 7, 5, 4, 3, 2, 1], id: \.self) { count in
                    details(badges: count)
                }
            }
        } icon: {
            IconTile(systemName: stop.symbol, color: TravelMode.transit.tint, isRound: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(stop.name), \(stop.routes.map(\.name).joined(separator: ", "))")
    }

    private func details(badges count: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(stop.routes.prefix(count), id: \.self) { route in
                RouteBadgeView(route: route)
                    .fixedSize()
            }
            if stop.routes.count > count {
                Text("+\(stop.routes.count - count)")
                    .font(.caption2)
                    .fixedSize()
            }
            if let distanceMeters {
                Text(Measurement(value: distanceMeters, unit: UnitLength.meters), format: .measurement(width: .abbreviated, usage: .road))
                    .font(.footnote)
                    .fixedSize()
            }
        }
    }

    private static let maxBadges = 9
}

extension TransitStop {
    var symbol: String {
        let types = Set(routes.map(\.type))
        if types == [3] { return "bus.fill" }
        if types.isSubset(of: [2]) { return "train.side.front.car" }
        return "tram.fill"
    }

    var waypoint: Waypoint {
        let agency = FeedCatalog.feed(id: feedID)?.name
        // Single-line systems name their route after themselves ("PATH · PATH").
        let lines = routes.prefix(6).map(\.name).filter { $0 != agency }.joined(separator: " ")
        let subtitle = [agency, lines.isEmpty ? nil : lines].compactMap { $0 }.joined(separator: " · ")
        return Waypoint(name: name, subtitle: subtitle, coordinate: coordinate, kind: .stop(feedID: feedID, stopID: stopID))
    }
}
