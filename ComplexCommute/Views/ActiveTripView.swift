import CommuteCore
import GTFSKit
import SwiftUI

/// The trip in progress: what to do next, what's left, and what changed.
struct ActiveTripView: View {
    let planner: TripPlannerModel
    let onEdit: () -> Void
    let onDone: () -> Void

    @Environment(SheetRouter.self) private var router
    @State private var isSettingTarget = false
    @State private var isPickingTrain = false
    @State private var target = Date.now.addingTimeInterval(3_600)

    var body: some View {
        List {
            if let trip = planner.active {
                // Re-render on a clock so countdowns stay honest between re-plans.
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    NextStepCard(trip: trip, now: context.date)
                }
                .listRowBackground(Color.accentColor.opacity(0.12))

                // The turns themselves are left to a maps app; this one keeps following from behind it.
                if let target = trip.directionsTarget(at: .now) {
                    DirectionsButton(destination: target.destination, mode: target.mode)
                        .listRowBackground(Color.accentColor.opacity(0.12))
                }

                if !trip.isFinished {
                    Section {
                        TimelineView(.periodic(from: .now, by: 15)) { context in
                            TrainCheckSection(trip: trip, now: context.date, planner: planner) { isPickingTrain = true }
                        }
                    }
                }

                if let notice = trip.notice {
                    Section {
                        NoticeRow(notice: notice, arrival: trip.arrival, follow: planner.follow, dismiss: planner.dismissNotice)
                    }
                }

                if !trip.isFinished {
                    Section {
                        TripTimeline(legs: trip.remainingLegs)
                    } header: {
                        HStack {
                            Text("Remaining")
                            if planner.isPlanning {
                                ProgressView()
                                    .controlSize(.mini)
                            }
                        }
                    } footer: {
                        if let updated = planner.lastUpdated {
                            Text("Updated \(updated, format: .relative(presentation: .named)). Re-plans from your location as you go.")
                        }
                    }

                    Section {
                        controls(for: trip)
                    }
                }
            }
        }
        // Like Maps, the top of the sheet is the trip's vital signs, and all that shows when the sheet is pulled down.
        .safeAreaInset(edge: .top, spacing: 0) {
            if let trip = planner.active {
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    VStack(spacing: 0) {
                        // How the trip is doing against the time it has to be done by, above everything else.
                        if let progress = trip.arriveByProgress(now: context.date) {
                            ArriveByBar(progress: progress) {
                                target = progress.target
                                isSettingTarget = true
                            }
                            // Clear of the sheet's grabber above and of the numbers below.
                            .padding(.horizontal, 16)
                            .padding(.top, 22)
                        }
                        TripSummaryBar(trip: trip, now: context.date, onEnd: onDone)
                    }
                    // Opaque, and the sheet's own color, so the list neither shows through nor looks like a second panel.
                    .background(Color(.systemGroupedBackground))
                }
            }
        }
        .sheet(isPresented: $isPickingTrain) {
            TrainPickerView(planner: planner)
        }
        .sheet(isPresented: $isSettingTarget) {
            ArriveByEditor(target: $target, hasTarget: planner.active?.arriveBy != nil) { chosen in
                planner.setArriveBy(chosen)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        // A glance at a phone in a cupholder or on a platform shouldn't need an unlock.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    @ViewBuilder
    private func controls(for trip: ActiveTrip) -> some View {
        if trip.canMarkLeaving {
            Button("I'm Leaving Now", systemImage: "figure.walk.departure") {
                withAnimation { planner.markLeaving() }
                Task { await planner.refreshActiveTrip() }
            }
        }
        if let leg = trip.currentLeg {
            Button("I'm at \(leg.to.name)", systemImage: "checkmark.circle") {
                withAnimation { planner.markArrived() }
                Task { await planner.refreshActiveTrip() }
            }
            if leg.mode == .transit, !trip.hasBoarded, let station = trip.currentRide(at: .now)?.stops.first?.station {
                Button("Departures at \(station.name)", systemImage: "clock") { router.station = station }
            }
            if leg.mode == .transit, trip.hasBoarded, !leg.option.rides.isEmpty {
                Button("I Missed This Train", systemImage: "figure.wave") {
                    planner.markMissed()
                    Task { await planner.refreshActiveTrip() }
                }
            }
        }
        if trip.arriveBy == nil {
            Button("Set Arrival Time", systemImage: "target") {
                target = max(trip.arrival, .now)
                isSettingTarget = true
            }
        }
        Button("Edit Trip", systemImage: "slider.horizontal.3", action: onEdit)
    }
}

/// Setting, changing or dropping the time the rider has to be there, without leaving the trip.
private struct ArriveByEditor: View {
    @Binding var target: Date
    let hasTarget: Bool
    let onSave: (Date?) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Arrive By", selection: $target, displayedComponents: [.hourAndMinute])
                } footer: {
                    Text("The bar at the top of the trip tracks how you're doing against this time.")
                }
                if hasTarget {
                    Section {
                        Button("Remove Arrival Time", systemImage: "xmark.circle", role: .destructive) {
                            onSave(nil)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Arrive By")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onSave(target)
                        dismiss()
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }
}

/// Arrival time and minutes to go, with the way out: the strip Maps keeps on screen while navigating.
/// While driving or walking it counts down the leg under way, and names the train that leg is meant to catch.
private struct TripSummaryBar: View {
    let trip: ActiveTrip
    let now: Date
    let onEnd: () -> Void

    var body: some View {
        let leg = trip.currentLeg
        let isGuided = leg.map { $0.mode != .transit } ?? false
        let arrival = (isGuided ? leg?.arrival : nil) ?? trip.arrival

        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                stat(arrival.clockTime, "arrival")
                if !trip.isFinished {
                    stat("\(max(1, Int((arrival.timeIntervalSince(now) / 60).rounded())))", "min")
                }
                Spacer(minLength: 0)
                Button(trip.isFinished ? "Done" : "End", action: onEnd)
                    .font(.headline)
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .tint(trip.isFinished ? Color.accentColor : Color.red)
                    .accessibilityLabel(trip.isFinished ? "Done" : "End Trip")
            }
            if let leg, !trip.isFinished {
                destinationLine(for: leg)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stat(_ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.system(.title2, design: .rounded, weight: .bold))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(unit)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func destinationLine(for leg: Leg) -> some View {
        HStack(spacing: 5) {
            if leg.mode == .transit {
                Text("to \(trip.template.waypoints.last?.name ?? leg.to.name)")
            } else {
                Text("to \(leg.to.name)")
                if let ride = trip.connection?.ride {
                    Text("· then")
                    RouteBadgeView(route: ride.badge)
                    Text(ride.board.clockTime)
                }
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

/// Opens the rider's maps app with directions to wherever this part of the trip is headed. A tap uses the
/// app they used last; holding it offers the other.
struct DirectionsButton: View {
    let destination: Waypoint
    let mode: TravelMode

    @AppStorage(DirectionsApp.key) private var app = DirectionsApp.appleMaps

    var body: some View {
        Menu {
            ForEach(DirectionsApp.allCases) { choice in
                Button("Open in \(choice.name)") {
                    app = choice
                    choice.open(to: destination, mode: mode)
                }
            }
        } label: {
            Label("Directions in \(app.name)", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                .font(.headline)
        } primaryAction: {
            app.open(to: destination, mode: mode)
        }
        .accessibilityHint("To \(destination.name). Commute keeps following your trip.")
    }
}

private struct NextStepCard: View {
    let trip: ActiveTrip
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let leg = trip.currentLeg {
                step(for: leg)
            } else {
                Label("You've Arrived", systemImage: "flag.checkered")
                    .font(.title2.weight(.bold))
                Text(trip.template.waypoints.last?.name ?? "")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func step(for leg: Leg) -> some View {
        switch leg.mode {
        case .drive, .walk:
            // The turns are in the maps app; what the sheet adds is why the rider is going there.
            let waitsToLeave = !trip.isMoving && leg.departure.timeIntervalSince(now) >= 60
            Label(waitsToLeave ? "Leave in \(leg.departure.timeIntervalSince(now).shortDuration)" : "\(leg.mode.label) to \(leg.to.name)",
                  systemImage: leg.mode.symbol)
                .font(.title3.weight(.bold))
            if waitsToLeave {
                Text("\(leg.mode.label) to \(leg.to.name) · \(leg.duration.shortDuration)")
                    .foregroundStyle(.secondary)
            }
            if let (ride, spare) = trip.connection {
                HStack(spacing: 6) {
                    RouteBadgeView(route: ride.badge, size: .regular)
                    Text("\(ride.board, format: .dateTime.hour().minute())\(ride.headsign.map { " to \($0)" } ?? "")")
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(spare >= 60 ? "\(spare.shortDuration) to spare" : "Tight")
                        .fontWeight(.semibold)
                        .foregroundStyle(spare >= 120 ? Color.goodText : Color.warningText)
                }
                .font(.subheadline)
            }
        case .transit:
            if let ride = trip.currentRide(at: now) {
                rideStep(ride, in: leg)
            } else {
                Text("Transit to \(leg.to.name)")
                    .font(.title2.weight(.bold))
                Text("Arrive about \(leg.arrival.formatted(date: .omitted, time: .shortened))")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func rideStep(_ ride: Ride, in leg: Leg) -> some View {
        let isAboard = trip.hasBoarded && now >= ride.board
        HStack(spacing: 8) {
            RouteBadgeView(route: ride.badge, size: .large)
            if isAboard {
                Text("Exit at \(ride.alightStopName)")
            } else {
                Text("Board at \(ride.board.formatted(date: .omitted, time: .shortened))")
            }
        }
        .font(.title2.weight(.bold))

        if isAboard {
            Text("Arrives \(ride.alight.formatted(date: .omitted, time: .shortened)) · \(ride.stopCount) \(ride.stopCount == 1 ? "stop" : "stops") from \(ride.boardStopName)")
                .foregroundStyle(.secondary)
        } else {
            let wait = ride.board.timeIntervalSince(now)
            HStack(spacing: 4) {
                Text("\(ride.boardStopName)\(ride.headsign.map { " · toward \($0)" } ?? "")")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text(wait >= 60 ? "in \(wait.shortDuration)" : "now")
                    .fontWeight(.semibold)
                if ride.isRealtime {
                    Text("· \(ride.liveStatus)")
                        .foregroundStyle(ride.isLate ? Color.warningText : Color.goodText)
                }
            }
        }
    }
}

private struct NoticeRow: View {
    let notice: ActiveTrip.Notice
    let arrival: Date
    let follow: (Itinerary) -> Void
    let dismiss: () -> Void

    var body: some View {
        switch notice {
        case .planChanged(let previousArrival):
            let delta = arrival.timeIntervalSince(previousArrival)
            HStack {
                Label {
                    Text("Plan Updated")
                        .font(.headline)
                    Text(delta >= 60 ? "Your connection changed. You'll arrive \(delta.shortDuration) later."
                         : delta <= -60 ? "Your connection changed. You'll arrive \((-delta).shortDuration) sooner."
                         : "Your connection changed. Arrival time is about the same.")
                } icon: {
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("Dismiss", systemImage: "xmark", action: dismiss)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
        case .fasterOption(let itinerary):
            HStack {
                Label {
                    Text("Faster Option")
                        .font(.headline)
                    Text("Arrive \(itinerary.arrival.formatted(date: .omitted, time: .shortened)), \(arrival.timeIntervalSince(itinerary.arrival).shortDuration) sooner.")
                    HStack(spacing: 4) {
                        ForEach(Array(itinerary.legs.flatMap(\.option.rides).enumerated()), id: \.offset) { _, ride in
                            RouteBadgeView(route: ride.badge)
                        }
                    }
                } icon: {
                    Image(systemName: "bolt.fill")
                        .foregroundStyle(.green)
                }
                Spacer()
                Button("Switch") { follow(itinerary) }
                    .buttonStyle(.bordered)
            }
        }
    }
}

// MARK: - Which train

/// Which train the rider is on, why the app thinks so, and the way to put it right: the manual backup to
/// matching the rider's location against where each train is.
struct TrainCheckSection: View {
    let trip: ActiveTrip
    let now: Date
    let planner: TripPlannerModel
    let pickTrain: () -> Void

    var body: some View {
        if let suggestion = trip.suggestedTrain {
            suggestionRow(suggestion.ride)
        } else if trip.isAskingAboutTrain {
            movingRow
        } else if let leg = trip.currentLeg {
            if leg.mode == .transit, trip.hasBoarded, let ride = trip.currentRide(at: now), now >= ride.board {
                aboardRow(ride)
            } else if leg.mode == .transit {
                Button("I'm On a Train", systemImage: "tram.fill", action: pickTrain)
            } else if trip.connection != nil {
                // The drive or walk may have ended without the app seeing it: a garage, a dead zone, a fast platform.
                Button("I'm Already on the Train", systemImage: "tram.fill", action: pickTrain)
            }
        }
    }

    private func suggestionRow(_ ride: Ride) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                RouteBadgeView(route: ride.badge, size: .regular)
                VStack(alignment: .leading, spacing: 2) {
                    Text("On the \(ride.board.clockTime)\(ride.headsign.map { " to \($0)" } ?? "")?")
                        .font(.headline)
                    Text("Your location matches this train. Arrive \(ride.alightStopName) \(ride.alight.clockTime).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Yes") { withAnimation { planner.acceptSuggestedTrain() } }
                    .buttonStyle(.borderedProminent)
                Button("Different Train") {
                    planner.rejectSuggestedTrain()
                    pickTrain()
                }
                .buttonStyle(.bordered)
                Button("Not Yet") { planner.rejectSuggestedTrain() }
                    .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }

    /// Motion or leaving the station says the rider is on a train, but the planned one wasn't due.
    private var movingRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("On a Train?")
                        .font(.headline)
                    Text("You've started moving from the station, but your planned train isn't due yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "figure.walk.motion")
                    .foregroundStyle(.orange)
            }
            HStack {
                Button("Which Train?", action: pickTrain)
                    .buttonStyle(.borderedProminent)
                Button("Not Yet") { planner.dismissTrainQuestion() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }

    private func aboardRow(_ ride: Ride) -> some View {
        HStack(spacing: 8) {
            Image(systemName: trip.boardedBy?.symbol ?? "clock")
                .foregroundStyle(trip.boardedBy == .schedule ? Color.secondary : Color.green)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("On the \(ride.board.clockTime)")
                    RouteBadgeView(route: ride.badge)
                }
                .font(.subheadline.weight(.semibold))
                Text(trip.boardedBy?.explanation ?? "")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if trip.boardedBy == .schedule || trip.boardedBy == .movement || trip.boardedBy == .riderAboard {
                Button("Confirm") {
                    planner.board(ride, segment: trip.currentSegment, rideIndex: trip.ridingIndex(at: now))
                }
                .buttonStyle(.bordered)
            }
            Button("Change", action: pickTrain)
                .buttonStyle(.borderless)
        }
        .accessibilityElement(children: .contain)
    }
}

extension BoardingEvidence {
    var symbol: String {
        switch self {
        case .schedule: "clock"
        case .movement: "figure.walk.motion"
        case .riderAboard: "hand.raised.fill"
        case .location: "location.fill"
        case .rider: "checkmark.circle.fill"
        }
    }

    var explanation: String {
        switch self {
        case .schedule: "Assumed from the schedule. Confirm it so times follow your train."
        case .movement: "You moved off from the station as it was due. Confirm it so times follow your train."
        case .riderAboard: "You said you're aboard. Your location will pick out the train, or confirm it here."
        case .location: "Matched to your location. Times follow this train."
        case .rider: "Confirmed by you. Times follow this train."
        }
    }
}

/// Every train going the rider's way around now, to say which one they're on.
struct TrainPickerView: View {
    let planner: TripPlannerModel

    @Environment(\.dismiss) private var dismiss
    @State private var choices: (segment: Int, rideIndex: Int, planned: Ride, trains: [Ride])?
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            List {
                if let choices {
                    Section {
                        ForEach(choices.trains, id: \.trip) { ride in
                            Button {
                                planner.board(ride, segment: choices.segment, rideIndex: choices.rideIndex)
                                dismiss()
                            } label: {
                                TrainChoiceRow(ride: ride, isPlanned: ride.trip == choices.planned.trip)
                            }
                            .tint(.primary)
                        }
                    } header: {
                        Text("From \(choices.planned.boardStopName) toward \(choices.planned.alightStopName)")
                    } footer: {
                        Text("Arrival times, and everything after this train, will follow the one you pick.")
                    }
                } else if !isLoading {
                    ContentUnavailableView("No Trains Found", systemImage: "tram",
                                           description: Text("There's no schedule for this part of the trip to pick a train from."))
                }
            }
            .overlay {
                if isLoading { ProgressView() }
            }
            .navigationTitle("Which Train?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                let found = await planner.trainChoices()
                choices = found.flatMap { $0.trains.isEmpty ? nil : $0 }
                isLoading = false
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct TrainChoiceRow: View {
    let ride: Ride
    let isPlanned: Bool

    var body: some View {
        let hasLeft = ride.board <= .now
        HStack(spacing: 10) {
            RouteBadgeView(route: ride.badge, size: .regular)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(ride.board.clockTime)
                        .font(.headline)
                        .monospacedDigit()
                    if isPlanned {
                        Text("Planned")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Text("\(ride.headsign.map { "to \($0) · " } ?? "")arrives \(ride.alight.clockTime)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(hasLeft ? "left \(Date.now.timeIntervalSince(ride.board).shortDuration) ago" : ride.isRealtime ? ride.liveStatus : "scheduled")
                .font(.footnote)
                .foregroundStyle(ride.isLate ? Color.warningText : Color.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
