import Foundation

/// Airport links that publish no schedule of their own — people movers and terminal shuttles — carried in
/// the app and written out as GTFS on the phone. Their stops sit on the stations they meet, so the router's
/// walking links join them to the subway and railroads like any other feed.
///
/// They run on headways rather than timetables, so trips are laid out every so many minutes through the
/// day. Times are the operators' published running times; realtime is not available for any of them.
public enum BuiltInFeeds {
    /// Bumped whenever the data below changes, so installed copies are rebuilt.
    public static let version = "builtin-1"

    /// The feed's files, file name to CSV text. Empty for an id that isn't built in.
    public static func files(for feedID: String) -> [String: String] {
        links.filter { $0.feedID == feedID }.gtfs
    }

    static let links: [AirportLink] = [newarkAirTrain, bwiShuttle] + loganShuttles + [skyTrain]

    /// The feed a city carries for its airports.
    static func descriptor(_ region: TransitRegion, name: String, detail: String) -> FeedDescriptor {
        FeedDescriptor(id: feedID(region), name: name, detail: detail, region: region, staticURL: nil, auth: .none, downloadMB: 0)
    }

    static func feedID(_ region: TransitRegion) -> String { "\(region.rawValue)-airport-links" }

    /// Neutral grey: none of these operators publishes a line colour.
    private static let grey = "5B6770"

    // Coordinates are OpenStreetMap's (the SL1 curb stops at Logan are the MBTA's), checked 2026-09-21.
    // Running times and headways are the operators' published figures where they give them, estimates otherwise.

    /// Newark's monorail, from the NJ Transit/Amtrak station to the terminals. Terminal A's station is the old P2,
    /// a shuttle bus ride from the terminal itself. (AirTrain JFK publishes its own GTFS and is downloaded instead.)
    static let newarkAirTrain = AirportLink(
        feedID: feedID(.nyc), routeID: "airtrain-ewr", shortName: "AirTrain", longName: "AirTrain Newark", routeType: 12,
        color: grey, textColor: "FFFFFF",
        stops: [
            .init(id: "ewr-rail", name: "Newark Airport Rail Station (AirTrain)", latitude: 40.70430, longitude: -74.19038),
            .init(id: "ewr-p4", name: "Newark Airport P4", latitude: 40.69675, longitude: -74.18218),
            .init(id: "ewr-c", name: "Newark Airport Terminal C", latitude: 40.69600, longitude: -74.17752),
            .init(id: "ewr-b", name: "Newark Airport Terminal B", latitude: 40.69076, longitude: -74.17663),
            .init(id: "ewr-p3", name: "Newark Airport P3", latitude: 40.68965, longitude: -74.18737),
            .init(id: "ewr-a", name: "Newark Airport Terminal A (P2)", latitude: 40.68735, longitude: -74.19077),
        ],
        runs: [
            .init(headsign: "Terminals", calls: [("ewr-rail", 0), ("ewr-p4", 4), ("ewr-c", 7), ("ewr-b", 11), ("ewr-p3", 14), ("ewr-a", 16)]),
            .init(headsign: "Rail Station", calls: [("ewr-a", 0), ("ewr-p3", 2), ("ewr-b", 5), ("ewr-c", 9), ("ewr-p4", 12), ("ewr-rail", 16)]),
        ],
        // Every 15 min 11 PM to 5 AM; the daytime figure is an estimate.
        headways: [.init(start: 0, end: 5, minutes: 15), .init(start: 5, end: 23, minutes: 5), .init(start: 23, end: 24, minutes: 15)])

    /// The free bus between BWI's rail station (MARC Penn Line, Amtrak) and the terminal's lower level.
    static let bwiShuttle = AirportLink(
        feedID: feedID(.dc), routeID: "bwi-rail-shuttle", shortName: "BWI", longName: "BWI Rail Station Shuttle", routeType: 3,
        color: grey, textColor: "FFFFFF",
        stops: [
            .init(id: "bwi-rail", name: "BWI Rail Station (Shuttle)", latitude: 39.19255, longitude: -76.69428),
            .init(id: "bwi-terminal", name: "BWI Airport Terminal", latitude: 39.18040, longitude: -76.67096),
        ],
        runs: [
            .init(headsign: "BWI Terminal", calls: [("bwi-rail", 0), ("bwi-terminal", 8)]),
            .init(headsign: "Rail Station", calls: [("bwi-terminal", 0), ("bwi-rail", 8)]),
        ],
        // Every 10–15 min, every 25 from 1 to 5 AM.
        headways: [.init(start: 1, end: 5, minutes: 25), .init(start: 5, end: 25, minutes: 12)])

    private static let loganStops: [AirportLink.Stop] = [
        .init(id: "bos-blue", name: "Airport Station Busway (Massport Shuttle)", latitude: 42.37430, longitude: -71.02973),
        .init(id: "bos-rcc", name: "Logan Rental Car Center", latitude: 42.3683, longitude: -71.0288),
        .init(id: "bos-a", name: "Logan Terminal A", latitude: 42.36461, longitude: -71.02086),
        .init(id: "bos-b1", name: "Logan Terminal B (Stop 1)", latitude: 42.36210, longitude: -71.01882),
        .init(id: "bos-b2", name: "Logan Terminal B (Stop 2)", latitude: 42.36210, longitude: -71.01798),
        .init(id: "bos-c", name: "Logan Terminal C", latitude: 42.36650, longitude: -71.01726),
        .init(id: "bos-e", name: "Logan Terminal E", latitude: 42.36949, longitude: -71.02017),
        .init(id: "bos-garage", name: "Logan Economy Garage", latitude: 42.37564, longitude: -71.02571),
    ]

    /// Massport's free shuttles between the Blue Line and the terminals. Each is a one-way loop, laid out here as
    /// the half from the station round to the terminals and the half from the terminals back to it. 22 and 33 run
    /// by day, 55 overnight in their place, 88 around the clock from the Economy Garage.
    static let loganShuttles: [AirportLink] = [
        logan("22", "Blue Line – Terminals A, B", headways: [.init(start: 9, end: 22, minutes: 5)],
              out: [("bos-blue", 0), ("bos-rcc", 4), ("bos-a", 8), ("bos-b1", 11), ("bos-b2", 12)],
              back: [("bos-a", 0), ("bos-b1", 3), ("bos-b2", 4), ("bos-blue", 9)]),
        logan("33", "Blue Line – Terminals C, E", headways: [.init(start: 9, end: 22, minutes: 7)],
              out: [("bos-blue", 0), ("bos-rcc", 4), ("bos-c", 9), ("bos-e", 12)],
              back: [("bos-c", 0), ("bos-e", 3), ("bos-blue", 7)]),
        logan("55", "Blue Line – All Terminals", headways: [.init(start: 22, end: 33, minutes: 6)],
              out: [("bos-blue", 0), ("bos-rcc", 4), ("bos-a", 8), ("bos-b1", 11), ("bos-b2", 12), ("bos-c", 15), ("bos-e", 18)],
              back: [("bos-a", 0), ("bos-b1", 3), ("bos-b2", 4), ("bos-c", 7), ("bos-e", 10), ("bos-blue", 14)]),
        // Calls at the Blue Line only on the way in to the terminals.
        logan("88", "Economy Garage – All Terminals", headways: [.init(start: 0, end: 24, minutes: 8)],
              out: [("bos-garage", 0), ("bos-blue", 3), ("bos-a", 7), ("bos-b1", 10), ("bos-b2", 11), ("bos-c", 14), ("bos-e", 17)],
              back: [("bos-a", 0), ("bos-b1", 3), ("bos-b2", 4), ("bos-c", 7), ("bos-e", 10), ("bos-garage", 14)]),
    ]

    private static func logan(_ number: String, _ name: String, headways: [AirportLink.Headway],
                              out: [(stop: String, minutes: Double)], back: [(stop: String, minutes: Double)]) -> AirportLink {
        let used = Set((out + back).map(\.stop))
        return AirportLink(feedID: feedID(.boston), routeID: "massport-\(number)", shortName: number, longName: "Massport Shuttle \(name)",
                           routeType: 3, color: grey, textColor: "FFFFFF", stops: loganStops.filter { used.contains($0.id) },
                           runs: [.init(headsign: "Terminals", calls: out), .init(headsign: back.last?.stop == "bos-blue" ? "Airport Station" : "Economy Garage", calls: back)],
                           headways: headways)
    }

    /// Hartsfield-Jackson's landside people mover, from the MARTA end of the Domestic Terminal to the Gateway Center
    /// and the Rental Car Center. (MARTA's Airport station is inside the terminal, and is in MARTA's own feed.)
    static let skyTrain = AirportLink(
        feedID: feedID(.atlanta), routeID: "atl-skytrain", shortName: "SkyTrain", longName: "ATL SkyTrain", routeType: 12,
        color: grey, textColor: "FFFFFF",
        stops: [
            .init(id: "atl-airport", name: "ATL SkyTrain Airport", latitude: 33.64084, longitude: -84.44683),
            .init(id: "atl-gateway", name: "ATL SkyTrain Gateway Center", latitude: 33.64389, longitude: -84.45667),
            .init(id: "atl-rcc", name: "ATL SkyTrain Rental Car Center", latitude: 33.63987, longitude: -84.46445),
        ],
        runs: [
            .init(headsign: "Rental Car Center", calls: [("atl-airport", 0), ("atl-gateway", 3), ("atl-rcc", 5)]),
            .init(headsign: "Airport", calls: [("atl-rcc", 0), ("atl-gateway", 2), ("atl-airport", 5)]),
        ],
        // Every 2–3 min, every 10 from 11 PM to 4 AM.
        headways: [.init(start: 4, end: 23, minutes: 3), .init(start: 23, end: 28, minutes: 10)])
}

/// One vehicle service: where it stops, how long it takes between them, and how often it runs.
struct AirportLink {
    struct Stop {
        let id: String
        let name: String
        let latitude: Double
        let longitude: Double
    }

    /// Minutes between vehicles from `start` until `end` (hours after midnight; `end` may pass 24).
    struct Headway {
        let start: Double
        let end: Double
        let minutes: Double
    }

    /// One direction of travel: the stops in order, each with minutes from the first.
    struct Run {
        let headsign: String
        let calls: [(stop: String, minutes: Double)]
    }

    let feedID: String
    let routeID: String
    /// What the bullet says.
    let shortName: String
    let longName: String
    /// GTFS route_type: 3 for a shuttle bus, 12 (monorail) for a people mover.
    let routeType: Int
    let color: String
    let textColor: String
    let stops: [Stop]
    let runs: [Run]
    let headways: [Headway]
}

extension [AirportLink] {
    /// Every link in one feed, written out as GTFS.
    var gtfs: [String: String] {
        guard !isEmpty else { return [:] }
        var stops = ["stop_id,stop_name,stop_lat,stop_lon,location_type"]
        var routes = ["route_id,route_short_name,route_long_name,route_type,route_color,route_text_color"]
        var trips = ["route_id,service_id,trip_id,trip_headsign,direction_id"]
        var stopTimes = ["trip_id,arrival_time,departure_time,stop_id,stop_sequence"]
        var seenStops = Set<String>()

        for link in self {
            for stop in link.stops where seenStops.insert(stop.id).inserted {
                stops.append([stop.id, csv(stop.name), String(format: "%.5f", stop.latitude), String(format: "%.5f", stop.longitude), "0"].joined(separator: ","))
            }
            routes.append([link.routeID, csv(link.shortName), csv(link.longName), String(link.routeType), link.color, link.textColor].joined(separator: ","))
            for (direction, run) in link.runs.enumerated() {
                for start in link.departures() {
                    let tripID = "\(link.routeID)-\(direction)-\(start)"
                    trips.append([link.routeID, "daily", tripID, csv(run.headsign), String(direction)].joined(separator: ","))
                    for (sequence, call) in run.calls.enumerated() {
                        let time = gtfsTime(start + Int((call.minutes * 60).rounded()))
                        stopTimes.append([tripID, time, time, call.stop, String(sequence + 1)].joined(separator: ","))
                    }
                }
            }
        }
        return [
            "stops.txt": stops.joined(separator: "\n"),
            "routes.txt": routes.joined(separator: "\n"),
            "trips.txt": trips.joined(separator: "\n"),
            "stop_times.txt": stopTimes.joined(separator: "\n"),
            // Every day, for longer than any copy of the app will be in use.
            "calendar.txt": "service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\ndaily,1,1,1,1,1,1,1,20250101,20391231",
            "feed_info.txt": "feed_publisher_name,feed_version\nComplexCommute,\(BuiltInFeeds.version)",
        ]
    }

    private func csv(_ text: String) -> String {
        text.contains(",") || text.contains("\"") ? "\"\(text.replacingOccurrences(of: "\"", with: "\"\""))\"" : text
    }

    private func gtfsTime(_ seconds: Int) -> String {
        String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
}

extension AirportLink {
    /// Seconds after midnight each vehicle leaves the first stop of a run.
    func departures() -> [Int] {
        var times: [Int] = []
        for band in headways {
            var time = Int((band.start * 3600).rounded())
            let end = Int((band.end * 3600).rounded())
            let step = Swift.max(60, Int((band.minutes * 60).rounded()))
            while time < end {
                times.append(time)
                time += step
            }
        }
        return times
    }
}
