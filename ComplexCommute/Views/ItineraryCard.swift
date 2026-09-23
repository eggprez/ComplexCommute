import CommuteCore
import GTFSKit
import SwiftUI

/// One trip option. The selected card expands to show its legs.
struct ItineraryCard: View {
    let itinerary: Itinerary
    let tags: Set<ItineraryTag>
    let isSelected: Bool
    let isLeavingNow: Bool
    /// Set when the rider is planning backwards from a time they have to be there by.
    var target: Date?
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
                TripTimeline(legs: itinerary.legs)
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
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.primary)
            }

            HStack(spacing: 6) {
                Text(timeRange)
                    .foregroundStyle(Color.secondary)
                    .monospacedDigit()
                if let target {
                    let progress = ArriveByProgress(target: target, projectedArrival: itinerary.arrival)
                    Text(progress.deltaDescription)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(progress.standing.isBehind ? progress.standing.tint : Color.secondary)
                }
                if itinerary.hasRealtime {
                    Label("Live", systemImage: "dot.radiowaves.left.and.right")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(Color.goodText)
                }
                if !itinerary.alerts.isEmpty {
                    Label("Service alerts", systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(Color.orange)
                }
            }
            .font(.subheadline)

            SegmentStrip(legs: itinerary.legs)

            if !tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(ItineraryTag.allCases.filter(tags.contains), id: \.self) { tag in
                        Text(tag.label)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.goodText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.green.opacity(0.18), in: .capsule)
                    }
                }
            }
        }
    }

    /// "8:42 – 9:10 AM": the half of the day is said once unless the trip crosses noon or midnight.
    private var timeRange: String {
        let calendar = Calendar.current
        let sameHalf = calendar.isDate(itinerary.departure, inSameDayAs: itinerary.arrival)
            && (calendar.component(.hour, from: itinerary.departure) < 12) == (calendar.component(.hour, from: itinerary.arrival) < 12)
        let start = sameHalf ? itinerary.departure.clockTime : itinerary.departure.formatted(date: .omitted, time: .shortened)
        return "\(start) – \(itinerary.arrival.formatted(date: .omitted, time: .shortened))"
    }

    private var headline: String {
        guard target == nil else {
            return "Leave \(itinerary.departure.formatted(date: .omitted, time: .shortened))"
        }
        guard isLeavingNow else {
            return "Arrive \(itinerary.arrival.formatted(date: .omitted, time: .shortened))"
        }
        let lead = itinerary.departure.timeIntervalSinceNow
        return lead < 60 ? "Leave now" : "Leave in \(lead.shortDuration)"
    }
}

/// The trip at a glance: each stretch as a chip, in order. Drives and walks show their minutes; rides show their line.
struct SegmentStrip: View {
    let legs: [Leg]

    private enum Piece: Hashable {
        case travel(TravelMode, TimeInterval)
        case ride(RouteBadge)
    }

    /// Walks this short inside a transit leg are just getting to the platform.
    private static let notableWalk: TimeInterval = 120

    private var pieces: [Piece] {
        legs.flatMap { leg -> [Piece] in
            guard !leg.option.rides.isEmpty else { return [.travel(leg.mode, leg.duration)] }
            var pieces: [Piece] = []
            for ride in leg.option.rides {
                if ride.walkBefore >= Self.notableWalk { pieces.append(.travel(.walk, ride.walkBefore)) }
                pieces.append(.ride(ride.badge))
            }
            if leg.option.walkAfter >= Self.notableWalk { pieces.append(.travel(.walk, leg.option.walkAfter)) }
            return pieces
        }
    }

    var body: some View {
        // A long trip drops its walks before anything gets squeezed or cut off.
        let rides = pieces.filter { if case .ride = $0 { true } else { false } }
        ViewThatFits(in: .horizontal) {
            strip(pieces).fixedSize()
            strip(rides).fixedSize()
            // Several long line names ("Babylon Branch", "City Terminal Zone") still won't fit: let the long
            // names truncate rather than push the whole card off the screen. Short ones keep their size.
            strip(rides)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
        }
    }

    private func strip(_ pieces: [Piece]) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(pieces.enumerated()), id: \.offset) { index, piece in
                if index > 0 {
                    Image(systemName: "chevron.compact.right")
                        .font(.footnote)
                        .foregroundStyle(Color.secondary.opacity(0.5))
                }
                switch piece {
                case .travel(let mode, let seconds):
                    HStack(spacing: 3) {
                        Image(systemName: mode.symbol)
                        Text("\(Int((max(60, seconds) / 60).rounded()))")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(mode == .walk ? Color.secondary : mode.tint)
                    .padding(.horizontal, 7)
                    .frame(height: 22)
                    .background((mode == .walk ? Color.secondary : mode.tint).opacity(0.14), in: .capsule)
                    .accessibilityLabel("\(mode.label) \(seconds.shortDuration)")
                case .ride(let badge):
                    RouteBadgeView(route: badge, size: .regular)
                }
            }
        }
        .lineLimit(1)
    }
}

struct AlertRow: View {
    let alert: ServiceAlert
    @State private var isShowingDetails = false

    var body: some View {
        Button {
            isShowingDetails = true
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.orange)
                Text(alert.header.withoutBulletCodes)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(Color.primary)
            }
            .font(.footnote)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .sheet(isPresented: $isShowingDetails) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 4) {
                            ForEach(alert.routeNames, id: \.self) { name in
                                Text(name)
                                    .font(.caption.weight(.bold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color(.systemGray4), in: .capsule)
                            }
                        }
                        Text(alert.header.withoutBulletCodes)
                            .font(.headline)
                        if !alert.details.isEmpty {
                            Text(alert.details.withoutBulletCodes)
                        }
                        if let url = alert.url {
                            Link("More Information", destination: url)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
                .navigationTitle("Service Alert")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", systemImage: "checkmark") { isShowingDetails = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
}

extension Ride {
    /// A minute or more behind schedule.
    var isLate: Bool { board.timeIntervalSince(scheduledBoard) >= 60 }

    var liveStatus: String {
        let delay = board.timeIntervalSince(scheduledBoard)
        if delay >= 60 { return "\(delay.shortDuration) late" }
        if delay <= -60 { return "\((-delay).shortDuration) early" }
        return "on time"
    }

    var badge: RouteBadge {
        RouteBadge(name: routeName, colorHex: routeColorHex, textColorHex: routeTextColorHex, type: routeType)
    }
}
