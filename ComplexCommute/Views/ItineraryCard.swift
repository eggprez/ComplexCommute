import CommuteCore
import GTFSKit
import MapKit
import SwiftUI

/// One trip option. The selected card expands to show its legs.
struct ItineraryCard: View {
    let itinerary: Itinerary
    let tags: Set<ItineraryTag>
    let isSelected: Bool
    let isLeavingNow: Bool
    let onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onSelect) {
                summary
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            if isSelected {
                Divider()
                ForEach(Array(itinerary.legs.enumerated()), id: \.element.id) { index, leg in
                    let wait = itinerary.wait(before: index)
                    if wait >= 60 {
                        Label("Wait \(wait.shortDuration)", systemImage: "clock")
                            .font(.footnote)
                            .foregroundStyle(Color.secondary)
                    }
                    LegRow(leg: leg)
                }
            }
        }
        .buttonStyle(.borderless)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.12) : nil)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(headline)
                    .font(.headline)
                    .foregroundStyle(Color.primary)
                Spacer()
                Text("\(itinerary.hasEstimates ? "~" : "")\(itinerary.duration.shortDuration)")
                    .font(.headline)
                    .foregroundStyle(Color.primary)
            }

            Text("\(itinerary.departure, format: .dateTime.hour().minute()) – \(itinerary.arrival, format: .dateTime.hour().minute())")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)

            HStack(spacing: 6) {
                ForEach(Array(itinerary.legs.enumerated()), id: \.element.id) { index, leg in
                    if index > 0 {
                        Image(systemName: "chevron.compact.right")
                            .foregroundStyle(Color.secondary.opacity(0.6))
                    }
                    if leg.option.rides.isEmpty {
                        Label(leg.duration.shortDuration, systemImage: leg.mode.symbol)
                            .labelStyle(.titleAndIcon)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(leg.mode.tint)
                    } else {
                        ForEach(Array(leg.option.rides.enumerated()), id: \.offset) { _, ride in
                            RouteBadgeView(route: ride.badge)
                        }
                    }
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)

            if !tags.isEmpty {
                Text(ItineraryTag.allCases.filter(tags.contains).map(\.label).joined(separator: " · "))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            }
        }
    }

    private var headline: String {
        guard isLeavingNow else {
            return "Arrive \(itinerary.arrival.formatted(date: .omitted, time: .shortened))"
        }
        let lead = itinerary.departure.timeIntervalSinceNow
        return lead < 60 ? "Leave now" : "Leave in \(lead.shortDuration)"
    }
}

private struct LegRow: View {
    let leg: Leg

    var body: some View {
        HStack(alignment: .top) {
            Label {
                Text("\(leg.mode.label) to \(leg.to.name)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.primary)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
            } icon: {
                Image(systemName: leg.mode.symbol)
                    .foregroundStyle(leg.mode.tint)
            }

            Spacer()

            if leg.option.rides.isEmpty {
                openInMapsButton
            }
        }
        ForEach(Array(leg.option.rides.enumerated()), id: \.offset) { _, ride in
            WalkStepRow(seconds: ride.walkBefore, destination: ride.boardStopName)
            RideRow(ride: ride)
        }
        if !leg.option.rides.isEmpty {
            WalkStepRow(seconds: leg.option.walkAfter, destination: leg.to.name)
        }
    }

    private var openInMapsButton: some View {
        Button("Open in Maps", systemImage: "arrow.triangle.turn.up.right.circle") {
            openInMaps()
        }
        .labelStyle(.iconOnly)
        .font(.title3)
    }

    private var detail: String {
        var parts = ["\(leg.departure.formatted(date: .omitted, time: .shortened)) – \(leg.arrival.formatted(date: .omitted, time: .shortened))"]
        if let meters = leg.option.distanceMeters {
            parts.append(Measurement(value: meters, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road)))
        }
        if let summary = leg.option.summary {
            parts.append("via \(summary)")
        }
        if leg.option.isEstimate {
            parts.append("estimate")
        }
        if leg.option.walkingMeters > 0, leg.mode == .transit {
            let walk = Measurement(value: leg.option.walkingMeters, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road))
            parts.append("\(walk) walking")
        }
        return parts.joined(separator: " · ")
    }

    private func openInMaps() {
        let source = MKMapItem(location: leg.from.coordinate.location, address: nil)
        source.name = leg.from.name
        let destination = MKMapItem(location: leg.to.coordinate.location, address: nil)
        destination.name = leg.to.name
        let mode = switch leg.mode {
        case .drive: MKLaunchOptionsDirectionsModeDriving
        case .walk: MKLaunchOptionsDirectionsModeWalking
        case .transit: MKLaunchOptionsDirectionsModeTransit
        }
        MKMapItem.openMaps(with: [source, destination], launchOptions: [MKLaunchOptionsDirectionsModeKey: mode])
    }
}

/// A walk inside a transit leg: to the first station, between stations, or from the last one.
private struct WalkStepRow: View {
    let seconds: TimeInterval
    let destination: String

    var body: some View {
        if seconds >= 60 {
            HStack(spacing: 8) {
                Image(systemName: "figure.walk")
                    .frame(width: 44, alignment: .trailing)
                Text("Walk \(seconds.shortDuration) to \(destination)")
            }
            .font(.footnote)
            .foregroundStyle(Color.secondary)
        }
    }
}

private struct RideRow: View {
    let ride: Ride

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            RouteBadgeView(route: ride.badge)
                .frame(width: 44, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                if let headsign = ride.headsign {
                    Text("toward \(headsign)")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Color.primary)
                }
                Text("\(ride.board, format: .dateTime.hour().minute())  \(ride.boardStopName)")
                Text("\(ride.alight, format: .dateTime.hour().minute())  \(ride.alightStopName) · \(ride.stopCount) \(ride.stopCount == 1 ? "stop" : "stops")")
            }
            .font(.footnote)
            .foregroundStyle(Color.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

extension Ride {
    var badge: RouteBadge {
        RouteBadge(name: routeName, colorHex: routeColorHex, textColorHex: routeTextColorHex, type: routeType)
    }
}
