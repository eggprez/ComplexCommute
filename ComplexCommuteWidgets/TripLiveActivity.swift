import ActivityKit
import CommuteCore
import SwiftUI
import WidgetKit

/// The trip in progress, wherever the app isn't: Lock Screen, Dynamic Island, and the Watch's Smart Stack.
/// Everywhere, the Arrive By bar comes first and biggest; the next instruction and the departures from a
/// change are what's under it.
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
                    Group {
                        if let progress = glance.progress {
                            Text("\(progress.shortDelta) · by \(progress.target.clockTime)")
                                .foregroundStyle(tint)
                        } else {
                            Text(glance.destination)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let progress = glance.progress {
                            ArriveByTrack(progress: progress, height: 10, labels: .none)
                        }
                        InstructionRow(instruction: glance.instruction, showsDetail: glance.connections == nil)
                        if let board = glance.connections {
                            ConnectionBoardRow(board: board, badgeHeight: 16, showsStation: false)
                        }
                        TripActionsRow(glance: glance)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                // The bar in miniature; the step's icon only when there's no arrival time to measure against.
                if let progress = glance.progress {
                    ArriveByTrack(progress: progress, height: 5, labels: .none)
                        .frame(width: 40)
                        .padding(.leading, 2)
                } else {
                    InstructionIcon(instruction: glance.instruction, size: 20)
                        .foregroundStyle(tint)
                }
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
            WristActivityView(glance: glance, isStale: isStale)
                .activityBackgroundTint(glance.progress.map { $0.standing.tint.opacity(0.22) })
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
                        .font(glance.progress == nil ? .system(.title3, design: .rounded, weight: .bold) : .headline)
                    Spacer(minLength: 0)
                    Group {
                        if isStale, !glance.isFinished {
                            Text("Open Commute to update")
                                .foregroundStyle(.secondary)
                        } else if let progress = glance.progress {
                            Text("\(progress.deltaDescription) · by \(progress.target.clockTime)")
                                .foregroundStyle(progress.standing.tint)
                        } else {
                            Text(glance.destination)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                }
                if let progress = glance.progress {
                    ArriveByTrack(progress: progress, height: 14)
                }
            }
            // Room is tight on the Lock Screen: the departures stand in for the instruction's detail, which
            // they say more usefully ("then Q" becomes when each Q goes).
            InstructionRow(instruction: glance.instruction, showsDetail: glance.connections == nil)
            if let board = glance.connections {
                ConnectionBoardRow(board: board)
            }
            TripActionsRow(glance: glance)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
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

/// The manual backup to motion and geofences: say you're at the station or on the train, or answer the
/// app's question about which train, straight from the Lock Screen.
private struct TripActionsRow: View {
    let glance: TripGlance

    var body: some View {
        if !glance.actions.isEmpty, !glance.isFinished {
            HStack(spacing: 8) {
                if let prompt = glance.prompt {
                    Text(prompt)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
                ForEach(glance.actions, id: \.self) { action in
                    Button(intent: TripActionIntent(action)) {
                        Label(action.title, systemImage: action.symbol)
                            .font(.footnote.weight(.semibold))
                            .lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(action == .missed || action == .rejectTrain ? .secondary : .accentColor)
                }
            }
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
    var showsDetail = true

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            InstructionIcon(instruction: instruction, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(instruction.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityLabel(instruction.spokenTitle)
                DeadlineText(instruction: instruction)
                    .font(.footnote)
                    .lineLimit(1)
                if showsDetail, let detail = instruction.detail {
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
               instruction: TripInstruction(kind: .ride, mode: .transit, title: "Exit at Canal St", detail: "2 stops · then Q",
                                            route: RouteLabel(name: "6", colorHex: "00933C", textColorHex: "FFFFFF"), deadline: .now + 240),
               arrival: .now + 1_500, arriveBy: .now + 1_560,
               connections: ConnectionBoard(station: "Canal St", toward: "57 St", departures: [
                   .init(route: RouteLabel(name: "N", colorHex: "FCCC0A", textColorHex: "000000"), time: .now + 360, isRealtime: true),
                   .init(route: RouteLabel(name: "Q", colorHex: "FCCC0A", textColorHex: "000000"), time: .now + 540, isRealtime: true, isPlanned: true),
                   .init(route: RouteLabel(name: "Q", colorHex: "FCCC0A", textColorHex: "000000"), time: .now + 1_020),
               ]))
    TripGlance(destination: "Office",
               instruction: TripInstruction(kind: .ride, mode: .transit, title: "Exit at 57 St", detail: "3 stops · then walk to Office",
                                            route: RouteLabel(name: "Q", colorHex: "FCCC0A", textColorHex: "000000"), deadline: .now + 540),
               arrival: .now + 900)
}
