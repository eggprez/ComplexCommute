import CommuteCore
import GTFSKit
import SwiftUI

struct TransitStopRow: View {
    let stop: TransitStop
    var distanceMeters: Double?

    var body: some View {
        Label {
            Text(stop.name)
            HStack(spacing: 4) {
                ForEach(stop.routes.prefix(Self.maxBadges), id: \.self) { route in
                    RouteBadgeView(route: route)
                }
                if stop.routes.count > Self.maxBadges {
                    Text("+\(stop.routes.count - Self.maxBadges)")
                        .font(.caption2)
                }
                if let distanceMeters {
                    Text(Measurement(value: distanceMeters, unit: UnitLength.meters), format: .measurement(width: .abbreviated, usage: .road))
                        .font(.footnote)
                }
            }
        } icon: {
            Image(systemName: stop.symbol)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(stop.name), \(stop.routes.map(\.name).joined(separator: ", "))")
    }

    private static let maxBadges = 9
}

struct RouteBadgeView: View {
    let route: RouteBadge

    var body: some View {
        let fill = Color(hex: route.colorHex) ?? Color(.systemGray3)
        Text(route.name)
            .font(.caption2.weight(.bold))
            .lineLimit(1)
            .foregroundStyle(Color(hex: route.textColorHex) ?? (route.colorHex == nil ? Color.primary : Color.white))
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(fill, in: .capsule)
    }
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
        let lines = routes.prefix(6).map(\.name).joined(separator: " ")
        let subtitle = [agency, lines.isEmpty ? nil : lines].compactMap { $0 }.joined(separator: " · ")
        return Waypoint(name: name, subtitle: subtitle, coordinate: coordinate, kind: .stop(feedID: feedID, stopID: stopID))
    }
}

extension Color {
    /// "RRGGBB" as published in GTFS; nil for missing or malformed values.
    init?(hex: String?) {
        guard let hex, hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}
