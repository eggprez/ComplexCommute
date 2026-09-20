import CommuteCore
import CoreLocation
import Observation

@Observable
final class LocationService {
    private(set) var location: CLLocation?

    private var session: CLServiceSession?
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
                    }
                }
            } catch {
                self.updates = nil
            }
        }
    }
}
