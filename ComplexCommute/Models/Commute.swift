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
    /// What the commute was travelled by the last time it was planned. Nil until then.
    var lookData: Data?

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

    /// What a widget and its link back into the app know this commute by. The moment it was created: unlike the
    /// store's own identifier it is the same on every device the commute syncs to.
    var widgetID: String {
        String(Int((createdAt.timeIntervalSinceReferenceDate * 1_000).rounded()))
    }

    /// As much of the commute as its widget shows.
    @MainActor var summary: CommuteSummary {
        let template = template
        let first = template.waypoints.first
        return CommuteSummary(id: widgetID, name: name, origin: first?.kind == .currentLocation ? nil : first?.name,
                              destination: template.waypoints.last?.name ?? "",
                              symbol: (template.modes.contains(.transit) ? TravelMode.transit : template.modes.first ?? .transit).symbol,
                              arriveByMinutes: arriveByMinutes)
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

    /// A commute that has never been planned is drawn from its modes alone: "transit", not yet "bus".
    var look: CommuteLook {
        get { lookData.flatMap { try? JSONDecoder().decode(CommuteLook.self, from: $0) } ?? CommuteLook(template: template) }
        set { lookData = try? JSONEncoder().encode(newValue) }
    }
}

/// A way of getting somewhere, as finely as a rider tells them apart: a bus is not a subway.
nonisolated enum TravelKind: String, Codable, Hashable, Sendable {
    case drive
    case walk
    case subway
    case rail
    case bus
    case tram
    case ferry
    case cable
    /// Transit that hasn't been planned yet, or of a kind the schedule doesn't say.
    case transit

    init(_ mode: TravelMode) {
        switch mode {
        case .drive: self = .drive
        case .walk: self = .walk
        case .transit: self = .transit
        }
    }

    /// From a GTFS route_type, basic or extended.
    init(routeType: Int) {
        switch routeType {
        case 1, 400...499: self = .subway
        case 2, 100...199: self = .rail
        case 3, 11, 200...299, 700...899: self = .bus
        // Monorails and people movers (AirTrain) ride like a tram.
        case 0, 12, 900...999: self = .tram
        case 4, 1000...1299: self = .ferry
        case 5, 6, 7, 1300...1499: self = .cable
        default: self = .transit
        }
    }
}

/// What a commute is travelled by, in order, and the one that carries most of it.
nonisolated struct CommuteLook: Codable, Hashable, Sendable {
    var kinds: [TravelKind]
    var primary: TravelKind

    init(template: TripTemplate) {
        kinds = Self.withoutRepeats(template.modes.map(TravelKind.init))
        primary = [.transit, .drive, .walk].first(where: kinds.contains) ?? .transit
    }

    /// Each drive, walk and ride of a planned trip. Walks to and between platforms are part of the ride.
    init(itinerary: Itinerary) {
        var pieces: [(kind: TravelKind, duration: TimeInterval)] = []
        for leg in itinerary.legs {
            if leg.option.rides.isEmpty {
                pieces.append((TravelKind(leg.mode), leg.duration))
            } else {
                pieces += leg.option.rides.map { (TravelKind(routeType: $0.routeType), $0.alight.timeIntervalSince($0.board)) }
            }
        }
        kinds = Self.withoutRepeats(pieces.map(\.kind))
        let time = Dictionary(pieces.map { ($0.kind, $0.duration) }, uniquingKeysWith: +)
        // Nobody calls a train ride with a walk at each end a walk.
        let vehicles = time.filter { $0.key != .walk }
        primary = (vehicles.isEmpty ? time : vehicles).max { $0.value < $1.value }?.key ?? .transit
    }

    private static func withoutRepeats(_ kinds: [TravelKind]) -> [TravelKind] {
        kinds.reduce(into: []) { result, kind in
            if result.last != kind { result.append(kind) }
        }
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
