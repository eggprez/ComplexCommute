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

/// A line's bullet as riders know it from signs: a disc for a subway letter or number, a lozenge for anything longer.
struct RouteBadgeView: View {
    enum Size {
        case small, regular, large

        var height: CGFloat {
            switch self {
            case .small: 18
            case .regular: 22
            case .large: 30
            }
        }

        var font: Font {
            switch self {
            case .small: .caption2.weight(.bold)
            case .regular: .caption.weight(.bold)
            case .large: .callout.weight(.bold)
            }
        }
    }

    let route: RouteBadge
    var size = Size.small

    var body: some View {
        let fill = Color(hex: route.colorHex) ?? Color(.systemGray3)
        Text(route.name)
            .font(size.font)
            .lineLimit(1)
            .foregroundStyle(Color(hex: route.textColorHex) ?? Color.readable(on: route.colorHex) ?? Color.primary)
            .padding(.horizontal, route.name.count <= 2 ? 0 : size.height * 0.3)
            .frame(minWidth: size.height, minHeight: size.height)
            .background(fill, in: .rect(cornerRadius: route.name.count <= 2 ? size.height / 2 : size.height * 0.28))
            .accessibilityLabel("\(route.name) line")
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
        // Single-line systems name their route after themselves ("PATH · PATH").
        let lines = routes.prefix(6).map(\.name).filter { $0 != agency }.joined(separator: " ")
        let subtitle = [agency, lines.isEmpty ? nil : lines].compactMap { $0 }.joined(separator: " · ")
        return Waypoint(name: name, subtitle: subtitle, coordinate: coordinate, kind: .stop(feedID: feedID, stopID: stopID))
    }
}
