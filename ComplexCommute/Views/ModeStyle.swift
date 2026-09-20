import CommuteCore
import SwiftUI

extension TravelMode {
    var label: String {
        switch self {
        case .drive: "Drive"
        case .walk: "Walk"
        case .transit: "Transit"
        }
    }

    var symbol: String {
        switch self {
        case .drive: "car.fill"
        case .walk: "figure.walk"
        case .transit: "tram.fill"
        }
    }

    var tint: Color {
        switch self {
        case .drive: .blue
        case .walk: .gray
        case .transit: .orange
        }
    }
}

extension Waypoint {
    var symbol: String {
        switch kind {
        case .currentLocation: "location.fill"
        case .place: "mappin"
        case .stop: "tram.fill"
        }
    }
}

extension ItineraryTag {
    var label: String {
        switch self {
        case .fastest: "Fastest"
        case .fewestTransfers: "Fewest transfers"
        case .leastWalking: "Least walking"
        }
    }
}

extension TimeInterval {
    /// "8 min", "1 hr 12 min"
    var shortDuration: String {
        Duration.seconds(max(60, self)).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
}
