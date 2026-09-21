import CommuteCore
import CoreLocation
import Observation

@Observable
final class LocationService {
    private(set) var location: CLLocation?
    /// Called on every fix, view or no view: a trip in progress is followed with the phone in a pocket.
    @ObservationIgnored var onUpdate: (() -> Void)?

    private var session: CLServiceSession?
    private var background: CLBackgroundActivitySession?
    private var updates: Task<Void, Never>?

    var coordinate: Coordinate? {
        location.map { Coordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
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
        if keep, background == nil {
            background = CLBackgroundActivitySession()
        }
    }
}
