import CommuteCore
import Foundation
import SwiftData

// Every stored property has a default and there are no unique constraints, as CloudKit sync requires.

@Model
final class Commute {
    var name: String = ""
    var templateData: Data = Data()
    var createdAt: Date = Date()

    init(name: String, template: TripTemplate) {
        self.name = name
        self.templateData = (try? JSONEncoder().encode(template)) ?? Data()
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
