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

extension Color {
    /// "RRGGBB" as published in GTFS; nil for missing or malformed values.
    init?(hex: String?) {
        guard let hex, hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}
