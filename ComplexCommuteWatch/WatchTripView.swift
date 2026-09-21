import CommuteCore
import SwiftUI

/// The trip under way on the phone: how it stands, what to do next, and the things only the rider can say.
struct WatchTripView: View {
    let trip: WatchTripState
    let phone: PhoneLink

    private var glance: TripGlance { trip.glance }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                standing
                instruction
                if trip.needsPhone, !glance.isFinished {
                    Label("Open Commute on your iPhone to keep this up to date.", systemImage: "iphone")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                notice
                actions
                if !trip.upcoming.isEmpty {
                    upcoming
                }
                Button(glance.isFinished ? "Done" : "End Trip", role: glance.isFinished ? nil : .destructive) {
                    Task { await phone.send(.endTrip) }
                }
                .padding(.top, 4)
            }
            .disabled(phone.busy != nil)
        }
        .navigationTitle(glance.destination)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The Arrive By bar, or just the arrival time for a trip with nothing to be on time for.
    private var standing: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let progress = glance.progress {
                HStack(spacing: 4) {
                    Image(systemName: progress.standing.symbol)
                        .foregroundStyle(progress.standing.tint)
                    Text(progress.isFinal ? "Arrived" : progress.standing.label)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    Text(progress.shortDelta)
                        .font(.footnote.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(progress.standing.tint)
                }
                ArriveByTrack(progress: progress, height: 10)
                Text("\(progress.deltaDescription) · by \(progress.target.clockTime)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text(glance.isFinished ? "Arrived" : "Arrive")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(glance.arrival, format: .dateTime.hour().minute())
                    .font(.system(.title2, design: .rounded, weight: .bold))
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((glance.progress?.standing.tint ?? .gray).opacity(0.2), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private var instruction: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                InstructionIcon(instruction: glance.instruction, size: 24)
                Text(glance.instruction.title)
                    .font(.headline)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(glance.instruction.spokenTitle)
            DeadlineText(instruction: glance.instruction)
                .font(.footnote)
            if let detail = glance.instruction.detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var notice: some View {
        if let faster = trip.faster {
            VStack(alignment: .leading, spacing: 4) {
                Label("Faster Option", systemImage: "bolt.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.green)
                HStack(spacing: 3) {
                    ForEach(Array(faster.routes.enumerated()), id: \.offset) { _, route in
                        RouteLabelBadge(route: route, height: 16)
                    }
                }
                Text("Arrive \(faster.arrival.formatted(date: .omitted, time: .shortened)), \(faster.saving.shortDuration) sooner.")
                    .font(.caption2)
                Button("Switch") { Task { await phone.send(.followFaster) } }
                    .tint(.green)
            }
        } else if let change = trip.planChange {
            VStack(alignment: .leading, spacing: 4) {
                Label("Plan Updated", systemImage: "arrow.triangle.branch")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(change >= 60 ? "You'll arrive \(change.shortDuration) later."
                     : change <= -60 ? "You'll arrive \((-change).shortDuration) sooner." : "Arrival time is about the same.")
                    .font(.caption2)
                Button("OK") { Task { await phone.send(.dismissNotice) } }
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if let place = trip.nextWaypoint {
            Button("I'm at \(place)", systemImage: "checkmark.circle") {
                Task { await phone.send(.markArrived) }
            }
        }
        if trip.canMarkMissed {
            Button("Missed This Train", systemImage: "figure.wave") {
                Task { await phone.send(.markMissed) }
            }
        }
    }

    private var upcoming: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Then")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(trip.upcoming.enumerated()), id: \.offset) { _, step in
                HStack(spacing: 5) {
                    if let route = step.route {
                        RouteLabelBadge(route: route, height: 16)
                    } else {
                        Image(systemName: step.mode.symbol)
                            .font(.caption2)
                            .frame(minWidth: 16)
                    }
                    Text(step.title)
                        .font(.caption2)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(step.time.clockTime)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.top, 2)
    }
}
