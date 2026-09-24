import CommuteCore
import MapKit
import UIKit

/// The app the turns are left to. This one plans the chain and keeps watch over it; getting down a
/// particular road is something the maps apps already do better.
enum DirectionsApp: String, CaseIterable, Identifiable {
    case appleMaps
    case googleMaps

    static let key = "directionsApp"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .appleMaps: "Maps"
        case .googleMaps: "Google Maps"
        }
    }

    /// The rider's choice, remembered from the last time they made one.
    static var preferred: DirectionsApp {
        get { UserDefaults.standard.string(forKey: key).flatMap(DirectionsApp.init) ?? .appleMaps }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    /// Hands over directions from where the rider is to `destination`. The trip carries on being
    /// followed from the background, on the Lock Screen and the Watch.
    func open(to destination: Waypoint, mode: TravelMode) {
        switch self {
        case .appleMaps:
            let item = MKMapItem(location: destination.coordinate.location, address: nil)
            item.name = destination.name
            item.openInMaps(launchOptions: [
                MKLaunchOptionsDirectionsModeKey: mode == .drive ? MKLaunchOptionsDirectionsModeDriving : MKLaunchOptionsDirectionsModeWalking,
            ])
        case .googleMaps:
            // A universal link: the Google Maps app when it is installed, the browser when it isn't.
            var link = URLComponents(string: "https://www.google.com/maps/dir/")!
            link.queryItems = [
                URLQueryItem(name: "api", value: "1"),
                URLQueryItem(name: "destination", value: "\(destination.coordinate.latitude),\(destination.coordinate.longitude)"),
                URLQueryItem(name: "travelmode", value: mode == .drive ? "driving" : "walking"),
                URLQueryItem(name: "dir_action", value: "navigate"),
            ]
            if let url = link.url {
                UIApplication.shared.open(url)
            }
        }
    }
}

extension ActiveTrip {
    /// Where another app should be asked to take the rider right now: the end of the drive or walk under
    /// way, or the platform of a train they have yet to walk to. Nil aboard a vehicle, and at the end.
    func directionsTarget(at now: Date) -> (destination: Waypoint, mode: TravelMode)? {
        guard let leg = currentLeg else { return nil }
        if leg.mode != .transit {
            return (leg.to, leg.mode)
        }
        guard !hasBoarded, let ride = currentRide(at: now), ride.walkBefore >= 60, let platform = ride.stops.first?.station else { return nil }
        return (Waypoint(name: platform.name, coordinate: platform.coordinate, kind: .stop(feedID: platform.feedID, stopID: platform.stopID)), .walk)
    }
}
