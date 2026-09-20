import Foundation

public enum TransitRegion: String, CaseIterable, Identifiable, Sendable {
    case nyc
    case dc

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .nyc: "New York City"
        case .dc: "Washington, DC"
        }
    }
}

/// A credential the user supplies in Settings.
public enum APIKeyID: String, CaseIterable, Identifiable, Sendable {
    case wmata

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .wmata: "WMATA"
        }
    }

    public var signupURL: URL {
        switch self {
        case .wmata: URL(string: "https://developer.wmata.com/signup")!
        }
    }

    public var instructions: String {
        switch self {
        case .wmata: "Create a free WMATA developer account, subscribe to the Default Tier product, then copy the primary key from your profile."
        }
    }
}

public struct FeedDescriptor: Identifiable, Hashable, Sendable {
    public enum Auth: Hashable, Sendable {
        case none
        /// The key is sent in the named HTTP header.
        case header(name: String, key: APIKeyID)
    }

    public let id: String
    public let name: String
    public let detail: String
    public let region: TransitRegion
    public let staticURL: URL
    public let auth: Auth
    /// Zip size in MB when last checked (2026-09); the imported database is several times larger.
    public let downloadMB: Double?

    public var requiredKey: APIKeyID? {
        if case .header(_, let key) = auth { key } else { nil }
    }

    public func request(apiKey: String?) -> URLRequest {
        var request = URLRequest(url: staticURL)
        if case .header(let name, _) = auth, let apiKey {
            request.setValue(apiKey, forHTTPHeaderField: name)
        }
        return request
    }
}

public enum FeedCatalog {
    public static let feeds: [FeedDescriptor] = nyc + dc

    public static func feeds(in region: TransitRegion) -> [FeedDescriptor] {
        feeds.filter { $0.region == region }
    }

    public static func feed(id: String) -> FeedDescriptor? {
        feeds.first { $0.id == id }
    }

    private static func mta(_ id: String, _ name: String, _ detail: String, file: String, mb: Double) -> FeedDescriptor {
        FeedDescriptor(id: id, name: name, detail: detail, region: .nyc,
                       staticURL: URL(string: "https://rrgtfsfeeds.s3.amazonaws.com/\(file).zip")!, auth: .none, downloadMB: mb)
    }

    private static let nyc: [FeedDescriptor] = [
        mta("mta-subway", "Subway", "MTA New York City Transit", file: "gtfs_subway", mb: 5.6),
        mta("mta-lirr", "Long Island Rail Road", "MTA commuter rail", file: "gtfslirr", mb: 2.0),
        mta("mta-mnr", "Metro-North Railroad", "MTA commuter rail", file: "gtfsmnr", mb: 5.8),
        FeedDescriptor(id: "path", name: "PATH", detail: "Port Authority Trans-Hudson", region: .nyc,
                       staticURL: URL(string: "https://data.trilliumtransit.com/gtfs/path-nj-us/path-nj-us.zip")!, auth: .none, downloadMB: 1.2),
        FeedDescriptor(id: "njt-rail", name: "NJ Transit Rail", detail: "Commuter rail and light rail", region: .nyc,
                       staticURL: URL(string: "https://www.njtransit.com/rail_data.zip")!, auth: .none, downloadMB: 6.4),
        FeedDescriptor(id: "njt-bus", name: "NJ Transit Bus", detail: "Statewide bus network", region: .nyc,
                       staticURL: URL(string: "https://www.njtransit.com/bus_data.zip")!, auth: .none, downloadMB: 49.8),
        mta("mta-bus-manhattan", "Manhattan Buses", "MTA New York City Transit", file: "gtfs_m", mb: 9.5),
        mta("mta-bus-brooklyn", "Brooklyn Buses", "MTA New York City Transit", file: "gtfs_b", mb: 19.6),
        mta("mta-bus-bronx", "Bronx Buses", "MTA New York City Transit", file: "gtfs_bx", mb: 9.6),
        mta("mta-bus-queens", "Queens Buses", "MTA New York City Transit", file: "gtfs_q", mb: 6.8),
        mta("mta-bus-staten-island", "Staten Island Buses", "MTA New York City Transit", file: "gtfs_si", mb: 7.5),
        mta("mta-bus-company", "MTA Bus Company", "Express and former private-line routes", file: "gtfs_busco", mb: 9.6),
    ]

    private static let dc: [FeedDescriptor] = [
        FeedDescriptor(id: "wmata-rail", name: "Metrorail", detail: "WMATA", region: .dc,
                       staticURL: URL(string: "https://api.wmata.com/gtfs/rail-gtfs-static.zip")!,
                       auth: .header(name: "api_key", key: .wmata), downloadMB: nil),
        FeedDescriptor(id: "wmata-bus", name: "Metrobus", detail: "WMATA", region: .dc,
                       staticURL: URL(string: "https://api.wmata.com/gtfs/bus-gtfs-static.zip")!,
                       auth: .header(name: "api_key", key: .wmata), downloadMB: nil),
        FeedDescriptor(id: "marc", name: "MARC Train", detail: "Maryland commuter rail", region: .dc,
                       staticURL: URL(string: "https://mdotmta-gtfs.s3.amazonaws.com/mdotmta_gtfs_marc.zip")!, auth: .none, downloadMB: 0.2),
        FeedDescriptor(id: "vre", name: "Virginia Railway Express", detail: "Virginia commuter rail", region: .dc,
                       staticURL: URL(string: "https://gtfs.vre.org/containercdngtfsupload/google_transit.zip")!, auth: .none, downloadMB: 0.1),
    ]
}
