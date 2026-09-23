/// An agency's free transfer between two separate stations: leave one, walk along the street, and enter the other
/// without paying again. Riders who don't know about one pay twice, so a trip that uses it says so.
/// Researched 2026-09-21 for every city in `TransitRegion`; see TRANSFERS.md, and check again when adding a city.
public struct FreeTransfer: Hashable, Sendable {
    public let feedID: String
    /// Parent station ids (stops.txt `stop_id`), in either order.
    public let stations: Set<String>
    /// The agency's name for it, where it has one.
    public let name: String?
    /// What makes it free: "Free with SmarTrip within 30 min".
    public let rule: String

    /// "Farragut Crossing: free with SmarTrip within 30 min", or just the rule.
    public var label: String {
        name.map { "\($0): \(rule.prefix(1).lowercased())\(rule.dropFirst())" } ?? rule
    }

    public static let all: [FreeTransfer] = [
        // Not in WMATA's GTFS: it publishes no transfers.txt.
        FreeTransfer(feedID: "wmata-rail", stations: ["STN_A02", "STN_C03"], name: "Farragut Crossing",
                     rule: "Free with SmarTrip within 30 min"),
        // In the MTA's transfers.txt already, which covers the routing; the fare is what riders don't expect.
        FreeTransfer(feedID: "mta-subway", stations: ["R11", "B08"], name: nil, rule: mtaRule),
        FreeTransfer(feedID: "mta-subway", stations: ["629", "B08"], name: nil, rule: mtaRule),
        FreeTransfer(feedID: "mta-subway", stations: ["254", "L26"], name: nil, rule: mtaRule),
    ]

    private static let mtaRule = "Free transfer with the same OMNY card or MetroCard within 2 hours"

    /// The free transfer for walking from one station to another, if the agency offers one.
    public static func between(feedID: String, _ from: String, _ to: String) -> FreeTransfer? {
        guard from != to else { return nil }
        return all.first { $0.feedID == feedID && $0.stations == [from, to] }
    }
}
