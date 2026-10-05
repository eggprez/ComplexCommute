import CommuteCore
import CoreLocation
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
    /// A trip is being travelled: fixes are asked for as a navigation app would, not as a map that happens to be open.
    private var isFollowingTrip = false
    /// Which run of `updates` is the current one, so one being replaced can't clear its replacement on the way out.
    private var generation = 0

    var coordinate: Coordinate? {
        location.map { Coordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
    }

    /// The latest fix with its time and accuracy, as the train matcher wants it.
    var fix: LocationFix? {
        guard let location, let coordinate, location.horizontalAccuracy >= 0 else { return nil }
        return LocationFix(coordinate: coordinate, time: location.timestamp, accuracy: location.horizontalAccuracy,
                           speed: location.speedAccuracy >= 0 && location.speed >= 0 ? location.speed : nil)
    }

    func start() {
        guard updates == nil else { return }
        if session == nil { session = CLServiceSession(authorization: .whenInUse) }
        generation += 1
        let run = generation
        // On a trip every fix counts: a bus pulling out, a stop reached early. Navigation-grade updates keep coming
        // at full rate and accuracy, where the default eases off to save power.
        let configuration: CLLocationUpdate.LiveConfiguration = isFollowingTrip ? .otherNavigation : .default
        updates = Task {
            do {
                for try await update in CLLocationUpdate.liveUpdates(configuration) {
                    if let location = update.location {
                        self.location = location
                        onUpdate?()
                    }
                }
            } catch {}
            if generation == run { self.updates = nil }
        }
    }

    /// Keeps fixes coming with the app in the background, for as long as a trip is being travelled.
    /// iOS only honours a session begun while the app is in front, so `renew` starts a fresh one
    /// whenever the app comes forward mid-trip.
    func keepRunningInBackground(_ keep: Bool, renew: Bool = false) {
        if keep != isFollowingTrip {
            isFollowingTrip = keep
            if updates != nil {
                updates?.cancel()
                updates = nil
                start()
            }
        }
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

/// Geofences around the station the next train leaves from and wherever the current leg ends. iOS watches
/// them with the app suspended, or not running at all, and wakes it to say one was crossed.
final class StationWatcher {
    var onCrossing: ((_ id: String, _ entered: Bool, _ date: Date) -> Void)?

    /// Letters and digits only: CoreLocation aborts the app on any other character in a monitor's name.
    private static let name = "TripStations"
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
