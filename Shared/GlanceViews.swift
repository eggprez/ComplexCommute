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

/// A quarter of an hour either side of the target, with the target itself marked in the middle.
struct ArriveByTrack: View {
    let progress: ArriveByProgress
    var height: CGFloat = 14

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                Capsule()
                    .fill(progress.standing.tint)
                    .frame(width: max(height / 2, width * progress.position))
                Rectangle()
                    .fill(.secondary)
                    .frame(width: 1.5)
                    .offset(x: width / 2)
                Circle()
                    .fill(progress.standing.tint)
                    .overlay(Circle().strokeBorder(.background, lineWidth: 2))
                    .frame(width: height, height: height)
                    .offset(x: min(max(width * progress.position - height / 2, 0), width - height))
                    .animation(.easeInOut, value: progress.position)
            }
        }
        .frame(height: height)
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
