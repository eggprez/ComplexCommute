import CommuteCore
import GTFSKit
import SwiftUI
import TransitRouting

/// What leaves a station next, live where the agency publishes predictions.
struct StationBoardView: View {
    let station: StationRef

    @Environment(\.transitPlanner) private var transit
    @State private var departures: [StopDeparture]?
    /// Stations a five-minute walk away, which count as the same place (Farragut West from Farragut North).
    @State private var nearby: [NearbyBoard] = []
    @State private var lastUpdated: Date?
    @State private var routeFilter: String?

    static let refreshInterval: Duration = .seconds(30)
    /// A rider wants the next train and a fallback or two, not the afternoon's timetable.
    static let departuresPerDestination = 3

    var body: some View {
        List {
            if let departures {
                let routes = (departures + nearby.flatMap(\.departures)).map(\.route).reduce(into: [RouteBadge]()) { routes, route in
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
                    if let lastUpdated, nearby.isEmpty {
                        updatedNote(lastUpdated)
                    }
                }
                ForEach(nearby) { board in
                    Section {
                        TimelineView(.periodic(from: .now, by: 15)) { context in
                            // Only what can still be reached on foot.
                            let reachable = board.departures.filter { $0.time > context.date.addingTimeInterval(board.walk - 30) && (routeFilter == nil || $0.route.name == routeFilter) }
                            ForEach(DepartureGroup.groups(reachable, limit: Self.departuresPerDestination)) { group in
                                DepartureGroupRow(group: group, now: context.date)
                            }
                        }
                    } header: {
                        Label("\(board.station.name) · \(board.walk.shortDuration) walk", systemImage: "figure.walk")
                    } footer: {
                        if let lastUpdated, board.id == nearby.last?.id {
                            updatedNote(lastUpdated)
                        }
                    }
                }
            }
        }
        .overlay {
            if let departures {
                if departures.isEmpty && nearby.allSatisfy(\.departures.isEmpty) {
                    ContentUnavailableView("No Upcoming Departures", systemImage: "clock.badge.xmark",
                                           description: Text("Nothing is scheduled to leave here in the next two hours."))
                }
            } else {
                ProgressView()
            }
        }
        // Rows otherwise show through the title bar as they scroll under it.
        .scrollEdgeEffectStyle(.hard, for: .top)
        .navigationTitle(station.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            while !Task.isCancelled {
                let found = await transit?.departures(from: station) ?? []
                var others: [NearbyBoard] = []
                for (other, walk) in await transit?.stationsInSamePlace(as: station) ?? [] {
                    others.append(NearbyBoard(station: other, walk: walk, departures: await transit?.departures(from: other) ?? []))
                }
                guard !Task.isCancelled else { return }
                departures = found
                nearby = others.filter { !$0.departures.isEmpty }
                lastUpdated = .now
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    private func updatedNote(_ date: Date) -> some View {
        Text("Updated \(date, format: .dateTime.hour().minute()). Green times are live predictions; the rest are scheduled.")
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

/// Departures from a station in the same place as the one on the board.
private struct NearbyBoard: Identifiable {
    let station: StationRef
    let walk: TimeInterval
    let departures: [StopDeparture]

    var id: String { station.id }
}

/// One line to one destination: the next departure counted down large, the two after it beside it.
private struct DepartureGroupRow: View {
    let group: DepartureGroup
    let now: Date

    @ScaledMetric(relativeTo: .headline) private var nextWidth: CGFloat = 60
    @ScaledMetric(relativeTo: .subheadline) private var laterWidth: CGFloat = 24

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
                        .foregroundStyle(delay(of: first) > 0 ? Color.warningText : Color.goodText)
                }
            }
            Spacer(minLength: 8)
            // Fixed columns, so the next departures line up down the board whatever the destination's length.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ForEach(0..<StationBoardView.departuresPerDestination, id: \.self) { index in
                    Group {
                        if index < group.departures.count {
                            countdown(for: group.departures[index], isNext: index == 0)
                        } else {
                            Color.clear.frame(height: 1)
                        }
                    }
                    .frame(width: index == 0 ? nextWidth : laterWidth, alignment: .trailing)
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
        .foregroundStyle(departure.isRealtime ? Color.goodText : isNext ? Color.primary : Color.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private func minutes(until departure: StopDeparture) -> Int {
        max(0, Int(departure.time.timeIntervalSince(now) / 60))
    }

    private func delay(of departure: StopDeparture) -> TimeInterval {
        departure.time.timeIntervalSince(departure.scheduled)
    }
}
