import CommuteCore
import SwiftUI
import WidgetKit

/// The trip in the Watch's Smart Stack, where iOS mirrors the Live Activity (there is no Watch app).
/// The Arrive By bar leads, as it does everywhere; the next step is the line under it:
///
///     On Time                −3 by 9:00
///     ━━━━━━━━━━━●━━━━━━━━━━━━━━━━━━━━━━━━━
///     [Q] Board at Canal St           3:10
///
/// With no arrival time to measure against, the expected arrival takes the bar's place.
struct WristActivityView: View {
    let glance: TripGlance
    let isStale: Bool

    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    private var instruction: TripInstruction { glance.instruction }
    private var isDimmed: Bool { isStale && !glance.isFinished }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let progress = glance.progress {
                header(progress)
                ArriveByTrack(progress: progress, height: 6, labels: .none)
            } else {
                arrivalHeader
            }
            step
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .opacity(isDimmed ? 0.6 : 1)
    }

    // MARK: The bar

    /// "Running Late" and "+7 by 9:00": how it stands, how far off, and the time to be there by.
    /// Late gets a filled chip, so it's what the eye lands on.
    private func header(_ progress: ArriveByProgress) -> some View {
        let isWarning = !progress.isFinal && (progress.standing == .slipping || progress.standing == .late)
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(progress.isFinal ? "Arrived" : progress.standing.label)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 2)
            HStack(spacing: 3) {
                Text(progress.isFinal ? progress.deltaDescription : progress.shortDelta)
                    .font(.system(.body, design: .rounded, weight: .bold))
                if !progress.isFinal {
                    Text("by \(progress.target.clockTime)")
                        .font(.system(.caption2, design: .rounded, weight: .semibold))
                        .opacity(0.8)
                }
            }
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(isWarning && !isLuminanceReduced ? .black : progress.standing.tint)
            .padding(.horizontal, isWarning ? 6 : 0)
            .background {
                if isWarning {
                    Capsule().fill(progress.standing.tint.opacity(isLuminanceReduced ? 0.35 : 1))
                }
            }
            .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(progress.isFinal
            ? "Arrived \(progress.deltaDescription)"
            : "\(progress.standing.label), \(progress.deltaDescription) for \(progress.target.clockTime)")
    }

    /// No time to be there by: when it gets there, as big as the bar would be.
    private var arrivalHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(glance.isFinished ? "Arrived \(glance.arrival.clockTime)" : "Arrive \(glance.arrival.clockTime)")
                .font(.system(.title3, design: .rounded, weight: .bold))
                .monospacedDigit()
            Spacer(minLength: 2)
            Text(glance.destination)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
    }

    // MARK: Under it

    /// The next step and the countdown to it, or why the card has stopped moving.
    @ViewBuilder
    private var step: some View {
        HStack(alignment: .center, spacing: 5) {
            if isDimmed {
                Label("Open Commute on iPhone", systemImage: "iphone")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if glance.isFinished {
                Image(systemName: "flag.checkered")
                    .font(.caption2.weight(.semibold))
                Text(glance.destination)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else {
                InstructionIcon(instruction: instruction, size: 16)
                Text(instruction.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .minimumScaleFactor(0.75)
                    .accessibilityLabel(instruction.spokenTitle)
                Spacer(minLength: 2)
                if let deadline = instruction.deadline {
                    Text(timerInterval: min(.now, deadline)...deadline, countsDown: true)
                        .font(.system(.footnote, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 44, alignment: .trailing)
                        .accessibilityLabel(instruction.deadlineLabel.map { "\($0) \(deadline.clockTime)" } ?? deadline.clockTime)
                }
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview("Smart Stack", traits: .fixedLayout(width: 184, height: 76)) {
    let q = RouteLabel(name: "Q", colorHex: "FCCC0A", textColorHex: "000000")
    ScrollView {
        VStack(spacing: 8) {
            ForEach(Array([
                TripGlance(destination: "Office",
                           instruction: TripInstruction(kind: .leave, mode: .drive, title: "Leave at 8:12", detail: "Drive to Metropark · 25 min", deadline: .now + 272),
                           arrival: .now + 3_000, arriveBy: .now + 3_300),
                TripGlance(destination: "Office",
                           instruction: TripInstruction(kind: .board, mode: .transit, title: "Board at Canal St", detail: "toward 96 St · on time", route: q, deadline: .now + 190),
                           arrival: .now + 1_800, arriveBy: .now + 1_380,
                           connections: ConnectionBoard(station: "Canal St", toward: "57 St", departures: [
                               .init(route: RouteLabel(name: "N", colorHex: "FCCC0A", textColorHex: "000000"), time: .now + 190, isRealtime: true),
                               .init(route: q, time: .now + 370, isRealtime: true, isPlanned: true),
                               .init(route: q, time: .now + 850),
                           ])),
                TripGlance(destination: "Office",
                           instruction: TripInstruction(kind: .ride, mode: .transit, title: "Exit at 57 St", detail: "3 stops · then walk to Office", route: q, deadline: .now + 540),
                           arrival: .now + 900),
                TripGlance(destination: "Office", instruction: TripInstruction(kind: .arrived, title: "You've Arrived"),
                           arrival: .now, arriveBy: .now + 240, isFinished: true),
            ].enumerated()), id: \.offset) { _, glance in
                WristActivityView(glance: glance, isStale: false)
                    .background(.gray.opacity(0.25), in: .rect(cornerRadius: 16))
            }
        }
    }
    .frame(width: 184)
}
