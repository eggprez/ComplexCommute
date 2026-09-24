import CommuteCore
import CoreLocation
import CoreMotion
import Observation

@Observable
final class LocationService {
    private(set) var location: CLLocation?
    /// Called on every fix, view or no view: a trip in progress is followed with the phone in a pocket.
    @ObservationIgnored var onUpdate: (() -> Void)?

    private var session: CLServiceSession?
    /// Held while a trip is under way: station geofences only wake an app that isn't running with Always access.
    private var alwaysSession: CLServiceSession?
    private var background: CLBackgroundActivitySession?
    private var updates: Task<Void, Never>?

    var coordinate: Coordinate? {
        location.map { Coordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
    }

    /// The latest fix with its time and accuracy, as the train matcher wants it.
    var fix: LocationFix? {
        guard let location, let coordinate, location.horizontalAccuracy >= 0 else { return nil }
        return LocationFix(coordinate: coordinate, time: location.timestamp, accuracy: location.horizontalAccuracy)
    }

    func start() {
        guard updates == nil else { return }
        session = CLServiceSession(authorization: .whenInUse)
        updates = Task {
            do {
                for try await update in CLLocationUpdate.liveUpdates() {
                    if let location = update.location {
                        self.location = location
                        onUpdate?()
                    }
                }
            } catch {
                self.updates = nil
            }
        }
    }

    /// Keeps fixes coming with the app in the background, for as long as a trip is being travelled.
    /// iOS only honours a session begun while the app is in front, so `renew` starts a fresh one
    /// whenever the app comes forward mid-trip.
    func keepRunningInBackground(_ keep: Bool, renew: Bool = false) {
        if !keep || renew {
            background?.invalidate()
            background = nil
        }
        if keep, alwaysSession == nil {
            alwaysSession = CLServiceSession(authorization: .always)
        } else if !keep {
            alwaysSession?.invalidate()
            alwaysSession = nil
        }
        if keep, background == nil {
            background = CLBackgroundActivitySession()
        }
    }
}

/// What the motion coprocessor says the rider is doing, while a trip is under way. Works underground and in a
/// garage, where GPS doesn't: the step from driving to walking, and from standing on a platform to moving off.
@Observable
final class MotionService {
    private(set) var motion: Motion?
    @ObservationIgnored var onUpdate: ((Motion) -> Void)?

    private let manager = CMMotionActivityManager()
    private var isRunning = false

    func start() {
        guard !isRunning, CMMotionActivityManager.isActivityAvailable() else { return }
        isRunning = true
        manager.startActivityUpdates(to: .main) { activity in
            guard let activity, activity.confidence != .low else { return }
            let motion = Motion(activity)
            MainActor.assumeIsolated {
                guard self.motion != motion else { return }
                self.motion = motion
                self.onUpdate?(motion)
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        manager.stopActivityUpdates()
        isRunning = false
        motion = nil
    }
}

private extension Motion {
    /// A train at speed reads as automotive; at a platform it can read as automotive and stationary at once.
    nonisolated init(_ activity: CMMotionActivity) {
        self = activity.automotive ? .automotive : activity.cycling ? .cycling : activity.running ? .running
            : activity.walking ? .walking : activity.stationary ? .stationary : .unknown
    }
}

/// Geofences around the station the next train leaves from and wherever the current leg ends. iOS watches
/// them with the app suspended, or not running at all, and wakes it to say one was crossed.
final class StationWatcher {
    var onCrossing: ((_ id: String, _ entered: Bool, _ date: Date) -> Void)?

    private static let name = "trip-stations"
    private var monitor: CLMonitor?
    private var watched: [String: WatchedPlace] = [:]
    private var wanted: [WatchedPlace] = []

    /// Must run at every launch: a crossing that woke the app is only delivered to a monitor opened by the same name.
    func start() {
        guard monitor == nil else { return }
        Task {
            let monitor = await CLMonitor(Self.name)
            self.monitor = monitor
            await sync(clearingUnknown: true)
            do {
                for try await event in await monitor.events {
                    switch event.state {
                    case .satisfied: onCrossing?(event.identifier, true, event.date)
                    case .unsatisfied: onCrossing?(event.identifier, false, event.date)
                    default: break
                    }
                }
            } catch {}
        }
    }

    /// Watches exactly these places, dropping the rest.
    func watch(_ places: [WatchedPlace]) {
        guard places != wanted else { return }
        wanted = places
        Task { await sync() }
    }

    private func sync(clearingUnknown: Bool = false) async {
        guard let monitor else { return }
        let wanted = Dictionary(wanted.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let existing = clearingUnknown ? Set(await monitor.identifiers) : Set(watched.keys)
        for id in existing where wanted[id] == nil {
            await monitor.remove(id)
        }
        for (id, place) in wanted where watched[id] != place {
            let condition = CLMonitor.CircularGeographicCondition(
                center: CLLocationCoordinate2D(latitude: place.center.latitude, longitude: place.center.longitude), radius: place.radius)
            // Starting inside a fence isn't crossing it: assume the rider is where they are.
            await monitor.add(condition, identifier: id, assuming: .unsatisfied)
        }
        watched = wanted
    }
}
