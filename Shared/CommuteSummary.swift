import CommuteCore
import Foundation

/// As much of a saved commute as a widget shows. The commutes themselves live in the app's own store, which a
/// widget can't open, so the app writes this list out whenever they change.
nonisolated struct CommuteSummary: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    /// Where it starts, or nil when that is wherever the rider happens to be.
    var origin: String?
    var destination: String
    /// The SF Symbol for how it is travelled: transit if any of it is, otherwise how it sets out.
    var symbol: String
    /// The standing time of day to be there by, as minutes after midnight.
    var arriveByMinutes: Int?

    var arriveBy: TimeOfDay? { arriveByMinutes.map(TimeOfDay.init(minutes:)) }

    private static let key = "commutes"

    static func loadAll() -> [CommuteSummary] {
        AppGroup.defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([CommuteSummary].self, from: $0) } ?? []
    }

    /// - Returns: false when this is what was there already, so nothing needs redrawing.
    @discardableResult
    static func saveAll(_ commutes: [CommuteSummary]) -> Bool {
        guard commutes != loadAll() else { return false }
        AppGroup.defaults.set(try? JSONEncoder().encode(commutes), forKey: key)
        return true
    }
}
