import AppIntents
import CommuteCore
import GTFSKit
import SwiftUI
import TransitRouting
import WidgetKit

/// What leaves next from wherever the rider is standing: subway, rail and buses, nearest first.
struct NearbyDeparturesWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetKind.nearby, intent: NearbyDeparturesIntent.self, provider: NearbyTimelineProvider()) { entry in
            NearbyDeparturesView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Nearby Departures")
        .description("The next subways, trains and buses from the stations and stops around you.")
        // Extra large is the iPad's; on an iPhone, large is as big as a widget gets.
        .supportedFamilies([.systemMedium, .systemLarge, .systemExtraLarge])
    }
}

private struct NearbyDeparturesView: View {
    let entry: NearbyEntry

    @Environment(\.widgetFamily) private var family

    /// Rows that fit under the header: a station's name counts as one, each of its lines as another.
    private var rows: Int {
        switch family {
        case .systemMedium: 4
        default: 12
        }
    }

    private var columns: Int { family == .systemExtraLarge ? 2 : 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            switch entry.content {
            case .boards(let boards):
                let upcoming = boards.map { $0.upcoming(at: entry.date) }.filter { !$0.groups.isEmpty }
                if upcoming.isEmpty {
                    // The timeline outran what was looked up: iOS hasn't let the widget reload in a long while.
                    message("Tap to Refresh", "These departures have all left.", symbol: "arrow.clockwise")
                } else {
                    board(upcoming)
                }
            case .noLocation:
                message("Location Unavailable", "Allow Commute to use your location, then tap refresh.", symbol: "location.slash.fill")
            case .noSchedules:
                message("No Transit Data", "Open Commute and download the schedules for your city.", symbol: "tram.fill")
            case .nothingNearby:
                message("Nothing Nearby", "No station or stop is within a short walk of here.", symbol: "mappin.slash")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "location.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tint)
                .widgetAccentable()
            Text("Nearby")
                .font(.headline)
            Spacer(minLength: 4)
            Text("Updated \(entry.fetchedAt, style: .time)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                // Dims while a refresh is on its way, which is all the feedback a widget can give.
                .invalidatableContent()
            Button(intent: RefreshDeparturesIntent()) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption.weight(.bold))
                    .frame(width: 28, height: 28)
                    .background(.tint.opacity(0.15), in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .widgetAccentable()
            .accessibilityLabel("Refresh")
            .accessibilityHint("Finds where you are and looks up departures again")
        }
    }

    @ViewBuilder
    private func board(_ boards: [NearbyBoard]) -> some View {
        let columns = Self.columns(of: boards, count: columns, rows: rows, perStation: family == .systemMedium ? 3 : 4)
        HStack(alignment: .top, spacing: 20) {
            ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(column) { board in
                        StationSection(board: board, now: entry.date, showsLive: entry.showsLive, isRoomy: family != .systemMedium)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .invalidatableContent()
    }

    private func message(_ title: String, _ detail: String, symbol: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Deals stations into columns, nearest first, each trimmed to the lines there is room for. A station is only
    /// started where it can show at least one line under its name.
    static func columns(of boards: [NearbyBoard], count: Int, rows: Int, perStation: Int) -> [[NearbyBoard]] {
        var columns: [[NearbyBoard]] = []
        var remaining = boards[...]
        for _ in 0..<count {
            var column: [NearbyBoard] = []
            var left = rows
            while let next = remaining.first, left >= 2 {
                var board = next
                board.groups = Array(next.groups.prefix(min(perStation, left - 1)))
                column.append(board)
                left -= 1 + board.groups.count
                remaining = remaining.dropFirst()
            }
            if !column.isEmpty { columns.append(column) }
        }
        return columns
    }
}

/// A station or stop, how far it is, and its next departures. Tapping it opens its full board in the app.
private struct StationSection: View {
    let board: NearbyBoard
    let now: Date
    let showsLive: Bool
    let isRoomy: Bool

    var body: some View {
        Link(destination: AppLink.station(board.station).url) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: board.isBus ? "bus.fill" : "tram.fill")
                    Text(board.station.name)
                        .lineLimit(1)
                    Text("· \(board.walk.shortDuration) walk")
                        .fontWeight(.regular)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(height: 16)

                ForEach(board.groups) { group in
                    DepartureRow(group: group, now: now, showsLive: showsLive, showsLater: true, isRoomy: isRoomy)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One line to one destination: its bullet, where it is going, the minutes to the next one, and the ones after.
private struct DepartureRow: View {
    let group: DepartureGroup
    let now: Date
    let showsLive: Bool
    let showsLater: Bool
    let isRoomy: Bool

    var body: some View {
        HStack(spacing: 8) {
            RouteBadgeView(route: group.route, size: .regular)
                .frame(minWidth: 30, maxWidth: 96, alignment: .leading)
                .fixedSize()
                .widgetAccentable()
            Text(group.destination)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 4)
            if showsLater, group.departures.count > 1 {
                Text(group.departures.dropFirst().prefix(2).map { "\(minutes(until: $0))" }.joined(separator: ", "))
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let first = group.departures.first {
                countdown(to: first)
                    .frame(minWidth: 46, alignment: .trailing)
            }
        }
        .frame(height: isRoomy ? 22 : 20)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(group.route.name) to \(group.destination)")
        .accessibilityValue(group.departures.map { minutes(until: $0) == 0 ? "now" : "\(minutes(until: $0)) minutes" }.joined(separator: ", "))
    }

    private func countdown(to departure: StopDeparture) -> some View {
        let minutes = minutes(until: departure)
        return Group {
            if minutes == 0 {
                Text("Now")
            } else {
                Text("\(minutes)\(Text(" min").font(.caption2.weight(.semibold)))")
            }
        }
        .font(.system(.callout, design: .rounded, weight: .bold))
        .monospacedDigit()
        // Green is a live prediction, as on a station's board in the app.
        .foregroundStyle(departure.isRealtime && showsLive ? Color.goodText : Color.primary)
        .lineLimit(1)
    }

    private func minutes(until departure: StopDeparture) -> Int {
        max(0, Int(departure.time.timeIntervalSince(now) / 60))
    }
}

#Preview(as: .systemLarge) {
    NearbyDeparturesWidget()
} timeline: {
    NearbyEntry(date: .now, content: .boards(NearbyBoard.samples(at: .now)), fetchedAt: .now)
    NearbyEntry(date: .now, content: .noSchedules, fetchedAt: .now)
}
