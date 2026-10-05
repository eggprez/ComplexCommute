import CommuteCore
import Foundation

/// Where a tap on a widget lands in the app.
nonisolated enum AppLink: Equatable {
    /// A saved commute, opened ready to be given a time to arrive by.
    case commute(id: String)
    /// A station's departure board.
    case station(StationRef)

    /// Also declared under `CFBundleURLTypes` in project.yml.
    static let scheme = "complexcommute"

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .commute(let id):
            components.host = "commute"
            components.queryItems = [URLQueryItem(name: "id", value: id)]
        case .station(let station):
            components.host = "station"
            components.queryItems = [
                URLQueryItem(name: "feed", value: station.feedID),
                URLQueryItem(name: "stop", value: station.stopID),
                URLQueryItem(name: "name", value: station.name),
                URLQueryItem(name: "lat", value: String(station.coordinate.latitude)),
                URLQueryItem(name: "lon", value: String(station.coordinate.longitude)),
            ]
        }
        return components.url ?? URL(string: "\(Self.scheme)://")!
    }

    init?(_ url: URL) {
        guard url.scheme == Self.scheme, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        func value(_ name: String) -> String? {
            components.queryItems?.first { $0.name == name }?.value
        }
        switch components.host {
        case "commute":
            guard let id = value("id") else { return nil }
            self = .commute(id: id)
        case "station":
            guard let feed = value("feed"), let stop = value("stop"), let name = value("name"),
                  let latitude = value("lat").flatMap(Double.init), let longitude = value("lon").flatMap(Double.init) else { return nil }
            self = .station(StationRef(feedID: feed, stopID: stop, name: name, coordinate: Coordinate(latitude: latitude, longitude: longitude)))
        default:
            return nil
        }
    }
}
