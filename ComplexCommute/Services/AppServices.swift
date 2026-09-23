import BackgroundTasks
import CommuteCore
import Foundation
import Observation
import SwiftData
import TransitRouting

/// The app's long-lived pieces. They live above the view tree because a background refresh has to
/// reach them when there is no view on screen at all.
@Observable
final class AppServices {
    let location: LocationService
    let transitData: TransitDataStore
    let transit: TransitPlanner
    let planner: TripPlannerModel
    let notifier: TripNotifier
    let container: ModelContainer
    let liveActivity = TripActivityController()
    let motion = MotionService()
    let stations = StationWatcher()

    private let tripStore = ActiveTripStore()
    /// What was last written to disk, so the file is only rewritten when the trip really changed.
    private var stored: StoredTrip?
    /// What leaves the change the rider is coming up on, as last looked up, and for which change.
    private var connections: (station: String, toward: String, board: ConnectionBoard, fetchedAt: Date)?
    private var connectionLookup: Task<Void, Never>?

    /// Also listed in `BGTaskSchedulerPermittedIdentifiers`; iOS refuses the task otherwise.
    static let refreshIdentifier = "scottai.commuter-app.refresh"
    /// How long before its arrival time a commute counts as the one coming up.
    static let watchWindow: TimeInterval = 2 * 3_600
    /// The soonest a background wake is asked for. iOS decides what it actually grants.
    static let refreshInterval: TimeInterval = 10 * 60
    /// How often the departures from an upcoming change are looked up again. Realtime refreshes about as often.
    static let connectionsMaxAge: TimeInterval = 30

    init() {
        let location = LocationService()
        let transitData = TransitDataStore()
        let realtime = RealtimeService { KeychainStore.string(for: $0.rawValue) }
        let transit = TransitPlanner(library: transitData.library, realtime: realtime)
        let notifier = TripNotifier()
        let resolver = CommuteLegResolver(mapKit: MapKitLegResolver(), transit: transit)
        self.location = location
        self.transitData = transitData
        self.transit = transit
        self.notifier = notifier
        self.planner = TripPlannerModel(location: location, resolver: resolver, notifier: notifier, trains: transit)
        do {
            container = try ModelContainer(for: Commute.self, SavedPlace.self, ConnectionLog.self)
        } catch {
            fatalError("Could not open the commute store: \(error)")
        }

        location.onUpdate = { [planner] in planner.locationDidChange() }
        motion.onUpdate = { [planner] in planner.motionDidChange($0) }
        stations.onCrossing = { [planner] id, entered, date in planner.crossed(id, entered: entered, at: date) }
        TripActionRouter.handler = { [planner] in planner.perform($0) }
        // Before the trip is picked back up: a geofence crossing may be why the app was launched at all.
        stations.start()
        planner.recordConnections = { [weak self] in self?.keep($0) }
        planner.onTripChange = { [weak self] in self?.tripDidChange() }

        if let trip = tripStore.load() {
            planner.resume(trip)
        } else {
            // Nothing to pick up, so an activity still on the Lock Screen belongs to a trip that is over.
            liveActivity.show(nil, force: true)
        }
    }

    // MARK: Trip in progress

    /// The trip moved on, was re-planned, or ended: tell everything outside the app that shows it.
    /// The Watch's Smart Stack is the Live Activity too, mirrored there by iOS.
    private func tripDidChange(force: Bool = false) {
        let now = Date.now
        let trip = planner.active

        var glance = trip?.glance(at: now)
        let state = trip.map { StoredTrip(glance: glance ?? $0.glance(at: now), legs: $0.legs) }
        glance?.connections = connections(for: trip, at: now)
        liveActivity.show(glance, force: force)
        let isUnderway = trip.map { !$0.isFinished } ?? false
        location.keepRunningInBackground(isUnderway, renew: force)
        if isUnderway { motion.start() } else { motion.stop() }
        stations.watch(isUnderway ? trip?.placesToWatch ?? [] : [])

        guard state != stored else { return }
        stored = state
        if let trip, !trip.isFinished {
            tripStore.save(trip)
        } else {
            tripStore.clear()
        }
    }

    /// The next few vehicles from the change coming up that go where the rider is going. Looked up in the
    /// background: this answers with what was last found, and the trip is told again once more is known.
    private func connections(for trip: ActiveTrip?, at now: Date) -> ConnectionBoard? {
        guard let change = trip?.upcomingChange(at: now) else {
            connections = nil
            return nil
        }
        let (station, toward) = (change.station.id, change.toward.id)
        let isCurrent = connections.map { $0.station == station && $0.toward == toward } ?? false
        let isFresh = isCurrent && now.timeIntervalSince(connections?.fetchedAt ?? .distantPast) < Self.connectionsMaxAge
        if !isFresh, connectionLookup == nil {
            connectionLookup = Task { [transit] in
                let found = await transit.departures(from: change.station, toward: change.toward, after: change.catchableFrom,
                                                     within: 90 * 60, limit: 6)
                let board = change.board(found.map { departure in
                    ConnectionBoard.Departure(route: RouteLabel(name: departure.route.name, colorHex: departure.route.colorHex,
                                                                textColorHex: departure.route.textColorHex),
                                              time: departure.time, isRealtime: departure.isRealtime)
                })
                connections = (station, toward, board, .now)
                connectionLookup = nil
                tripDidChange()
            }
        }
        guard isCurrent else { return nil }
        return connections?.board.catchable(from: change.catchableFrom)
    }

    /// The app came to the front or left it. Coming forward is the one moment iOS lets a Live Activity
    /// and background location begin, so a trip that started without them gets them now.
    func sceneDidChange(isActive: Bool) {
        tripDidChange(force: isActive && planner.active != nil)
    }

    /// Connections the trip in progress has timed, kept for learning the buffer from.
    private func keep(_ records: [ConnectionRecord]) {
        let context = container.mainContext
        for record in records {
            let id = record.id
            let existing = try? context.fetch(FetchDescriptor<ConnectionLog>(predicate: #Predicate { $0.recordID == id }))
            if let found = existing?.first {
                found.apply(record)
            } else {
                context.insert(ConnectionLog(record))
            }
        }
        try? context.save()
    }

    // MARK: Background refresh

    /// Asks iOS to wake the app again. It decides whether and when, and declines outright in the
    /// simulator, so nothing may depend on this having run.
    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: Self.refreshInterval)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Woken in the background. Only two things are worth the wake: a trip actually being travelled,
    /// and a commute with a standing arrival time that is coming up.
    func refreshInBackground() async {
        await notifier.refresh()
        if planner.active != nil {
            await planner.refreshActiveTrip()
        } else {
            await refreshUpcomingCommute()
        }
        scheduleBackgroundRefresh()
    }

    /// Re-plans the commute nearest its arrival time and moves its "time to leave" reminder to match.
    func refreshUpcomingCommute() async {
        guard let (commute, target) = upcomingCommute() else {
            notifier.cancelLeaveNow()
            return
        }
        guard let best = await planner.plan(commute.template, arrivingBy: target) else { return }
        notifier.scheduleLeaveNow(at: best.departure, for: commute.name, arriveBy: target)
    }

    /// The commute closest to its standing arrival time, if one is within the window.
    func upcomingCommute() -> (commute: Commute, target: Date)? {
        let commutes = (try? container.mainContext.fetch(FetchDescriptor<Commute>())) ?? []
        return commutes.compactMap { commute -> (Commute, Date)? in
            guard commute.template.isPlannable, let target = commute.nextArriveBy,
                  target.timeIntervalSinceNow < Self.watchWindow else { return nil }
            return (commute, target)
        }
        .min { $0.1 < $1.1 }
    }
}

/// What decides whether the trip on disk is out of date: what it shows, and the plan behind it.
private struct StoredTrip: Equatable {
    var glance: TripGlance
    var legs: [Leg]
}
