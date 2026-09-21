import CommuteCore
import Foundation
import Observation

enum DepartureChoice: Hashable {
    case now
    case at(Date)
    /// The rider has to be there by this time; the app works out when to leave.
    case arriveBy(Date)

    var target: Date? {
        if case .arriveBy(let date) = self { return date }
        return nil
    }
}

/// The trip currently being edited, planned and shown on the map.
@Observable
final class TripPlannerModel {
    enum Status: Equatable {
        case idle
        case waitingForLocation
        case failed(String)
    }

    var template = TripTemplate()
    /// Changing how the trip is planned changes which option is the one to take, so the old pick goes.
    var departure: DepartureChoice = .now {
        didSet {
            guard departure != oldValue else { return }
            selectedID = nil
            hasPickedOption = false
        }
    }
    var selectedID: Itinerary.ID?
    /// The rider chose an option themselves, so re-planning must stop moving it for them.
    private(set) var hasPickedOption = false

    private(set) var itineraries: [Itinerary] = []
    private(set) var tags: [Itinerary.ID: Set<ItineraryTag>] = [:]
    private(set) var status: Status = .idle
    private(set) var isPlanning = false
    private(set) var lastUpdated: Date?
    /// The trip being travelled, once the rider taps Start.
    private(set) var active: ActiveTrip? {
        didSet { onTripChange?() }
    }
    /// Position along the current drive or walk leg's turn-by-turn steps.
    private(set) var guidance: RouteProgress?
    /// Under way on a drive or walk leg (or due to be), as opposed to waiting for the time to leave.
    private(set) var isNavigating = false

    let location: LocationService
    let voice = VoiceGuide()
    let notifier: TripNotifier
    /// Where recorded connections go to be kept.
    var recordConnections: (([ConnectionRecord]) -> Void)?
    /// Anything about the trip in progress may have changed: the Live Activity, the Watch and the
    /// copy kept on disk all hang off this.
    var onTripChange: (() -> Void)?
    /// Follows the trip for as long as there is one, whatever is or isn't on screen.
    private var following: Task<Void, Never>?
    private let planner: ChainPlanner
    private var lastReroute = Date.distantPast

    /// How often "leave now" trips re-plan while on screen.
    static let refreshInterval: Duration = .seconds(30)
    /// Working back from an arrival time costs several passes of routing, and the answer moves slowly,
    /// so it is refreshed less eagerly.
    static let arriveByRefreshInterval: Duration = .seconds(120)
    /// A trip in progress re-plans more eagerly: a missed connection should show up fast.
    static let activeRefreshInterval: Duration = .seconds(20)
    /// Straying this far from the route asks for a new one right away, but not more often than `rerouteInterval`.
    static let offRouteMeters = 50.0
    static let rerouteInterval: TimeInterval = 8

    init(location: LocationService, resolver: any LegResolving, notifier: TripNotifier = TripNotifier()) {
        self.location = location
        self.notifier = notifier
        self.planner = ChainPlanner(resolver: resolver)
    }

    /// The rider taps an option: from here it is theirs, not the app's to keep changing.
    func select(_ itinerary: Itinerary) {
        selectedID = itinerary.id
        hasPickedOption = true
    }

    var selected: Itinerary? {
        itineraries.first { $0.id == selectedID } ?? itineraries.first
    }

    /// What the map draws: the rest of the trip in progress, or the option being considered.
    var displayedItinerary: Itinerary? {
        active.map { Itinerary(legs: $0.remainingLegs) } ?? selected
    }

    func start(_ template: TripTemplate, arrivingBy target: Date? = nil) {
        self.template = template
        departure = target.map(DepartureChoice.arriveBy) ?? .now
        hasPickedOption = false
        notifier.cancelLeaveNow()
        itineraries = []
        tags = [:]
        selectedID = nil
        status = .idle
        lastUpdated = nil
        endActiveTrip()
    }

    // MARK: Active trip

    /// Starts travelling the selected option. Returns false if there is nothing to start.
    @discardableResult
    func startActiveTrip() -> Bool {
        guard let selected else { return false }
        var resolved = template
        if let coordinate = location.coordinate {
            resolved.updateCurrentLocation(coordinate)
        }
        active = ActiveTrip(template: resolved, itinerary: selected, arriveBy: departure.target)
        updateGuidance()
        beginFollowing()
        // The reminder has done its job, and from here the trip screen is the thing to watch.
        notifier.cancelLeaveNow()
        notifier.reset()
        Task { await notifier.requestAuthorizationIfNeeded() }
        return active != nil
    }

    /// Sets, changes or clears the arrival time of the trip being travelled.
    func setArriveBy(_ target: Date?) {
        active?.arriveBy = target
        if active == nil, let target {
            departure = .arriveBy(target)
        }
    }

    /// Picks a trip back up after the app was closed under it.
    func resume(_ trip: ActiveTrip) {
        template = trip.template
        departure = trip.arriveBy.map(DepartureChoice.arriveBy) ?? .now
        active = trip
        updateGuidance()
        beginFollowing()
    }

    private func beginFollowing() {
        following?.cancel()
        following = Task { await followActiveTrip() }
    }

    func endActiveTrip() {
        following?.cancel()
        following = nil
        active = nil
        guidance = nil
        isNavigating = false
        voice.stop()
    }

    /// The steps being navigated: those of the current leg when it is a drive or a walk.
    var guidedLeg: Leg? {
        guard let leg = active?.currentLeg, !leg.option.steps.isEmpty else { return nil }
        return leg
    }

    private func updateGuidance() {
        guard let leg = guidedLeg, let coordinate = location.coordinate else {
            guidance = nil
            isNavigating = false
            return
        }
        guidance = RouteProgress(steps: leg.option.steps, location: coordinate)
        isNavigating = active?.isMoving == true || leg.departure.timeIntervalSinceNow < 60
        if let guidance, isNavigating {
            voice.announce(leg.option.steps[guidance.stepIndex], metersAway: guidance.metersToManeuver, mode: leg.mode)
        }
    }

    /// Stops the trip and hands what's left of it to the editor, starting from where the rider is now.
    func editRemainingTrip() {
        guard let trip = active else { return }
        let next = min(trip.currentSegment + 1, trip.template.waypoints.count - 1)
        let remaining = [.currentLocation()] + trip.template.waypoints[next...]
        let modes = Array(trip.template.modes[(next - 1)...])
        start(TripTemplate(waypoints: remaining, modes: modes))
    }

    func markArrived() {
        active?.markArrived(now: .now)
        storeRecords()
        updateGuidance()
    }

    func markMissed() {
        active?.markMissed(now: .now)
        storeRecords()
    }

    /// Hands anything the trip has learned to whoever is keeping it.
    private func storeRecords() {
        guard let drained = active?.drainRecords(), !drained.isEmpty else { return }
        recordConnections?(drained)
    }

    func dismissNotice() {
        active?.dismissNotice()
    }

    func follow(_ itinerary: Itinerary) {
        active?.follow(itinerary)
    }

    /// Tracks progress and keeps re-planning what's left until the trip ends or is called off.
    private func followActiveTrip() async {
        while !Task.isCancelled, let trip = active, !trip.isFinished {
            await refreshActiveTrip()
            try? await Task.sleep(for: Self.activeRefreshInterval)
        }
    }

    /// Cheap enough to run on every location fix: only checks whether the rider reached the next waypoint.
    func locationDidChange() {
        guard active != nil else { return }
        let changedLeg = active?.update(location: location.coordinate, now: .now) == true
        if changedLeg { storeRecords() }
        updateGuidance()
        let isOffRoute = (guidance?.metersOffRoute ?? 0) > Self.offRouteMeters && !isPlanning
            && Date.now.timeIntervalSince(lastReroute) > Self.rerouteInterval
        guard changedLeg || isOffRoute else { return }
        lastReroute = .now
        Task { await refreshActiveTrip() }
    }

    func refreshActiveTrip() async {
        active?.update(location: location.coordinate, now: .now)
        storeRecords()
        guard let request = active?.replanRequest(location: location.coordinate, now: .now) else { return }
        isPlanning = true
        defer { isPlanning = false }
        let planned = try? await planner.plan(request.template, departingAt: request.departure, canDelayDeparture: request.canDelayDeparture,
                                              isWaitingAtOrigin: request.isWaitingAtOrigin)
        guard !Task.isCancelled, let planned else { return }
        active?.apply(planned, for: request)
        announceNotice()
        updateGuidance()
        lastUpdated = .now
    }

    /// A plan worth switching to is worth a notification: the phone is usually in a pocket by now.
    private func announceNotice() {
        guard let trip = active, case .fasterOption(let faster) = trip.notice else { return }
        notifier.announceFasterOption(faster, saving: trip.arrival.timeIntervalSince(faster.arrival))
    }

    /// Plans once, then keeps re-planning from the live location until the calling task is cancelled.
    /// A fixed departure time is the one case with nothing to watch for.
    func planContinuously() async {
        repeat {
            await plan()
            try? await Task.sleep(for: departure.target == nil ? Self.refreshInterval : Self.arriveByRefreshInterval)
        } while !Task.isCancelled && !isFixedDeparture
    }

    private var isFixedDeparture: Bool {
        if case .at = departure { return true }
        return false
    }

    /// Plans a commute without disturbing the trip on screen, for the background refresh.
    /// - Returns: the option that leaves as late as it can and still arrives in time, or nil if the
    ///   rider's position isn't known well enough to plan from.
    func plan(_ template: TripTemplate, arrivingBy target: Date) async -> Itinerary? {
        var resolved = template
        if resolved.usesCurrentLocation {
            guard let coordinate = location.coordinate else { return nil }
            resolved.updateCurrentLocation(coordinate)
        }
        let planned = try? await planner.plan(resolved, arrivingBy: target, notBefore: .now)
        return planned?.first { $0.arrival <= target } ?? planned?.first
    }

    /// Keeps the "time to leave" reminder on the trip being planned, so it fires with the phone away.
    private func scheduleLeaveReminder() {
        guard active == nil, let target = departure.target, let selected, selected.arrival <= target else {
            if active != nil || departure.target == nil { notifier.cancelLeaveNow() }
            return
        }
        notifier.scheduleLeaveNow(at: selected.departure, for: template.waypoints.last?.name ?? "your trip", arriveBy: target)
    }

    func plan() async {
        guard template.isPlannable else {
            itineraries = []
            status = .idle
            return
        }

        var resolved = template
        if resolved.usesCurrentLocation {
            guard let coordinate = location.coordinate else {
                status = .waitingForLocation
                return
            }
            resolved.updateCurrentLocation(coordinate)
        }

        isPlanning = true
        defer { isPlanning = false }
        do {
            let planned: [Itinerary]
            switch departure {
            case .now:
                planned = try await planner.plan(resolved, departingAt: .now)
            case .at(let date):
                planned = try await planner.plan(resolved, departingAt: date)
            case .arriveBy(let target):
                planned = try await planner.plan(resolved, arrivingBy: target, notBefore: .now)
            }
            guard !Task.isCancelled else { return }
            itineraries = planned
            // Working back from an arrival time already puts the one to take first; ranking it again
            // by speed would bury the whole point of it.
            tags = departure.target == nil ? ChainPlanner.tags(for: planned) : [:]
            // Planning backwards from a time keeps recommending the latest safe departure as traffic
            // and trains move, unless the rider has picked one themselves.
            let follows = departure.target != nil && !hasPickedOption
            if follows || selectedID == nil || !planned.contains(where: { $0.id == selectedID }) {
                selectedID = planned.first?.id
            }
            status = .idle
            lastUpdated = .now
            scheduleLeaveReminder()
        } catch is CancellationError {
        } catch PlanningError.noRoute(let index) {
            let segment = resolved.segments[index]
            itineraries = []
            status = .failed("No \(segment.mode.label.lowercased()) route from \(segment.from.name) to \(segment.to.name).")
        } catch {
            // Keep showing the last good options through transient network failures.
            if itineraries.isEmpty {
                status = .failed(error.localizedDescription)
            }
        }
    }
}
