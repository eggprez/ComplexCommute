import CommuteCore
import GTFSKit
import MapKit
import SwiftUI

/// The trip in progress: what to do next, what's left, and what changed.
struct ActiveTripView: View {
    let planner: TripPlannerModel
    let onEdit: () -> Void
    let onDone: () -> Void

    var body: some View {
        List {
            if let trip = planner.active {
                // Re-render on a clock so countdowns stay honest between re-plans.
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    NextStepCard(trip: trip, now: context.date)
                }
                .listRowBackground(Color.accentColor.opacity(0.12))

                if let notice = trip.notice {
                    Section {
                        NoticeRow(notice: notice, arrival: trip.arrival, follow: planner.follow, dismiss: planner.dismissNotice)
                    }
                }

                if !trip.isFinished {
                    Section {
                        ForEach(trip.remainingLegs) { leg in
                            VStack(alignment: .leading, spacing: 10) {
                                LegRow(leg: leg)
                            }
                            .buttonStyle(.borderless)
                        }
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
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .task { await planner.followActiveTrip() }
        .onChange(of: planner.location.coordinate) { planner.locationDidChange() }
        // A glance at a phone in a cupholder or on a platform shouldn't need an unlock.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private var title: String {
        guard let trip = planner.active, !trip.isFinished else { return "Trip" }
        return "Arrive \(trip.arrival.formatted(date: .omitted, time: .shortened))"
    }

    @ViewBuilder
    private func controls(for trip: ActiveTrip) -> some View {
        if let leg = trip.currentLeg {
            Button("I'm at \(leg.to.name)", systemImage: "checkmark.circle") {
                withAnimation { planner.markArrived() }
                Task { await planner.refreshActiveTrip() }
            }
            if leg.mode == .transit, trip.hasBoarded, !leg.option.rides.isEmpty {
                Button("I Missed This Train", systemImage: "figure.wave") {
                    planner.markMissed()
                    Task { await planner.refreshActiveTrip() }
                }
            }
        }
        Button("Edit Trip", systemImage: "slider.horizontal.3", action: onEdit)
        Button("End Trip", systemImage: "xmark.circle", role: .destructive, action: onDone)
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
            let waitsToLeave = !trip.isMoving && leg.departure.timeIntervalSince(now) >= 60
            Text(waitsToLeave ? "Leave in \(leg.departure.timeIntervalSince(now).shortDuration)" : "\(leg.mode.label) to \(leg.to.name)")
                .font(.title2.weight(.bold))
            HStack {
                Label(waitsToLeave ? "\(leg.mode.label) to \(leg.to.name) · \(leg.duration.shortDuration)"
                                   : "Arrive \(leg.arrival.formatted(date: .omitted, time: .shortened))", systemImage: leg.mode.symbol)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Directions", systemImage: "arrow.triangle.turn.up.right.circle.fill") { openInMaps(leg) }
                    .labelStyle(.iconOnly)
                    .font(.title)
                    .buttonStyle(.borderless)
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
            RouteBadgeView(route: ride.badge)
                .scaleEffect(1.4)
                .padding(.horizontal, 4)
            if isAboard {
                Text("Exit at \(ride.alightStopName)")
            } else {
                Text("Board at \(ride.board.formatted(date: .omitted, time: .shortened))")
            }
        }
        .font(.title2.weight(.bold))

        if isAboard {
            Text("\(ride.alight.formatted(date: .omitted, time: .shortened)) · \(ride.stopCount) \(ride.stopCount == 1 ? "stop" : "stops") from \(ride.boardStopName)")
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
                    Text(ride.liveStatus)
                        .foregroundStyle(ride.isLate ? Color.orange : Color.green)
                }
            }
        }
    }

    private func openInMaps(_ leg: Leg) {
        let destination = MKMapItem(location: leg.to.coordinate.location, address: nil)
        destination.name = leg.to.name
        let mode = leg.mode == .drive ? MKLaunchOptionsDirectionsModeDriving : MKLaunchOptionsDirectionsModeWalking
        destination.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: mode])
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
