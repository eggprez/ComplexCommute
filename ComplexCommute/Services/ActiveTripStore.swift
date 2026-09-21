import CommuteCore
import Foundation

/// The trip in progress, written down so that closing the app mid-trip doesn't end the trip.
struct ActiveTripStore {
    /// A trip this long past its arrival is over, whatever the app last knew about it.
    static let expiry: TimeInterval = 30 * 60

    private let url: URL

    init(directory: URL = .applicationSupportDirectory) {
        url = directory.appending(path: "active-trip.json")
    }

    func save(_ trip: ActiveTrip) {
        guard let data = try? JSONEncoder().encode(trip) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    /// The trip that was under way when the app last ran, if it could still be.
    func load(now: Date = .now) -> ActiveTrip? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let trip = try? JSONDecoder().decode(ActiveTrip.self, from: data),
              !trip.isFinished, now < trip.arrival.addingTimeInterval(Self.expiry) else {
            clear()
            return nil
        }
        return trip
    }
}
