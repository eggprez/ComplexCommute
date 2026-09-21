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
    let watch = WatchBridge()

    private let tripStore = ActiveTripStore()
    /// What was last written to disk, so the file is only rewritten when the trip really changed.
    private var stored: WatchTripState?
    private var isInFront = false
    /// The app has been in front at some point in this trip. Until it has, iOS allows neither the
    /// Live Activity nor location in the background, and the trip can't be kept up to date.
    private var tripHasBeenInFront = false

    /// Also listed in `BGTaskSchedulerPermittedIdentifiers`; iOS refuses the task otherwise.
    static let refreshIdentifier = "scottai.commuter-app.refresh"
    /// How long before its arrival time a commute counts as the one coming up.
    static let watchWindow: TimeInterval = 2 * 3_600
    /// The soonest a background wake is asked for. iOS decides what it actually grants.
    static let refreshInterval: TimeInterval = 10 * 60

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
        self.planner = TripPlannerModel(location: location, resolver: resolver, notifier: notifier)
        do {
            container = try ModelContainer(for: Commute.self, SavedPlace.self, ConnectionLog.self)
        } catch {
            fatalError("Could not open the commute store: \(error)")
        }

        location.onUpdate = { [planner] in planner.locationDidChange() }
        planner.recordConnections = { [weak self] in self?.keep($0) }
        planner.onTripChange = { [weak self] in self?.tripDidChange() }
        watch.handler = { [weak self] in await self?.perform($0) ?? WatchReply(context: WatchContext()) }
        watch.activate()

        if let trip = tripStore.load() {
            planner.resume(trip)
        } else {
            // Nothing to pick up, so an activity still on the Lock Screen belongs to a trip that is over.
            liveActivity.show(nil, force: true)
        }
    }

    // MARK: Trip in progress

    /// The trip moved on, was re-planned, or ended: tell everything outside the app that shows it.
    private func tripDidChange(force: Bool = false) {
        let now = Date.now
        let trip = planner.active
        if trip == nil { tripHasBeenInFront = false } else if isInFront { tripHasBeenInFront = true }

        var state = trip?.watchState(at: now)
        state?.needsPhone = !tripHasBeenInFront
        liveActivity.show(state?.glance, force: force)
        watch.send(WatchContext(trip: state, commutes: watchCommutes(), sentAt: now))
        location.keepRunningInBackground(trip.map { !$0.isFinished } ?? false, renew: force)

        guard state != stored else { return }
        stored = state
        if let trip, !trip.isFinished {
            tripStore.save(trip)
        } else {
            tripStore.clear()
        }
    }

    /// The app came to the front or left it. Coming forward is the one moment iOS lets a Live Activity
    /// and background location begin, so a trip that started without them gets them now.
    func sceneDidChange(isActive: Bool) {
        isInFront = isActive
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

    // MARK: Watch

    private func watchCommutes() -> [WatchCommute] {
        let commutes = (try? container.mainContext.fetch(FetchDescriptor<Commute>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        return commutes.filter(\.template.isPlannable).map { commute in
            WatchCommute(id: commute.watchID, name: commute.name, arriveBy: commute.nextArriveBy,
                         summary: commute.template.waypoints.map(\.name).joined(separator: " → "))
        }
    }

    /// Carries out what the rider asked for from the wrist.
    private func perform(_ command: WatchCommand) async -> WatchReply {
        var error: String?
        switch command {
        case .refresh:
            break
        case .start(let commuteID):
            error = await startCommute(withWatchID: commuteID)
        case .markArrived:
            planner.markArrived()
            await planner.refreshActiveTrip()
        case .markMissed:
            planner.markMissed()
            await planner.refreshActiveTrip()
        case .followFaster:
            if case .fasterOption(let itinerary) = planner.active?.notice { planner.follow(itinerary) }
        case .dismissNotice:
            planner.dismissNotice()
        case .endTrip:
            planner.endActiveTrip()
        }
        var state = planner.active?.watchState(at: .now)
        state?.needsPhone = !tripHasBeenInFront
        return WatchReply(context: WatchContext(trip: state, commutes: watchCommutes()), error: error)
    }

    /// Plans a saved commute and sets off on the best option, as tapping Start on the phone would.
    /// - Returns: what went wrong, if anything did.
    private func startCommute(withWatchID id: String) async -> String? {
        let commutes = (try? container.mainContext.fetch(FetchDescriptor<Commute>())) ?? []
        guard let commute = commutes.first(where: { $0.watchID == id }) else { return "That commute is no longer on your iPhone." }

        location.start()
        planner.start(commute.template, arrivingBy: commute.nextArriveBy)
        await planner.plan()
        // A phone woken for this may not know where it is yet.
        for _ in 0..<10 where planner.status == .waitingForLocation {
            try? await Task.sleep(for: .milliseconds(500))
            await planner.plan()
        }
        guard planner.startActiveTrip() else {
            if case .failed(let message) = planner.status { return message }
            return planner.status == .waitingForLocation ? "Open Commute on your iPhone so it can find where you are." : "No route found."
        }
        if !tripHasBeenInFront {
            notifier.announceNeedsPhone(for: commute.name)
        }
        return nil
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
