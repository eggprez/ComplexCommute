import CommuteCore
import Foundation

public struct RouteBadge: Codable, Hashable, Sendable {
    public let name: String
    /// "RRGGBB", as published by the agency.
    public let colorHex: String?
    public let textColorHex: String?
    /// GTFS route_type (0 tram, 1 subway, 2 rail, 3 bus, ...).
    public let type: Int

    public init(name: String, colorHex: String? = nil, textColorHex: String? = nil, type: Int = 1) {
        self.name = name
        self.colorHex = colorHex
        self.textColorHex = textColorHex
        self.type = type
    }
}

public struct TransitStop: Hashable, Identifiable, Sendable {
    public let feedID: String
    public let stopID: String
    public let name: String
    public let coordinate: Coordinate
    public let routes: [RouteBadge]

    public var id: String { "\(feedID):\(stopID)" }
}

public struct FeedInfo: Hashable, Sendable {
    public let feedID: String
    public let version: String?
    public let importedAt: Date
    public let stopCount: Int
    public let routeCount: Int
    public let fileSize: Int
    /// Last day covered by the feed's calendar (yyyymmdd). Past it, plans reuse the final published week.
    public let lastServiceDate: Int?
    /// False for a file imported before route shapes were kept; its rides are drawn stop to stop until it is refreshed.
    public let hasShapes: Bool

    public func isExpired(on date: Date = .now, calendar: Calendar = .current) -> Bool {
        guard let lastServiceDate else { return false }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return (parts.year ?? 0) * 10_000 + (parts.month ?? 0) * 100 + (parts.day ?? 0) > lastServiceDate
    }
}

/// Read-only access to one imported feed.
final class FeedDatabase {
    let feedID: String
    struct BoundingBox {
        let minLatitude, maxLatitude, minLongitude, maxLongitude: Double
    }

    let database: SQLiteDatabase
    private let url: URL
    private(set) lazy var boundingBox: BoundingBox? = loadBoundingBox()

    init(url: URL) throws {
        self.url = url
        database = try SQLiteDatabase(url: url, readOnly: true)
        feedID = try Self.meta("feed_id", in: database) ?? url.deletingPathExtension().lastPathComponent
    }

    private(set) lazy var schemaVersion = (try? Self.meta("schema_version", in: database)).flatMap { $0 }.flatMap(Int.init) ?? 0

    var isUsableSchema: Bool {
        (GTFSImporter.oldestUsableSchemaVersion...GTFSImporter.schemaVersion).contains(schemaVersion)
    }

    var hasShapes: Bool { schemaVersion >= 2 }

    /// Where trips with this shape run, in travel order.
    func shape(_ index: Int) throws -> [Coordinate]? {
        guard hasShapes else { return nil }
        let statement = try database.prepare("SELECT points FROM shapes WHERE shape_idx = ?")
        statement.bind(index, at: 1)
        return try statement.step() ? statement.data(0).map(ShapeCoding.path) : nil
    }

    func info() throws -> FeedInfo {
        let importedAt = try Self.meta("imported_at", in: database).flatMap(TimeInterval.init) ?? 0
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return FeedInfo(
            feedID: feedID,
            version: try Self.meta("feed_version", in: database),
            importedAt: Date(timeIntervalSince1970: importedAt),
            stopCount: try count("SELECT COUNT(*) FROM stops WHERE searchable = 1"),
            routeCount: try count("SELECT COUNT(*) FROM routes"),
            fileSize: size,
            lastServiceDate: try lastServiceDate(),
            hasShapes: hasShapes
        )
    }

    /// Stations and standalone stops whose name contains every word of `query`.
    func searchStops(matching query: String, limit: Int) throws -> [TransitStop] {
        let words = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !words.isEmpty else { return [] }
        let conditions = words.map { _ in "name LIKE ? ESCAPE '\\'" }.joined(separator: " AND ")
        let statement = try database.prepare("SELECT stop_idx, stop_id, name, lat, lon FROM stops WHERE searchable = 1 AND \(conditions) LIMIT ?")
        for (index, word) in words.enumerated() {
            let escaped = word.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            statement.bind("%\(escaped)%", at: Int32(index + 1))
        }
        statement.bind(limit, at: Int32(words.count + 1))
        return try stops(from: statement)
    }

    func stops(near center: Coordinate, radiusMeters: Double, limit: Int) throws -> [TransitStop] {
        let latitudeSpan = radiusMeters / 111_000
        let longitudeSpan = latitudeSpan / max(0.1, cos(center.latitude * .pi / 180))
        let statement = try database.prepare("""
            SELECT stop_idx, stop_id, name, lat, lon FROM stops
            WHERE searchable = 1 AND lat BETWEEN ? AND ? AND lon BETWEEN ? AND ?
            """)
        statement.bind(center.latitude - latitudeSpan, at: 1)
        statement.bind(center.latitude + latitudeSpan, at: 2)
        statement.bind(center.longitude - longitudeSpan, at: 3)
        statement.bind(center.longitude + longitudeSpan, at: 4)
        return try stops(from: statement)
            .filter { $0.coordinate.distance(to: center) <= radiusMeters }
            .sorted { $0.coordinate.distance(to: center) < $1.coordinate.distance(to: center) }
            .prefix(limit)
            .map { $0 }
    }

    private func stops(from statement: SQLiteStatement) throws -> [TransitStop] {
        var rows: [(index: Int, id: String, name: String, coordinate: Coordinate)] = []
        while try statement.step() {
            rows.append((statement.int(0), statement.string(1) ?? "", statement.string(2) ?? "",
                         Coordinate(latitude: statement.double(3), longitude: statement.double(4))))
        }

        let routes = try database.prepare("""
            SELECT r.short_name, r.long_name, r.color, r.text_color, r.type FROM stop_routes sr
            JOIN routes r ON r.route_idx = sr.route_idx WHERE sr.stop_idx = ?
            ORDER BY r.sort_order, r.short_name, r.long_name
            """)
        return try rows.map { row in
            routes.reset()
            routes.bind(row.index, at: 1)
            var badges: [RouteBadge] = []
            while try routes.step() {
                let name = routes.string(0) ?? routes.string(1) ?? ""
                let badge = RouteBadge(name: name, colorHex: routes.string(2), textColorHex: routes.string(3), type: routes.int(4))
                // Express/local variants often share a displayed name (e.g. two "1" routes).
                if !badges.contains(where: { $0.name == badge.name }) {
                    badges.append(badge)
                }
            }
            // NYC publishes expresses as separate "6X"/"7X" routes; riders think of them as the 6 and 7.
            let names = Set(badges.map(\.name))
            badges.removeAll { $0.name.count > 1 && $0.name.hasSuffix("X") && names.contains(String($0.name.dropLast())) }
            return TransitStop(feedID: feedID, stopID: row.id, name: row.name, coordinate: row.coordinate, routes: badges)
        }
    }

    private func count(_ sql: String) throws -> Int {
        let statement = try database.prepare(sql)
        return try statement.step() ? statement.int(0) : 0
    }

    private static func meta(_ key: String, in database: SQLiteDatabase) throws -> String? {
        let statement = try database.prepare("SELECT value FROM meta WHERE key = ?")
        statement.bind(key, at: 1)
        return try statement.step() ? statement.string(0) : nil
    }
}
