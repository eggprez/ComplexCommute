import CommuteCore
import Foundation

/// The set of imported feeds on disk: one SQLite file per feed in `directory`.
/// An actor so imports and searches never touch a connection concurrently.
public actor FeedLibrary {
    private let directory: URL
    /// A reader that isn't the library's keeper (a widget) leaves files it can't open alone: the app may be
    /// part-way through writing one.
    private let isReadOnly: Bool
    private var open: [String: FeedDatabase] = [:]
    private var didScan = false
    /// Changes whenever a feed is installed or removed, so routers know to rebuild their timetables.
    public private(set) var revision = 0

    public init(directory: URL, isReadOnly: Bool = false) {
        self.directory = directory
        self.isReadOnly = isReadOnly
    }

    public func installedFeeds() -> [FeedInfo] {
        scanIfNeeded()
        return open.values.compactMap { try? $0.info() }.sorted { $0.feedID < $1.feedID }
    }

    /// Imports a downloaded GTFS zip, replacing any installed copy of the same feed.
    /// The import itself runs off the actor, so searches stay responsive during a long import.
    public nonisolated func install(feedID: String, zip: URL, progress: @escaping @Sendable (ImportProgress) -> Void = { _ in }) async throws -> FeedInfo {
        let url = await prepareInstall(feedID: feedID)
        try GTFSImporter.importFeed(zip: zip, to: url, feedID: feedID, progress: progress)
        return try await finishInstall(feedID: feedID)
    }

    /// Installs a feed the app carries itself (see `BuiltInFeeds`), replacing any installed copy.
    public nonisolated func install(feedID: String, files: [String: String]) async throws -> FeedInfo {
        let url = await prepareInstall(feedID: feedID)
        try GTFSImporter.importFeed(files: files, to: url, feedID: feedID)
        return try await finishInstall(feedID: feedID)
    }

    private func prepareInstall(feedID: String) -> URL {
        scanIfNeeded()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return databaseURL(for: feedID)
    }

    /// Swaps the read connection over to the freshly imported file.
    private func finishInstall(feedID: String) throws -> FeedInfo {
        let database = try FeedDatabase(url: databaseURL(for: feedID))
        open[feedID] = database
        revision += 1
        return try database.info()
    }

    public func remove(feedID: String) throws {
        scanIfNeeded()
        open[feedID] = nil
        revision += 1
        try FileManager.default.removeItem(at: databaseURL(for: feedID))
    }

    /// Name search across every installed feed: prefix matches first, then nearest to `location`.
    public func searchStops(matching query: String, near location: Coordinate? = nil, limit: Int = 25) -> [TransitStop] {
        scanIfNeeded()
        let needle = query.lowercased().trimmingCharacters(in: .whitespaces)
        let matches = open.values.flatMap { (try? $0.searchStops(matching: query, limit: 200)) ?? [] }

        func rank(_ stop: TransitStop) -> (Int, Double, String) {
            let isPrefix = stop.name.lowercased().hasPrefix(needle)
            let distance = location.map { stop.coordinate.distance(to: $0) } ?? 0
            return (isPrefix ? 0 : 1, distance, stop.name)
        }
        return Array(matches.sorted { rank($0) < rank($1) }.prefix(limit))
    }

    public func stops(near center: Coordinate, radiusMeters: Double = 1200, limit: Int = 8) -> [TransitStop] {
        scanIfNeeded()
        return Array(open.values
            .flatMap { (try? $0.stops(near: center, radiusMeters: radiusMeters, limit: limit)) ?? [] }
            .sorted { $0.coordinate.distance(to: center) < $1.coordinate.distance(to: center) }
            .prefix(limit))
    }

    /// Installed feeds that operate near any of `coordinates`.
    public func feedIDs(near coordinates: [Coordinate], marginMeters: Double = 40_000) -> [String] {
        scanIfNeeded()
        return open.values
            .filter { feed in coordinates.contains { feed.covers($0, marginMeters: marginMeters) } }
            .map(\.feedID)
            .sorted()
    }

    public func timetableData(for days: [ServiceDay], feedIDs: [String]) -> [FeedTimetableData] {
        scanIfNeeded()
        return feedIDs.compactMap { open[$0] }.compactMap { try? $0.timetableData(for: days) }
    }

    /// The schedules of only the trips calling at the given stops of each feed within `window` (seconds from the
    /// base day's midnight): enough for departure boards, at a fraction of the memory of a whole network.
    public func timetableData(for days: [ServiceDay], callingAt stopIDs: [String: [String]], between window: Range<Int>) -> [FeedTimetableData] {
        scanIfNeeded()
        return stopIDs.keys.sorted().compactMap { feedID in
            try? open[feedID]?.timetableData(for: days, callingAt: stopIDs[feedID] ?? [], between: window)
        }
    }

    /// Gives schedules imported before boards could be read stop by stop the index that makes that cheap.
    /// Runs off the actor: building one takes a few seconds for a city's buses, and searches shouldn't wait on it.
    public nonisolated func indexForBoards() async {
        for url in await filesWithoutBoardIndex() {
            guard let database = try? SQLiteDatabase(url: url) else { continue }
            // Losing a race with a reader just leaves it for the next launch.
            try? database.execute("PRAGMA busy_timeout = 2000; \(GTFSImporter.boardIndex);")
            // A network built while the file was being written to may have missed it.
            await noteChange()
        }
    }

    private func noteChange() {
        revision += 1
    }

    private func filesWithoutBoardIndex() -> [URL] {
        scanIfNeeded()
        return open.values.filter { !$0.hasBoardIndex }.map { databaseURL(for: $0.feedID) }
    }

    /// The path trips with this shape follow, or nil when the feed has none.
    public func shape(feedID: String, index: Int) -> [Coordinate]? {
        scanIfNeeded()
        return try? open[feedID]?.shape(index)
    }

    private func databaseURL(for feedID: String) -> URL {
        directory.appendingPathComponent(feedID).appendingPathExtension("sqlite")
    }

    private func scanIfNeeded() {
        guard !didScan else { return }
        didScan = true
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "sqlite" {
            // Feeds imported by a schema too old to read are dropped; the app offers them for download again.
            guard let database = try? FeedDatabase(url: file), database.isUsableSchema else {
                if !isReadOnly { try? FileManager.default.removeItem(at: file) }
                continue
            }
            open[database.feedID] = database
        }
    }
}
