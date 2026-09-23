import CommuteCore
import SwiftUI

// The pieces of a trip that are drawn the same in the app, on the Lock Screen and on the wrist.

extension ArrivalStanding {
    var tint: Color {
        switch self {
        case .ahead: Color.green.mix(with: .white, by: 0.45)
        case .onTime: .green
        case .slipping: .orange
        case .late: .red
        }
    }

    var label: String {
        switch self {
        case .ahead: "Ahead of Time"
        case .onTime: "On Time"
        case .slipping: "Running Late"
        case .late: "Late"
        }
    }

    var symbol: String {
        switch self {
        case .ahead: "checkmark.circle.fill"
        case .onTime: "checkmark.circle.fill"
        case .slipping: "exclamationmark.circle.fill"
        case .late: "exclamationmark.triangle.fill"
        }
    }
}

extension ArriveByProgress {
    /// "+7" late, "−4" early, in minutes: the bar in as few characters as it can be said.
    var shortDelta: String {
        let minutes = Int((delta / 60).rounded())
        return minutes == 0 ? "0" : minutes > 0 ? "+\(minutes)" : "−\(-minutes)"
    }
}

/// Half an hour either side of the target. The bar is painted with what each stretch of it means, a
/// dotted line marks the target itself, and the ball takes the colour of wherever it has got to.
struct ArriveByTrack: View {
    enum Labels {
        /// "−30 min" and "+30 min" at either end.
        case full
        /// No room for them: the Dynamic Island, the Watch.
        case none
    }

    let progress: ArriveByProgress
    var height: CGFloat = 10
    var labels = Labels.full

    private var ball: CGFloat { height * 1.8 }
    /// The dotted line stands clear of the ball, so the target shows even with the ball sitting on it.
    private var full: CGFloat { ball + max(8, height) }

    var body: some View {
        HStack(spacing: 8) {
            if labels == .full { end("−30 min") }
            track
            if labels == .full { end("+30 min") }
        }
        .accessibilityHidden(true)
    }

    private func end(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .fixedSize()
    }

    private var track: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                // The bands, early to late.
                ZStack(alignment: .leading) {
                    ForEach(ArrivalStanding.allCases, id: \.self) { standing in
                        let span = ArriveByProgress.span(of: standing)
                        Rectangle()
                            .fill(standing.tint.opacity(standing == progress.standing ? 0.75 : 0.4))
                            .frame(width: width * (span.upperBound - span.lowerBound))
                            .offset(x: width * span.lowerBound)
                    }
                }
                .frame(width: width, height: height, alignment: .leading)
                .clipShape(.capsule)

                // The time to be there by.
                Path { path in
                    path.move(to: CGPoint(x: width / 2, y: 0))
                    path.addLine(to: CGPoint(x: width / 2, y: full))
                }
                .stroke(.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [0.5, 4]))
                .frame(height: full)

                Circle()
                    .fill(progress.standing.tint)
                    .overlay(Circle().strokeBorder(.white, lineWidth: max(2, ball * 0.14)))
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .frame(width: ball, height: ball)
                    .offset(x: min(max(width * progress.position - ball / 2, 0), width - ball))
                    .animation(.easeInOut, value: progress.position)
                    .animation(.easeInOut, value: progress.standing)
            }
            .frame(height: full)
        }
        .frame(height: full)
    }
}

/// A line's bullet, drawn from the little a glance carries about it.
struct RouteLabelBadge: View {
    let route: RouteLabel
    var height: CGFloat = 22

    var body: some View {
        let isShort = route.name.count <= 2
        Text(route.name)
            .font(.system(size: height * 0.55, weight: .bold))
            .lineLimit(1)
            .foregroundStyle(Color(hex: route.textColorHex) ?? (route.colorHex == nil ? Color.primary : Color.white))
            .padding(.horizontal, isShort ? 0 : height * 0.3)
            .frame(minWidth: height, minHeight: height)
            .background(Color(hex: route.colorHex) ?? Color.gray.opacity(0.35), in: .rect(cornerRadius: isShort ? height / 2 : height * 0.28))
            .accessibilityLabel("\(route.name) line")
    }
}

extension TripInstruction {
    var symbol: String {
        switch kind {
        case .arrived: "flag.checkered"
        case .change: "arrow.triangle.swap"
        default: (mode ?? .transit).symbol
        }
    }

    /// What the deadline is a deadline for, leading into the countdown.
    var deadlineLabel: String? {
        guard let deadline else { return nil }
        return switch kind {
        case .leave: "Leave in"
        case .travel: "Arrive \(deadline.clockTime) ·"
        case .board, .change: "Departs \(deadline.clockTime) ·"
        case .ride: "Arrives \(deadline.clockTime) ·"
        case .arrived: nil
        }
    }
}

/// The line's bullet for a ride, the mode's symbol for anything else.
struct InstructionIcon: View {
    let instruction: TripInstruction
    var size: CGFloat = 26

    var body: some View {
        if let route = instruction.route {
            RouteLabelBadge(route: route, height: size)
        } else {
            Image(systemName: instruction.symbol)
                .font(.system(size: size * 0.75, weight: .semibold))
                .frame(minWidth: size, minHeight: size)
                .accessibilityHidden(true)
        }
    }
}

/// "Departs 8:42 · 3:10", ticking on its own: a Live Activity is only redrawn when the app says so,
/// and a countdown that waited for that would be wrong most of the time.
struct DeadlineText: View {
    let instruction: TripInstruction

    var body: some View {
        if let deadline = instruction.deadline, let label = instruction.deadlineLabel {
            Text("\(label) \(Text(timerInterval: min(.now, deadline)...deadline, countsDown: true))")
                .monospacedDigit()
        }
    }
}

/// "Next to 57 St" and the next few vehicles from the change coming up, the planned one picked out and
/// live times in green, as Maps shows them. Every one listed stops there, whichever line it is.
struct ConnectionBoardRow: View {
    let board: ConnectionBoard
    var badgeHeight: CGFloat = 18
    /// Leave out the station, where the instruction beside it already names it.
    var showsStation = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(showsStation ? "Next to \(board.toward) from \(board.station)" : "Next to \(board.toward)")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            // As many as fit on one line: three on the Lock Screen, maybe two on a wrist.
            ViewThatFits(in: .horizontal) {
                ForEach((1...max(1, board.departures.count)).reversed(), id: \.self) { count in
                    times(Array(board.departures.prefix(count)))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    private func times(_ departures: [ConnectionBoard.Departure]) -> some View {
        HStack(spacing: 10) {
            ForEach(departures, id: \.self) { departure in
                HStack(spacing: 4) {
                    RouteLabelBadge(route: departure.route, height: badgeHeight)
                    Text(departure.time.clockTime)
                        .font(.footnote.weight(departure.isPlanned ? .bold : .regular))
                        .monospacedDigit()
                        .foregroundStyle(departure.isRealtime ? Color.green : departure.isPlanned ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
    }

    private var spoken: String {
        let times = board.departures.map { departure in
            "\(departure.route.name) at \(departure.time.clockTime)\(departure.isPlanned ? ", your train" : "")\(departure.isRealtime ? ", live" : "")"
        }
        return "Next to \(board.toward) from \(board.station): \(times.joined(separator: "; "))"
    }
}
