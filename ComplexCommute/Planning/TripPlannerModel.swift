import CommuteCore
import Foundation
import Observation
import TransitRouting

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
        didSet {
            // Answered, settled by the location, or the ride is over: however it went, the question is done with.
            if oldValue?.trainQuestion != nil, active?.trainQuestion == nil { notifier.withdrawWhichTrain() }
            onTripChange?()
        }
    }

    let location: LocationService
    let notifier: TripNotifier
    /// Where recorded connections go to be kept.
    var recordConnections: (([ConnectionRecord]) -> Void)?
    /// Anything about the trip in progress may have changed: the Live Activity (and with it the Watch)
    /// and the copy kept on disk all hang off this.
    var onTripChange: (() -> Void)?
    /// Follows the trip for as long as there is one, whatever is or isn't on screen.
    private var following: Task<Void, Never>?
    private let planner: ChainPlanner
    /// Finds which train the rider is on, and where every train going their way is.
    let trains: TransitPlanner?
    /// Recent fixes, for matching against where each train was. Underground there may be long gaps between them.
    private var recentFixes: [LocationFix] = []
    private var lastTrainCheck = Date.distantPast
    private var trainCheck: Task<Void, Never>?

    /// Fixes older than this say nothing about the train the rider is on now.
    static let fixMemory: TimeInterval = 8 * 60
    static let fixSpacing: TimeInterval = 5
    /// Matching runs on location changes, but no more often than this.
    static let trainCheckInterval: TimeInterval = 8

    /// How often "leave now" trips re-plan while on screen.
    static let refreshInterval: Duration = .seconds(30)
    /// Working back from an arrival time costs several passes of routing, and the answer moves slowly,
    /// so it is refreshed less eagerly.
    static let arriveByRefreshInterval: Duration = .seconds(120)
    /// A trip in progress re-plans more eagerly: a missed connection should show up fast.
    static let activeRefreshInterval: Duration = .seconds(20)
    /// Coming up on a boarding or on getting off, more eagerly still: these are the minutes a plan can change in.
    static let decisionRefreshInterval: Duration = .seconds(8)
    private var isRefreshing = false
    private var needsAnotherRefresh = false

    init(location: LocationService, resolver: any LegResolving, notifier: TripNotifier = TripNotifier(), trains: TransitPlanner? = nil) {
        self.location = location
        self.notifier = notifier
        self.planner = ChainPlanner(resolver: resolver)
        self.trains = trains
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

    /// The ride whose trains the map follows: the one the rider is on or heading for, or the first of the option picked.
    var trackedRide: Ride? {
        if let trip = active {
            guard let leg = trip.currentLeg else { return nil }
            return leg.mode == .transit ? trip.currentRide(at: .now) : trip.connection?.ride
        }
        return selected?.legs.first { $0.mode == .transit }?.option.rides.first
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
        var trip = ActiveTrip(template: resolved, itinerary: selected, arriveBy: departure.target)
        // Leaving now with no time to be there by: the arrival this plan promises becomes the one to keep.
        if case .now = departure { trip?.holdToPlannedArrival() }
        active = trip
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
        departure = trip.statedArriveBy.map(DepartureChoice.arriveBy) ?? .now
        active = trip
        beginFollowing()
    }

    private func beginFollowing() {
        following?.cancel()
        following = Task { await followActiveTrip() }
    }

    func endActiveTrip() {
        following?.cancel()
        following = nil
        trainCheck?.cancel()
        trainCheck = nil
        recentFixes = []
        active = nil
    }

    /// Stops the trip and hands what's left of it to the editor, starting from where the rider is now.
    func editRemainingTrip() {
        guard let trip = active else { return }
        let next = min(trip.currentSegment + 1, trip.template.waypoints.count - 1)
        let remaining = [.currentLocation()] + trip.template.waypoints[next...]
        let modes = Array(trip.template.modes[(next - 1)...])
        start(TripTemplate(waypoints: remaining, modes: modes, excludedFeedIDs: trip.template.excludedFeedIDs))
    }

    /// The rider set out ahead of the time the plan had them leaving: plan the rest from now.
    func markLeaving() {
        active?.markLeaving()
    }

    func markArrived() {
        active?.markArrived(now: .now)
        storeRecords()
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

    /// The rider picked one of the ways onward, in the app or from the Live Activity.
    func choose(_ branch: String) {
        active?.choose(branch: branch)
        storeRecords()
        Task { await refreshActiveTrip() }
    }

    // MARK: Geofences and the Lock Screen

    /// A station geofence was crossed, possibly with the app woken just to hear it.
    func crossed(_ id: String, entered: Bool, at date: Date) {
        guard active != nil else { return }
        let movedOn = active?.crossed(id, entered: entered, now: date) == true
        storeRecords()
        if movedOn { Task { await refreshActiveTrip() } }
    }

    /// The rider says they're aboard, without saying which vehicle: location matching can still tell.
    func markAboard() {
        active?.markAboard()
        storeRecords()
        Task { await refreshActiveTrip() }
    }

    /// A button on the Live Activity.
    func perform(_ action: TripAction) {
        switch action {
        case .arrived:
            markArrived()
            Task { await refreshActiveTrip() }
        case .aboard:
            markAboard()
        case .missed:
            markMissed()
            Task { await refreshActiveTrip() }
        }
    }

    // MARK: Which train

    /// The rider answered which of two trains they're on, in the app or from the notification.
    func answerTrainQuestion(_ option: Int) {
        active?.answerTrainQuestion(option)
        storeRecords()
        Task { await refreshActiveTrip() }
    }

    /// The rider picked the train they're on themselves.
    func board(_ ride: Ride, segment: Int, rideIndex: Int) {
        active?.board(ride, segment: segment, rideIndex: rideIndex, evidence: .rider)
        storeRecords()
        Task { await refreshActiveTrip() }
    }

    /// The ride the rider could be on or about to be on, and the trains going its way around now, for them to pick from.
    func trainChoices() async -> (segment: Int, rideIndex: Int, planned: Ride, trains: [Ride])? {
        guard let trip = active, let trains else { return nil }
        let segment: Int
        let index: Int
        if trip.currentLeg?.mode == .transit {
            segment = trip.currentSegment
            index = trip.ridingIndex(at: .now)
        } else {
            segment = trip.currentSegment + 1
            index = 0
        }
        guard segment < trip.legs.count, index < trip.legs[segment].option.rides.count else { return nil }
        let planned = trip.legs[segment].option.rides[index]
        var found = await trains.trains(like: planned)
        // The other way onward leaves from the same place: its vehicles are just as likely the one boarded.
        for branch in trip.branches where branch.segment == segment && branch.rideIndex == index {
            for ride in await trains.trains(like: branch.ride) where !found.contains(where: { $0.trip == ride.trip }) {
                found.append(ride)
            }
        }
        return (segment, index, planned, found.sorted { $0.board < $1.board })
    }

    /// Where each train going the way of the ride the rider is on or heading for is right now.
    func vehicles(along ride: Ride) async -> [VehicleEstimate] {
        await trains?.vehicles(along: ride) ?? []
    }

    /// Matches recent fixes against where each train going the rider's way was, and takes what that finds.
    private func checkTrain() async {
        guard let trains, let watch = active?.ridesToWatch(at: .now) else { return }
        let now = Date.now
        recentFixes.removeAll { now.timeIntervalSince($0.time) > Self.fixMemory }
        guard !recentFixes.isEmpty else { return }
        lastTrainCheck = now
        guard let match = await trains.matchTrain(for: watch.rides, fixes: recentFixes, leftStation: active?.leftStationAt, at: now),
              !Task.isCancelled else { return }
        let before = active?.currentLeg?.option.rides
        let asked = active?.trainQuestion
        active?.apply(match, segment: watch.segment, now: now)
        storeRecords()
        if let question = active?.trainQuestion, question != asked {
            notifier.askWhichTrain(question.options)
        }
        // Now on a different train than was shown: everything after it moves with it.
        if active?.currentLeg?.option.rides != before { await refreshActiveTrip() }
    }

    /// Fresh times for the train the rider is on: the one thing that decides when everything after it happens.
    private func refreshBoardedRide() async {
        guard let trains, let trip = active, trip.hasBoarded, trip.currentLeg?.mode == .transit,
              let ride = trip.currentRide(at: .now), ride.trip != nil,
              let live = await trains.live(ride), !Task.isCancelled else { return }
        active?.refreshRide(live)
    }

    /// Tracks progress and keeps re-planning what's left until the trip ends or is called off.
    private func followActiveTrip() async {
        while !Task.isCancelled, let trip = active, !trip.isFinished {
            await refreshActiveTrip()
            let isClose = active?.isNearDecision(location: location.coordinate, now: .now) ?? false
            try? await Task.sleep(for: isClose ? Self.decisionRefreshInterval : Self.activeRefreshInterval)
        }
    }

    /// Cheap enough to run on every location fix: only checks whether the rider reached the next waypoint.
    func locationDidChange() {
        guard active != nil else { return }
        // The turns are another app's business now; here a fix only matters when it ends a leg. Wherever the
        // rider has strayed to, the regular re-plan measures the rest of the trip from there.
        // One fix every few seconds is plenty to tell trains apart, and keeps matching cheap.
        if let fix = location.fix, recentFixes.last.map({ fix.time.timeIntervalSince($0.time) >= Self.fixSpacing }) ?? true {
            recentFixes.append(fix)
        }
        if trainCheck == nil, Date.now.timeIntervalSince(lastTrainCheck) >= Self.trainCheckInterval {
            trainCheck = Task {
                let segment = active?.currentSegment
                await checkTrain()
                trainCheck = nil
                // Catching up on a drive the app didn't see end is a change of leg like any other.
                if active?.currentSegment != segment { await refreshActiveTrip() }
            }
        }
        let before = active.map(Stage.init)
        active?.update(fix: location.fix, now: .now)
        // Reaching a station, getting on or off, setting out ahead of time: each changes what the rest of the trip
        // can be, so each is worth a re-plan there and then rather than at the next tick.
        guard active.map(Stage.init) != before else { return }
        storeRecords()
        Task { await refreshActiveTrip() }
    }

    /// Where the trip stands, as far as re-planning cares.
    private struct Stage: Equatable {
        let segment: Int
        let hasBoarded: Bool
        let rides: Int
        let isMoving: Bool

        init(_ trip: ActiveTrip) {
            segment = trip.currentSegment
            hasBoarded = trip.hasBoarded
            rides = trip.currentLeg?.option.rides.count ?? 0
            isMoving = trip.isMoving
        }
    }

    /// One re-plan at a time: asked again while one is under way, it runs once more when that one is done,
    /// so the last word is always planned from the latest state.
    func refreshActiveTrip() async {
        guard !isRefreshing else {
            needsAnotherRefresh = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            needsAnotherRefresh = false
            await planActiveTrip()
        } while needsAnotherRefresh && !Task.isCancelled
    }

    private func planActiveTrip() async {
        active?.update(fix: location.fix, now: .now)
        storeRecords()
        if trainCheck == nil { await checkTrain() }
        await refreshBoardedRide()
        guard let request = active?.replanRequest(location: location.coordinate, now: .now) else { return }
        isPlanning = true
        defer { isPlanning = false }
        let planned = try? await planner.plan(request.template, departingAt: request.departure, canDelayDeparture: request.canDelayDeparture,
                                              isWaitingAtOrigin: request.isWaitingAtOrigin)
        guard !Task.isCancelled, let planned else { return }
        active?.apply(planned, for: request)
        announceNotice()
        lastUpdated = .now
    }

    /// A plan worth switching to is worth a notification: the phone is usually in a pocket by now.
    private func announceNotice() {
        guard let trip = active else { return }
        switch trip.notice {
        case .fasterOption(let faster):
            notifier.announceFasterOption(faster, saving: trip.arrival.timeIntervalSince(faster.arrival))
        case .switchedToFaster(let previousArrival):
            notifier.announceSwitch(to: Itinerary(legs: trip.remainingLegs), saving: previousArrival.timeIntervalSince(trip.arrival))
        default:
            break
        }
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

    /// Plans a commute as if leaving now, without disturbing the trip on screen: enough to know what it is travelled by.
    func preview(_ template: TripTemplate) async -> Itinerary? {
        var resolved = template
        if resolved.usesCurrentLocation {
            guard let coordinate = location.coordinate else { return nil }
            resolved.updateCurrentLocation(coordinate)
        }
        return try? await planner.plan(resolved, departingAt: .now).first
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
