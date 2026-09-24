import CommuteCore
import MapKit
import Observation
import SwiftUI

/// As-you-type suggestions from Apple's search completer.
@Observable
final class PlaceSuggestions: NSObject, MKLocalSearchCompleterDelegate {
    private(set) var completions: [MKLocalSearchCompletion] = []

    @ObservationIgnored private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest, .query]
    }

    func update(query: String, near center: CLLocationCoordinate2D?) {
        if let center {
            completer.region = MKCoordinateRegion(center: center, latitudinalMeters: 80_000, longitudinalMeters: 80_000)
        }
        if query.isEmpty {
            completer.cancel()
            completions = []
        } else {
            completer.queryFragment = query
        }
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        completions = completer.results
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: any Error) {
        completions = []
    }
}

/// Places picked lately, newest first, for the empty search screen.
enum RecentPlaces {
    private static let key = "recentPlaces"
    private static let limit = 8

    static var all: [Waypoint] {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([Waypoint].self, from: $0) } ?? []
    }

    static func add(_ waypoint: Waypoint) {
        guard waypoint.kind != .currentLocation else { return }
        var recents = all.filter { $0.name != waypoint.name || $0.coordinate.distance(to: waypoint.coordinate) > 50 }
        recents.insert(waypoint, at: 0)
        UserDefaults.standard.set(try? JSONEncoder().encode(Array(recents.prefix(limit))), forKey: key)
    }
}

extension MKLocalSearchCompletion {
    /// A category or chain ("Coffee", "Search Nearby") rather than one place.
    var isQuery: Bool {
        subtitle.isEmpty || subtitle == "Search Nearby"
    }
}

extension MKMapItem {
    var shortAddress: String? {
        address?.shortAddress ?? address?.fullAddress
    }

    /// "Coffee Shop" from "MKPOICategoryCoffeeShop"; MapKit offers no display name of its own.
    var categoryName: String? {
        guard let raw = pointOfInterestCategory?.rawValue else { return nil }
        let name = raw.replacingOccurrences(of: "MKPOICategory", with: "")
        return name.reduce(into: "") { result, character in
            if character.isUppercase, !result.isEmpty, result.last?.isUppercase == false { result.append(" ") }
            result.append(character)
        }
    }

    var categorySymbol: String {
        switch pointOfInterestCategory {
        case .publicTransport: "tram.fill"
        case .airport: "airplane"
        case .parking: "parkingsign"
        case .gasStation: "fuelpump.fill"
        case .evCharger: "bolt.car.fill"
        case .carRental: "car.fill"
        case .restaurant, .foodMarket: "fork.knife"
        case .cafe, .bakery: "cup.and.saucer.fill"
        case .brewery, .winery, .nightlife: "wineglass.fill"
        case .store: "bag.fill"
        case .hotel: "bed.double.fill"
        case .school, .university: "graduationcap.fill"
        case .library: "books.vertical.fill"
        case .hospital, .pharmacy: "cross.fill"
        case .park, .nationalPark, .campground, .beach: "tree.fill"
        case .museum, .theater, .movieTheater: "theatermasks.fill"
        case .stadium, .fitnessCenter: "figure.run"
        case .bank, .atm: "dollarsign"
        case .postOffice: "envelope.fill"
        case .police, .fireStation: "shield.fill"
        default: "mappin"
        }
    }

    var categoryColor: Color {
        switch pointOfInterestCategory {
        case .publicTransport, .airport, .parking, .gasStation, .evCharger, .carRental: .blue
        case .restaurant, .foodMarket, .cafe, .bakery, .brewery, .winery, .nightlife: .orange
        case .store: .yellow
        case .hotel: .purple
        case .school, .university, .library: .brown
        case .hospital, .pharmacy: .red
        case .park, .nationalPark, .campground, .beach: .green
        case .museum, .theater, .movieTheater, .stadium, .fitnessCenter: .pink
        case .bank, .atm, .postOffice, .police, .fireStation: .gray
        default: .red
        }
    }
}
