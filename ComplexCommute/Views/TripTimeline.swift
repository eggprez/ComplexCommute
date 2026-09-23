import CommuteCore
import GTFSKit
import SwiftUI

/// How the line down the side of a timeline is drawn for one kind of travel.
struct Spine: Equatable {
    enum Stroke: Equatable {
        case solid
        case dotted
        case dashed
    }

    var color: Color
    var stroke = Stroke.solid
    var width: CGFloat = 5

    static let drive = Spine(color: TravelMode.drive.tint)
    static let walk = Spine(color: Color(.systemGray2), stroke: .dotted, width: 4)
    static let estimate = Spine(color: TravelMode.transit.tint, stroke: .dashed)

    static func ride(_ ride: Ride) -> Spine {
        Spine(color: Color(hex: ride.routeColorHex) ?? TravelMode.transit.tint, width: 7)
    }

    static func travel(_ leg: Leg) -> Spine {
        switch leg.mode {
        case .drive: .drive
        case .walk: .walk
        case .transit: .estimate
        }
    }
}

/// What sits on the line beside a row.
enum SpineNode: Equatable {
    case none
    /// A place the rider pinned: the trip's start, end, or a stop between.
    case waypoint
    /// Where a vehicle is boarded or left.
    case station(Color)
    /// A stop the vehicle calls at on the way.
    case pass(Color)
}

/// One row of a timeline: a time, a piece of the line, and whatever describes it.
struct TimelineRow<Content: View>: View {
    var time: Date?
    var isMajor = false
    var above: Spine?
    var below: Spine?
    var node = SpineNode.none
    @ViewBuilder var content: Content

    /// Center of the first line of text, where a row's node sits. Grows with the text beside it.
    @ScaledMetric(relativeTo: .subheadline) private var nodeY: CGFloat = 17
    /// Wide enough for "12:59" in the row's own type size.
    @ScaledMetric(relativeTo: .subheadline) private var timeWidth: CGFloat = 46

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                if let time {
                    Text(time.clockTime)
                        .font(isMajor ? .subheadline.weight(.semibold) : .footnote)
                        .foregroundStyle(isMajor ? Color.primary : Color.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                } else {
                    Color.clear
                }
            }
            .frame(width: timeWidth, height: nodeY * 2, alignment: .trailing)

            spine
                .frame(width: 22)

            content
                .frame(maxWidth: .infinity, minHeight: nodeY * 2, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var spine: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                SpineLine(spine: above)
                    .frame(height: nodeY)
                SpineLine(spine: below)
            }
            nodeView
                .frame(width: 22, height: nodeY * 2)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var nodeView: some View {
        switch node {
        case .none:
            EmptyView()
        case .waypoint:
            Circle()
                .fill(.background)
                .stroke(Color.primary, lineWidth: 4)
                .frame(width: 16, height: 16)
        case .station(let color):
            Circle()
                .fill(.white)
                .stroke(color, lineWidth: 3.5)
                .frame(width: 15, height: 15)
        case .pass(let color):
            Circle()
                .fill(.white)
                .stroke(color, lineWidth: 1.5)
                .frame(width: 8, height: 8)
        }
    }
}

private struct SpineLine: View {
    let spine: Spine?

    var body: some View {
        if let spine {
            VerticalLine()
                .stroke(spine.color, style: style(for: spine))
                .frame(maxHeight: .infinity)
        } else {
            Color.clear
        }
    }

    private func style(for spine: Spine) -> StrokeStyle {
        switch spine.stroke {
        case .solid: StrokeStyle(lineWidth: spine.width, lineCap: .butt)
        case .dotted: StrokeStyle(lineWidth: spine.width, lineCap: .round, dash: [0.1, spine.width * 2])
        case .dashed: StrokeStyle(lineWidth: spine.width, lineCap: .butt, dash: [6, 5])
        }
    }
}

private nonisolated struct VerticalLine: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        }
    }
}

/// A trip drawn as a line diagram: pinned places and stations sit on a line that is dotted where the rider walks,
/// blue where they drive and the route's own color where they ride.
struct TripTimeline: View {
    let legs: [Leg]

    @Environment(SheetRouter.self) private var router
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(legs.enumerated()), id: \.element.id) { index, leg in
                let previous = index > 0 ? legs[index - 1] : nil
                waypointRow(leg.from, time: previous?.arrival ?? leg.departure, above: previous.map(lastSpine), below: firstSpine(of: leg))
                if let previous, leg.departure.timeIntervalSince(previous.arrival) >= 60, leg.option.rides.isEmpty {
                    TimelineRow(above: firstSpine(of: leg), below: firstSpine(of: leg)) {
                        caption("Wait \(leg.departure.timeIntervalSince(previous.arrival).shortDuration)", systemImage: "clock")
                    }
                }
                if leg.option.rides.isEmpty {
                    travelRows(for: leg)
                } else {
                    rideRows(for: leg, readyAt: previous?.arrival ?? leg.departure)
                }
            }
            if let last = legs.last {
                waypointRow(last.to, time: last.arrival, above: lastSpine(of: last), below: nil)
            }
        }
        .buttonStyle(.borderless)
    }

    // MARK: Spines

    private func firstSpine(of leg: Leg) -> Spine {
        // Every ride is reached on foot, if only across the platform.
        leg.option.rides.isEmpty ? .travel(leg) : .walk
    }

    private func lastSpine(of leg: Leg) -> Spine {
        guard let ride = leg.option.rides.last else { return .travel(leg) }
        return exitsAtDestination(ride, of: leg) ? .ride(ride) : .walk
    }

    /// The pinned station is the one boarded at, so it needn't be named twice.
    private func boardsAtOrigin(_ ride: Ride, of leg: Leg) -> Bool {
        ride.boardStopName == leg.from.name && ride.walkBefore < 60
    }

    private func exitsAtDestination(_ ride: Ride, of leg: Leg) -> Bool {
        ride.alightStopName == leg.to.name && leg.option.walkAfter < 60
    }

    // MARK: Rows

    private func waypointRow(_ waypoint: Waypoint, time: Date, above: Spine?, below: Spine?) -> some View {
        TimelineRow(time: time, isMajor: true, above: above, below: below, node: .waypoint) {
            Button {
                router.station = waypoint.station
            } label: {
                HStack(spacing: 4) {
                    Text(waypoint.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .multilineTextAlignment(.leading)
                    if waypoint.station != nil {
                        disclosure
                    }
                }
                .contentShape(.rect)
            }
            .disabled(waypoint.station == nil)
            .accessibilityHint(waypoint.station == nil ? "" : "Shows departures")
        }
    }

    /// A drive, a walk, or a transit leg with no schedule behind it: one stretch of line, and a way to be
    /// shown down it by a maps app.
    @ViewBuilder
    private func travelRows(for leg: Leg) -> some View {
        let spine = Spine.travel(leg)
        TimelineRow(above: spine, below: spine) {
            HStack(spacing: 6) {
                Image(systemName: leg.mode.symbol)
                    .foregroundStyle(leg.mode.tint)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(travelSummary(for: leg))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Color.primary)
                    if let summary = leg.option.summary {
                        Text("via \(summary)")
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                }
                Spacer(minLength: 0)
                if leg.mode != .transit {
                    DirectionsButton(destination: leg.to, mode: leg.mode)
                        .labelStyle(.iconOnly)
                        .accessibilityLabel("Directions to \(leg.to.name)")
                }
            }
        }
        if leg.option.isEstimate {
            TimelineRow(above: spine, below: spine) {
                estimateNotice
            }
        }
    }

    private func travelSummary(for leg: Leg) -> String {
        var parts = [leg.mode.label, "\(leg.option.isEstimate ? "about " : "")\(leg.duration.shortDuration)"]
        if let meters = leg.option.distanceMeters, !leg.option.isEstimate {
            parts.append(meters.roadDistance)
        }
        return parts.joined(separator: " · ")
    }

    /// Without a schedule there are no lines, transfers or stops to show, so say why and how to fix it.
    private var estimateNotice: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No installed schedule connects these stops, so this is only a time estimate.")
                .foregroundStyle(Color.secondary)
            Button("Transit Data…") { router.isShowingTransitData = true }
        }
        .font(.caption)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func rideRows(for leg: Leg, readyAt: Date) -> some View {
        let rides = leg.option.rides
        ForEach(Array(rides.enumerated()), id: \.offset) { index, ride in
            let previous = index > 0 ? rides[index - 1] : nil
            let isMerged = index == 0 && boardsAtOrigin(ride, of: leg)
            let freeAt = previous?.alight ?? readyAt
            connectionRow(walk: ride.walkBefore, wait: ride.board.timeIntervalSince(freeAt) - ride.walkBefore, isTransfer: previous != nil,
                          freeTransfer: ride.freeTransfer)
            boardRow(ride, showsName: !isMerged && previous?.alightStopName != ride.boardStopName)
            stopsRows(for: ride, key: "stops.\(leg.id).\(index)")

            let isLast = index == rides.count - 1
            if !(isLast && exitsAtDestination(ride, of: leg)) {
                TimelineRow(time: ride.alight, above: .ride(ride), below: .walk, node: .station(Spine.ride(ride).color)) {
                    stationButton(ride.stops.last?.station, name: ride.alightStopName)
                }
            }
        }
        if leg.option.walkAfter >= 60 {
            TimelineRow(above: .walk, below: .walk) {
                caption("Walk \(leg.option.walkAfter.shortDuration)", systemImage: "figure.walk")
            }
        }
        ForEach(leg.option.alerts) { alert in
            TimelineRow(above: lastSpine(of: leg), below: lastSpine(of: leg)) {
                AlertRow(alert: alert)
            }
        }
    }

    /// Getting to a platform: the walk there, and the time in hand before the vehicle leaves.
    @ViewBuilder
    private func connectionRow(walk: TimeInterval, wait: TimeInterval, isTransfer: Bool, freeTransfer: String? = nil) -> some View {
        if walk >= 60 || wait >= 60 || freeTransfer != nil {
            TimelineRow(above: .walk, below: .walk) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 10) {
                        if walk >= 60 {
                            caption("\(isTransfer ? "Transfer" : "Walk") \(walk.shortDuration)", systemImage: "figure.walk")
                        }
                        if wait >= 60 {
                            caption("Wait \(wait.shortDuration)", systemImage: "clock")
                        }
                    }
                    // Leaving one station for another usually means paying again; say so when it doesn't.
                    if let freeTransfer {
                        Label(freeTransfer, systemImage: "ticket")
                            .font(.footnote)
                            .foregroundStyle(Color.goodText)
                    }
                }
            }
        }
    }

    private func boardRow(_ ride: Ride, showsName: Bool) -> some View {
        TimelineRow(time: ride.board, isMajor: true, above: .walk, below: .ride(ride), node: .station(Spine.ride(ride).color)) {
            VStack(alignment: .leading, spacing: 3) {
                if showsName {
                    stationButton(ride.stops.first?.station, name: ride.boardStopName)
                }
                HStack(spacing: 6) {
                    RouteBadgeView(route: ride.badge, size: .regular)
                    VStack(alignment: .leading, spacing: 0) {
                        if let headsign = ride.headsign {
                            Text("to \(headsign)")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(Color.primary)
                                .lineLimit(1)
                        }
                        if ride.isRealtime {
                            LiveStatus(ride: ride)
                                .font(.caption)
                        }
                    }
                }
            }
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private func stopsRows(for ride: Ride, key: String) -> some View {
        let spine = Spine.ride(ride)
        let isOpen = expanded.contains(key)
        TimelineRow(above: spine, below: spine) {
            Button {
                withAnimation(.snappy) { toggle(key) }
            } label: {
                HStack(spacing: 4) {
                    Text("\(ride.stopCount) \(ride.stopCount == 1 ? "stop" : "stops") · \(ride.alight.timeIntervalSince(ride.board).shortDuration)")
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                    if !ride.intermediateStops.isEmpty {
                        chevron(isOpen: isOpen)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .disabled(ride.intermediateStops.isEmpty)
        }
        if isOpen {
            ForEach(ride.intermediateStops, id: \.self) { stop in
                TimelineRow(time: stop.time, above: spine, below: spine, node: .pass(spine.color)) {
                    stationButton(stop.station, name: stop.station.name, isMinor: true)
                }
            }
        }
    }

    // MARK: Pieces

    private func stationButton(_ station: StationRef?, name: String, isMinor: Bool = false) -> some View {
        Button {
            router.station = station
        } label: {
            HStack(spacing: 4) {
                Text(name)
                    .font(isMinor ? .footnote : .subheadline.weight(.medium))
                    .foregroundStyle(isMinor ? Color.secondary : Color.primary)
                    .multilineTextAlignment(.leading)
                if station != nil {
                    disclosure
                }
            }
            .contentShape(.rect)
        }
        .disabled(station == nil)
        .accessibilityHint("Shows departures")
    }

    /// Icon and words kept together: a Label inside a List row is spread out to line up with the row's icon column.
    private func caption(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(text)
        }
        .font(.footnote)
        .foregroundStyle(Color.secondary)
    }

    private var disclosure: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.secondary.opacity(0.6))
    }

    private func chevron(isOpen: Bool) -> some View {
        Image(systemName: "chevron.down")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.secondary)
            .rotationEffect(.degrees(isOpen ? 180 : 0))
    }

    private func toggle(_ key: String) {
        if !expanded.insert(key).inserted {
            expanded.remove(key)
        }
    }
}

/// "((•)) 2 min late": whether a ride's prediction is live, and how it compares with the timetable.
struct LiveStatus: View {
    let ride: Ride

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .imageScale(.small)
            Text(ride.liveStatus)
        }
        .foregroundStyle(ride.isLate ? Color.warningText : Color.goodText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Live, \(ride.liveStatus)")
    }
}
