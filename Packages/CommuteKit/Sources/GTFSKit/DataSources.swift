import Foundation

/// An agency whose published data the app uses, and how its developer terms ask to be credited.
///
/// Wording follows each agency's terms (checked 2026-09): MassDOT's license requires the MBTA's data to be
/// credited to MassDOT; MTA and NJ TRANSIT forbid implying the app is licensed by them or that the data
/// is accurate, complete or timely; WMATA, VRE, MARTA and the Port Authority forbid implying endorsement
/// or using their marks. So the app names agencies in plain text only, and never shows their logos.
public struct DataSource: Identifiable, Hashable, Sendable {
    public let id: String
    public let agency: String
    /// What the agency's data covers in the app.
    public let services: String
    public let credit: String
    /// Nil for data the app compiled itself.
    public let termsURL: URL?
    /// The catalog feeds this agency publishes.
    public let feedIDs: [String]

    public var regions: [TransitRegion] {
        let regions = Set(feedIDs.compactMap { FeedCatalog.feed(id: $0)?.region })
        return TransitRegion.allCases.filter(regions.contains)
    }
}

public enum DataSources {
    /// Shown above the agency list, and in the App Store description.
    public static let disclaimer = """
        Schedules, real-time predictions and service alerts come from public data published by the transit agencies below. \
        It may not be real time, and may be inaccurate, incomplete or delayed. It is provided as is, without warranty. \
        ComplexCommute is independent and is not affiliated with, endorsed by or licensed by any transit agency.
        """

    public static let all: [DataSource] = [
        DataSource(id: "mta", agency: "Metropolitan Transportation Authority (MTA)",
                   services: "Subway, buses, Long Island Rail Road and Metro-North",
                   credit: "Schedule, real-time and service alert data from the MTA. Not endorsed by the MTA.",
                   termsURL: URL(string: "https://www.mta.info/developers/terms-and-conditions")!,
                   feedIDs: FeedCatalog.feeds.map(\.id).filter { $0.hasPrefix("mta-") }),
        DataSource(id: "path", agency: "Port Authority of New York and New Jersey",
                   services: "PATH",
                   credit: "PATH schedule data from the Port Authority of New York and New Jersey. Not endorsed by the Port Authority.",
                   termsURL: URL(string: "https://www.panynj.gov/path/en/index.html")!,
                   feedIDs: ["path"]),
        DataSource(id: "njt", agency: "NJ TRANSIT",
                   services: "Rail, light rail and bus",
                   credit: "NJ TRANSIT schedule data, used under the NJ TRANSIT Developer Terms. Not endorsed by NJ TRANSIT.",
                   termsURL: URL(string: "https://developer.njtransit.com/terms/")!,
                   feedIDs: ["njt-rail", "njt-bus"]),
        DataSource(id: "wmata", agency: "Washington Metropolitan Area Transit Authority (WMATA)",
                   services: "Metrorail and Metrobus",
                   credit: "Metrorail and Metrobus data from WMATA, provided as is. Not endorsed by WMATA.",
                   termsURL: URL(string: "https://developer.wmata.com/license")!,
                   feedIDs: ["wmata-rail", "wmata-bus"]),
        DataSource(id: "mdot-mta", agency: "Maryland Transit Administration (MDOT MTA)",
                   services: "MARC Train",
                   credit: "MARC data from MDOT MTA, which does not guarantee its accuracy or endorse this app.",
                   termsURL: URL(string: "https://www.mta.maryland.gov/developer-resources")!,
                   feedIDs: ["marc"]),
        DataSource(id: "vre", agency: "Virginia Railway Express (VRE)",
                   services: "VRE commuter rail",
                   credit: "VRE schedule data from Virginia Railway Express, provided as is. Not endorsed by VRE.",
                   termsURL: URL(string: "https://www.vre.org/assets/1/6/VRE_Mobile_Developer_2024.pdf")!,
                   feedIDs: ["vre"]),
        DataSource(id: "massdot", agency: "Massachusetts Department of Transportation (MassDOT)",
                   services: "MBTA subway, bus, Commuter Rail and ferry",
                   credit: "MBTA data provided by the Massachusetts Department of Transportation (MassDOT).",
                   termsURL: URL(string: "https://www.mbta.com/developers")!,
                   feedIDs: ["mbta"]),
        DataSource(id: "marta", agency: "Metropolitan Atlanta Rapid Transit Authority (MARTA)",
                   services: "Rail, bus and Atlanta Streetcar",
                   credit: "MARTA schedule, real-time and service alert data from MARTA. Not endorsed by MARTA.",
                   termsURL: URL(string: "https://itsmarta.com/app-developer-resources.aspx")!,
                   feedIDs: ["marta"]),
        DataSource(id: "511ny", agency: "511NY (New York State Department of Transportation)",
                   services: "AirTrain JFK",
                   credit: "AirTrain JFK schedule data from 511NY, provided as is. Not endorsed by NYSDOT or the Port Authority.",
                   termsURL: URL(string: "https://511ny.org/developers/help")!,
                   feedIDs: ["airtrain-jfk"]),
        DataSource(id: "builtin", agency: "Airport links (compiled by ComplexCommute)",
                   services: "AirTrain Newark, Massport's Logan shuttles, the BWI rail station shuttle and the ATL SkyTrain",
                   credit: """
                       These operators publish no schedules. Their stops and running times come from their public service \
                       information and are estimates: vehicles run every few minutes rather than at the times shown.
                       """,
                   termsURL: nil,
                   feedIDs: FeedCatalog.feeds.filter(\.isBuiltIn).map(\.id)),
    ]

    public static func source(forFeed feedID: String) -> DataSource? {
        all.first { $0.feedIDs.contains(feedID) }
    }
}
