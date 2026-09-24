import CommuteCore
import Foundation
import SwiftData

// Every stored property has a default and there are no unique constraints, as CloudKit sync requires.

@Model
final class Commute {
    var name: String = ""
    var templateData: Data = Data()
    var createdAt: Date = Date()
    /// The time of day this commute has to be finished by, as minutes after midnight. Nil when the
    /// rider never set one, or said no when asked.
    var arriveByMinutes: Int?
    /// Set once the rider has been asked whether this commute has a standing arrival time, so a "no"
    /// isn't asked again every time they edit it.
    var hasBeenAskedArriveBy: Bool = false

    init(name: String, template: TripTemplate) {
        self.name = name
        self.templateData = (try? JSONEncoder().encode(template)) ?? Data()
    }

    /// When this commute has to be finished by next: today if that is still to come, otherwise tomorrow.
    var nextArriveBy: Date? {
        arriveByMinutes.map { TimeOfDay(minutes: $0).next() }
    }

    var arriveBy: TimeOfDay? {
        get { arriveByMinutes.map(TimeOfDay.init(minutes:)) }
        set { arriveByMinutes = newValue?.minutes }
    }

    /// "Home to Office", or "To Office" for commutes that start wherever the rider is.
    static func defaultName(for template: TripTemplate) -> String {
        guard let first = template.waypoints.first, let last = template.waypoints.last, template.isPlannable else { return "New Commute" }
        return first.kind == .currentLocation ? "To \(last.name)" : "\(first.name) to \(last.name)"
    }

    var template: TripTemplate {
        get { (try? JSONDecoder().decode(TripTemplate.self, from: templateData)) ?? TripTemplate() }
        set { templateData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
}

@Model
final class SavedPlace {
    var name: String = ""
    var subtitle: String?
    var latitude: Double = 0
    var longitude: Double = 0
    var createdAt: Date = Date()

    init(name: String, subtitle: String?, coordinate: Coordinate) {
        self.name = name
        self.subtitle = subtitle
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
    }

    var waypoint: Waypoint {
        Waypoint(name: name, subtitle: subtitle, coordinate: Coordinate(latitude: latitude, longitude: longitude))
    }
}

/// One connection as it really went, kept so the app can learn what buffer this rider's connections
/// actually take. Every property has a default and nothing is unique, as CloudKit sync requires.
@Model
final class ConnectionLog {
    var recordID: UUID = UUID()
    var date: Date = Date()
    var approachRaw: String = ConnectionApproach.drive.rawValue
    var stationID: String?
    var stationName: String = ""
    var routeName: String?
    var plannedArrival: Date = Date()
    var actualArrival: Date = Date()
    var plannedDeparture: Date = Date()
    var actualDeparture: Date = Date()
    var isObserved: Bool = true
    var wasMissed: Bool = false

    init(_ record: ConnectionRecord) {
        apply(record)
    }

    func apply(_ record: ConnectionRecord) {
        recordID = record.id
        date = record.date
        approachRaw = record.approach.rawValue
        stationID = record.stationID
        stationName = record.stationName
        routeName = record.routeName
        plannedArrival = record.plannedArrival
        actualArrival = record.actualArrival
        plannedDeparture = record.plannedDeparture
        actualDeparture = record.actualDeparture
        isObserved = record.isObserved
        wasMissed = record.wasMissed
    }

    var record: ConnectionRecord {
        ConnectionRecord(id: recordID, date: date, approach: ConnectionApproach(rawValue: approachRaw) ?? .drive,
                         stationID: stationID, stationName: stationName, routeName: routeName,
                         plannedArrival: plannedArrival, actualArrival: actualArrival,
                         plannedDeparture: plannedDeparture, actualDeparture: actualDeparture,
                         isObserved: isObserved, wasMissed: wasMissed)
    }
}
