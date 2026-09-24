import CommuteCore
import Foundation

public enum TransitRegion: String, CaseIterable, Identifiable, Sendable {
    case nyc
    case dc
    case boston
    case atlanta

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .nyc: "New York City"
        case .dc: "Washington, DC"
        case .boston: "Boston"
        case .atlanta: "Atlanta"
        }
    }

    /// Roughly the middle of the city's network, for telling which city a trip is in.
    public var center: Coordinate {
        switch self {
        case .nyc: Coordinate(latitude: 40.75, longitude: -73.99)
        case .dc: Coordinate(latitude: 38.90, longitude: -77.03)
        case .boston: Coordinate(latitude: 42.36, longitude: -71.06)
        case .atlanta: Coordinate(latitude: 33.75, longitude: -84.39)
        }
    }

    /// The cities a trip through `coordinates` could use. Far enough to take in the commuter railroads'
    /// outer ends, near enough that neighboring cities don't overlap.
    public static func near(_ coordinates: [Coordinate], radiusMeters: Double = 150_000) -> [TransitRegion] {
        allCases.filter { region in coordinates.contains { $0.distance(to: region.center) <= radiusMeters } }
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

/// Where a feed's GTFS-realtime data lives and how its trips line up with the static schedule.
public struct RealtimeSource: Hashable, Sendable {
    public enum TripMatching: Hashable, Sendable {
        /// Realtime trip_ids equal the schedule's.
        case exactTripID
        /// NYC subway: realtime sends "044950_N..N" where the schedule has "…-Sunday-00_044950_N..N34R";
        /// origin time, route and direction identify the trip.
        case nyctSubway
    }

    public let tripUpdateURLs: [URL]
    public let alertURLs: [URL]
    public let tripMatching: TripMatching
    /// Seconds a fetched copy stays fresh. The citywide bus feed is large, so it refreshes less often.
    public let maxAge: TimeInterval

    init(tripUpdates: [String], alerts: [String], tripMatching: TripMatching = .exactTripID, maxAge: TimeInterval = 30) {
        tripUpdateURLs = tripUpdates.compactMap { URL(string: $0) }
        alertURLs = alerts.compactMap { URL(string: $0) }
        self.tripMatching = tripMatching
        self.maxAge = maxAge
    }

    /// Normalizes a trip_id from either side so that matching trips compare equal.
    public func matchKey(forTripID tripID: String) -> String {
        guard tripMatching == .nyctSubway else { return tripID }
        // "<origin time>_<route padded to 3 with dots><direction><path>": keep up to the direction ("044950_N..N",
        // "054000_GS.N"), dropping the schedule's service prefix and the path variant.
        let parts = tripID.split(separator: "_")
        guard parts.count >= 2, let run = parts.last, run.count >= 4 else { return tripID }
        return "\(parts[parts.count - 2])_\(run.prefix(4))"
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
    /// Nil for a feed the app carries itself (`BuiltInFeeds`), built on the phone instead of downloaded.
    public let staticURL: URL?
    public let auth: Auth
    /// Zip size in MB when last checked (2026-09); the imported database is several times larger.
    public let downloadMB: Double
    /// Realtime uses the same credentials as the schedule.
    public var realtime: RealtimeSource?
    /// How long an installed copy is used before the app fetches a newer one on its own.
    public var refreshInterval: TimeInterval = 7 * 86_400

    public var requiredKey: APIKeyID? {
        if case .header(_, let key) = auth { key } else { nil }
    }

    public var isBuiltIn: Bool { staticURL == nil }

    /// Nil for a built-in feed, which has nothing to download.
    public func request(apiKey: String?) -> URLRequest? {
        staticURL.map { request(for: $0, apiKey: apiKey) }
    }

    public func request(for url: URL, apiKey: String?) -> URLRequest {
        var request = URLRequest(url: url)
        if case .header(let name, _) = auth, let apiKey {
            request.setValue(apiKey, forHTTPHeaderField: name)
        }
        return request
    }
}

public enum FeedCatalog {
    public static let feeds: [FeedDescriptor] = nyc + dc + boston + atlanta

    public static func feeds(in region: TransitRegion) -> [FeedDescriptor] {
        feeds.filter { $0.region == region }
    }

    public static func feed(id: String) -> FeedDescriptor? {
        feeds.first { $0.id == id }
    }

    /// Everything a city's download fetches, in MB. Cities are installed whole, never a service at a time.
    public static func downloadMB(for region: TransitRegion) -> Double {
        feeds(in: region).reduce(0) { $0 + $1.downloadMB }
    }

    /// Keys a city needs before it can be downloaded.
    public static func requiredKeys(for region: TransitRegion) -> [APIKeyID] {
        Array(Set(feeds(in: region).compactMap(\.requiredKey))).sorted { $0.rawValue < $1.rawValue }
    }

    private static let mtaRealtime = "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/"

    private static func mta(_ id: String, _ name: String, _ detail: String, file: String, mb: Double, realtime: RealtimeSource) -> FeedDescriptor {
        FeedDescriptor(id: id, name: name, detail: detail, region: .nyc,
                       staticURL: URL(string: "https://rrgtfsfeeds.s3.amazonaws.com/\(file).zip")!, auth: .none, downloadMB: mb, realtime: realtime)
    }

    private static let subwayRealtime = RealtimeSource(
        tripUpdates: ["", "-ace", "-bdfm", "-g", "-jz", "-nqrw", "-l", "-si"].map { mtaRealtime + "nyct%2Fgtfs" + $0 },
        alerts: [mtaRealtime + "camsys%2Fsubway-alerts"], tripMatching: .nyctSubway)
    /// One citywide feed covers every MTA bus schedule.
    private static let busRealtime = RealtimeSource(
        tripUpdates: ["https://gtfsrt.prod.obanyc.com/tripUpdates"], alerts: [mtaRealtime + "camsys%2Fbus-alerts"], maxAge: 60)

    private static let nyc: [FeedDescriptor] = [
        // The "supplemented" schedule folds in planned service changes for the coming week, which both routes around
        // weekend work and lines up far better with realtime trip ids than the base schedule. It is rebuilt often.
        {
            var subway = mta("mta-subway", "Subway", "MTA New York City Transit", file: "gtfs_supplemented", mb: 18.8, realtime: subwayRealtime)
            subway.refreshInterval = 86_400
            return subway
        }(),
        mta("mta-lirr", "Long Island Rail Road", "MTA commuter rail", file: "gtfslirr", mb: 2.0,
            realtime: RealtimeSource(tripUpdates: [mtaRealtime + "lirr%2Fgtfs-lirr"], alerts: [mtaRealtime + "camsys%2Flirr-alerts"])),
        mta("mta-mnr", "Metro-North Railroad", "MTA commuter rail", file: "gtfsmnr", mb: 5.8,
            realtime: RealtimeSource(tripUpdates: [mtaRealtime + "mnr%2Fgtfs-mnr"], alerts: [mtaRealtime + "camsys%2Fmnr-alerts"])),
        FeedDescriptor(id: "path", name: "PATH", detail: "Port Authority Trans-Hudson", region: .nyc,
                       staticURL: URL(string: "https://data.trilliumtransit.com/gtfs/path-nj-us/path-nj-us.zip")!, auth: .none, downloadMB: 1.2),
        FeedDescriptor(id: "njt-rail", name: "NJ Transit Rail", detail: "Commuter rail and light rail", region: .nyc,
                       staticURL: URL(string: "https://www.njtransit.com/rail_data.zip")!, auth: .none, downloadMB: 6.4),
        FeedDescriptor(id: "njt-bus", name: "NJ Transit Bus", detail: "Statewide bus network", region: .nyc,
                       staticURL: URL(string: "https://www.njtransit.com/bus_data.zip")!, auth: .none, downloadMB: 49.8),
        mta("mta-bus-manhattan", "Manhattan Buses", "MTA New York City Transit", file: "gtfs_m", mb: 9.5, realtime: busRealtime),
        mta("mta-bus-brooklyn", "Brooklyn Buses", "MTA New York City Transit", file: "gtfs_b", mb: 19.6, realtime: busRealtime),
        mta("mta-bus-bronx", "Bronx Buses", "MTA New York City Transit", file: "gtfs_bx", mb: 9.6, realtime: busRealtime),
        mta("mta-bus-queens", "Queens Buses", "MTA New York City Transit", file: "gtfs_q", mb: 6.8, realtime: busRealtime),
        mta("mta-bus-staten-island", "Staten Island Buses", "MTA New York City Transit", file: "gtfs_si", mb: 7.5, realtime: busRealtime),
        mta("mta-bus-company", "MTA Bus Company", "Express and former private-line routes", file: "gtfs_busco", mb: 9.6, realtime: busRealtime),
        // Published by 511NY rather than the Port Authority. LaGuardia's Q70 and M60 are in the MTA bus feeds.
        FeedDescriptor(id: "airtrain-jfk", name: "AirTrain JFK", detail: "Port Authority, via 511NY", region: .nyc,
                       staticURL: URL(string: "https://s3.amazonaws.com/datatools-511ny/public/AirTrain_JFK.zip")!, auth: .none, downloadMB: 0.1),
        BuiltInFeeds.descriptor(.nyc, name: "AirTrain Newark", detail: "Built in: publishes no schedule"),
    ]

    private static let dc: [FeedDescriptor] = [
        FeedDescriptor(id: "wmata-rail", name: "Metrorail", detail: "WMATA", region: .dc,
                       staticURL: URL(string: "https://api.wmata.com/gtfs/rail-gtfs-static.zip")!,
                       // Estimated: WMATA only serves the file with a key, so it hasn't been measured.
                       auth: .header(name: "api_key", key: .wmata), downloadMB: 3,
                       realtime: RealtimeSource(tripUpdates: ["https://api.wmata.com/gtfs/rail-gtfsrt-tripupdates.pb"],
                                                alerts: ["https://api.wmata.com/gtfs/rail-gtfsrt-alerts.pb"])),
        FeedDescriptor(id: "wmata-bus", name: "Metrobus", detail: "WMATA", region: .dc,
                       staticURL: URL(string: "https://api.wmata.com/gtfs/bus-gtfs-static.zip")!,
                       // Estimated, as for Metrorail.
                       auth: .header(name: "api_key", key: .wmata), downloadMB: 30,
                       realtime: RealtimeSource(tripUpdates: ["https://api.wmata.com/gtfs/bus-gtfsrt-tripupdates.pb"],
                                                alerts: ["https://api.wmata.com/gtfs/bus-gtfsrt-alerts.pb"], maxAge: 60)),
        FeedDescriptor(id: "marc", name: "MARC Train", detail: "Maryland commuter rail", region: .dc,
                       staticURL: URL(string: "https://mdotmta-gtfs.s3.amazonaws.com/mdotmta_gtfs_marc.zip")!, auth: .none, downloadMB: 0.2),
        FeedDescriptor(id: "vre", name: "Virginia Railway Express", detail: "Virginia commuter rail", region: .dc,
                       staticURL: URL(string: "https://gtfs.vre.org/containercdngtfsupload/google_transit.zip")!, auth: .none, downloadMB: 0.1),
        // National and Dulles are Metrorail stations; BWI is a bus ride from its MARC/Amtrak station.
        BuiltInFeeds.descriptor(.dc, name: "BWI Rail Station Shuttle", detail: "Built in: publishes no schedule"),
    ]

    private static let boston: [FeedDescriptor] = [
        // One feed covers the subway, buses, commuter rail and ferries.
        FeedDescriptor(id: "mbta", name: "MBTA", detail: "Subway, bus, Commuter Rail and ferry", region: .boston,
                       staticURL: URL(string: "https://cdn.mbta.com/MBTA_GTFS.zip")!, auth: .none, downloadMB: 24.9,
                       realtime: RealtimeSource(tripUpdates: ["https://cdn.mbta.com/realtime/TripUpdates.pb"],
                                                alerts: ["https://cdn.mbta.com/realtime/Alerts.pb"])),
        // SL1 to the terminals is in the MBTA feed; the free shuttles from the Blue Line are Massport's.
        BuiltInFeeds.descriptor(.boston, name: "Logan Shuttles", detail: "Built in: Massport's free Blue Line shuttles"),
    ]

    private static let atlanta: [FeedDescriptor] = [
        // Rail, bus and the Atlanta Streetcar share one feed. Its realtime feed only carries buses.
        FeedDescriptor(id: "marta", name: "MARTA", detail: "Rail, bus and Atlanta Streetcar", region: .atlanta,
                       staticURL: URL(string: "https://itsmarta.com/google_transit_feed/google_transit.zip")!, auth: .none, downloadMB: 18.6,
                       realtime: RealtimeSource(tripUpdates: ["https://gtfs-rt.itsmarta.com/TMGTFSRealTimeWebService/tripupdate/tripupdates.pb"],
                                                alerts: ["https://gtfs-rt.itsmarta.com/TMGTFSRealTimeWebService/alert/alerts.pb"], maxAge: 60)),
        BuiltInFeeds.descriptor(.atlanta, name: "ATL SkyTrain", detail: "Built in: Airport to Gateway Center and Rental Car Center"),
    ]
}
