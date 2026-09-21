import CommuteCore
import GTFSKit
import SwiftUI
import TransitRouting

/// What leaves a station next, live where the agency publishes predictions.
struct StationBoardView: View {
    let station: StationRef

    @Environment(\.transitPlanner) private var transit
    @State private var departures: [StopDeparture]?
    @State private var lastUpdated: Date?
    @State private var routeFilter: String?

    static let refreshInterval: Duration = .seconds(30)
    /// A rider wants the next train and a fallback or two, not the afternoon's timetable.
    static let departuresPerDestination = 3

    var body: some View {
        List {
            if let departures {
                let routes = departures.map(\.route).reduce(into: [RouteBadge]()) { routes, route in
                    if !routes.contains(where: { $0.name == route.name }) { routes.append(route) }
                }
                if routes.count > 1 {
                    Section {
                        routePicker(routes)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }
                Section {
                    // Re-render on a clock so countdowns stay honest between refreshes.
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        let upcoming = departures.filter { $0.time > context.date.addingTimeInterval(-30) && (routeFilter == nil || $0.route.name == routeFilter) }
                        ForEach(DepartureGroup.groups(upcoming, limit: Self.departuresPerDestination)) { group in
                            DepartureGroupRow(group: group, now: context.date)
                        }
                    }
                } footer: {
                    if let lastUpdated {
                        Text("Updated \(lastUpdated, format: .dateTime.hour().minute()). Green times are live predictions; the rest are scheduled.")
                    }
                }
            }
        }
        .overlay {
            if let departures {
                if departures.isEmpty {
                    ContentUnavailableView("No Upcoming Departures", systemImage: "clock.badge.xmark",
                                           description: Text("Nothing is scheduled to leave here in the next two hours."))
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(station.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            while !Task.isCancelled {
                let found = await transit?.departures(from: station) ?? []
                guard !Task.isCancelled else { return }
                departures = found
                lastUpdated = .now
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    private func routePicker(_ routes: [RouteBadge]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                Button("All") { routeFilter = nil }
                    .buttonStyle(.bordered)
                    .tint(routeFilter == nil ? Color.accentColor : Color.secondary)
                ForEach(routes, id: \.name) { route in
                    Button {
                        routeFilter = routeFilter == route.name ? nil : route.name
                    } label: {
                        RouteBadgeView(route: route, size: .large)
                            .padding(2)
                            .opacity(routeFilter == nil || routeFilter == route.name ? 1 : 0.35)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(route.name)
                    .accessibilityAddTraits(routeFilter == route.name ? .isSelected : [])
                }
            }
        }
        .scrollIndicators(.hidden)
    }
}

/// One line to one destination: the next departure counted down large, the two after it beside it.
private struct DepartureGroupRow: View {
    let group: DepartureGroup
    let now: Date

    var body: some View {
        HStack(spacing: 12) {
            RouteBadgeView(route: group.route, size: .large)
                .frame(minWidth: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.destination)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                if let first = group.departures.first, first.isRealtime, abs(delay(of: first)) >= 60 {
                    Text(delay(of: first) > 0 ? "\(delay(of: first).shortDuration) late" : "\((-delay(of: first)).shortDuration) early")
                        .font(.footnote)
                        .foregroundStyle(delay(of: first) > 0 ? Color.orange : Color.green)
                }
            }
            Spacer(minLength: 8)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                ForEach(Array(group.departures.enumerated()), id: \.element.id) { index, departure in
                    countdown(for: departure, isNext: index == 0)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(group.route.name) to \(group.destination)")
        .accessibilityValue(group.departures.map { minutes(until: $0) == 0 ? "now" : "\(minutes(until: $0)) minutes" }.joined(separator: ", "))
    }

    private func countdown(for departure: StopDeparture, isNext: Bool) -> some View {
        let minutes = minutes(until: departure)
        return Group {
            if minutes == 0 {
                Text("Now")
            } else if isNext {
                Text("\(minutes) min")
            } else {
                Text("\(minutes)")
            }
        }
        .font(isNext ? .headline : .subheadline)
        .monospacedDigit()
        .foregroundStyle(departure.isRealtime ? Color.green : isNext ? Color.primary : Color.secondary)
    }

    private func minutes(until departure: StopDeparture) -> Int {
        max(0, Int(departure.time.timeIntervalSince(now) / 60))
    }

    private func delay(of departure: StopDeparture) -> TimeInterval {
        departure.time.timeIntervalSince(departure.scheduled)
    }
}
