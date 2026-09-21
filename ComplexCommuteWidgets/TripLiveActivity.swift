import ActivityKit
import CommuteCore
import SwiftUI
import WidgetKit

/// The trip in progress, wherever the app isn't: Lock Screen, Dynamic Island, and the Watch's Smart Stack.
struct TripLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TripActivityAttributes.self) { context in
            TripActivityView(glance: context.state, isStale: context.isStale)
        } dynamicIsland: { context in
            let glance = context.state
            let tint = glance.progress?.standing.tint ?? .accentColor
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    StandingLabel(glance: glance)
                        .font(.subheadline.weight(.semibold))
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(glance.progress.map { "by \($0.target.clockTime)" } ?? glance.destination)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let progress = glance.progress {
                            ArriveByTrack(progress: progress, height: 10)
                        }
                        InstructionRow(instruction: glance.instruction)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                InstructionIcon(instruction: glance.instruction, size: 20)
                    .foregroundStyle(tint)
            } compactTrailing: {
                if let progress = glance.progress {
                    Text(progress.shortDelta)
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                        .accessibilityLabel(progress.deltaDescription)
                } else {
                    Text(glance.arrival.clockTime)
                        .monospacedDigit()
                }
            } minimal: {
                Image(systemName: glance.progress?.standing.symbol ?? glance.instruction.symbol)
                    .foregroundStyle(tint)
            }
            .keylineTint(tint)
        }
        .supplementalActivityFamilies([.small])
    }
}

private struct TripActivityView: View {
    let glance: TripGlance
    let isStale: Bool

    @Environment(\.activityFamily) private var family

    var body: some View {
        switch family {
        case .small:
            small
        default:
            lockScreen
                .activityBackgroundTint(glance.progress.map { $0.standing.tint.opacity(0.16) })
        }
    }

    private var lockScreen: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    StandingLabel(glance: glance)
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                    Group {
                        if isStale, !glance.isFinished {
                            Text("Open Commute to update")
                        } else if let progress = glance.progress {
                            Text("\(progress.deltaDescription) · by \(progress.target.clockTime)")
                        } else {
                            Text(glance.destination)
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                if let progress = glance.progress {
                    ArriveByTrack(progress: progress)
                }
            }
            InstructionRow(instruction: glance.instruction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .opacity(isStale && !glance.isFinished ? 0.6 : 1)
    }

    /// The Watch's Smart Stack: the bar, and one line for what comes next.
    private var small: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                StandingLabel(glance: glance)
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 0)
                if let progress = glance.progress {
                    Text(progress.shortDelta)
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(progress.standing.tint)
                        .accessibilityLabel(progress.deltaDescription)
                }
            }
            if let progress = glance.progress {
                ArriveByTrack(progress: progress, height: 8)
            }
            HStack(spacing: 5) {
                InstructionIcon(instruction: glance.instruction, size: 18)
                Text(glance.instruction.title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(glance.instruction.spokenTitle)
            DeadlineText(instruction: glance.instruction)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .opacity(isStale && !glance.isFinished ? 0.6 : 1)
    }
}

/// "On Time" against an arrival time; without one, the arrival time itself stands in.
private struct StandingLabel: View {
    let glance: TripGlance

    var body: some View {
        if let progress = glance.progress {
            Label(progress.isFinal ? "Arrived" : progress.standing.label, systemImage: progress.standing.symbol)
                .labelStyle(TintedIconLabelStyle(tint: progress.standing.tint))
                .lineLimit(1)
        } else {
            Text(glance.isFinished ? "Arrived \(glance.arrival.clockTime)" : "Arrive \(glance.arrival.clockTime)")
                .lineLimit(1)
        }
    }
}

private struct TintedIconLabelStyle: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}

private struct InstructionRow: View {
    let instruction: TripInstruction

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            InstructionIcon(instruction: instruction, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(instruction.title)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityLabel(instruction.spokenTitle)
                DeadlineText(instruction: instruction)
                    .font(.footnote)
                    .lineLimit(1)
                if let detail = instruction.detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

#Preview("Lock Screen", as: .content, using: TripActivityAttributes(destination: "Office")) {
    TripLiveActivity()
} contentStates: {
    TripGlance(destination: "Office",
               instruction: TripInstruction(kind: .board, mode: .transit, title: "Board at Canal St", detail: "toward 96 St · on time",
                                            route: RouteLabel(name: "Q", colorHex: "FCCC0A", textColorHex: "000000"), deadline: .now + 190),
               arrival: .now + 1_800, arriveBy: .now + 2_040)
    TripGlance(destination: "Office",
               instruction: TripInstruction(kind: .travel, mode: .drive, title: "Drive to Metropark", detail: "Then NEC 8:42 AM · tight", deadline: .now + 600),
               arrival: .now + 3_600, arriveBy: .now + 3_100)
    TripGlance(destination: "Office",
               instruction: TripInstruction(kind: .ride, mode: .transit, title: "Exit at 57 St", detail: "3 stops · then walk to Office",
                                            route: RouteLabel(name: "Q", colorHex: "FCCC0A", textColorHex: "000000"), deadline: .now + 540),
               arrival: .now + 900)
}
