import Foundation

public enum GTFSImportError: Error, Equatable {
    case missingFile(String)
    case missingColumn(file: String, column: String)
}

public struct ImportProgress: Sendable {
    /// GTFS file being read, or nil while building indexes.
    public let file: String?
    /// Overall completion, 0...1, weighted by uncompressed file sizes.
    public let fraction: Double
}

/// Converts a GTFS zip into one compact SQLite file. String ids become dense integer indexes so the
/// multi-million-row stop_times table stays small and the router can load it straight into arrays.
public enum GTFSImporter {
    static let schemaVersion = 1

    private static let schema = """
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT) WITHOUT ROWID;
        CREATE TABLE routes (route_idx INTEGER PRIMARY KEY, route_id TEXT NOT NULL, short_name TEXT, long_name TEXT,
            type INTEGER NOT NULL, color TEXT, text_color TEXT, sort_order INTEGER);
        CREATE TABLE stops (stop_idx INTEGER PRIMARY KEY, stop_id TEXT NOT NULL, name TEXT NOT NULL, lat REAL NOT NULL,
            lon REAL NOT NULL, location_type INTEGER NOT NULL, parent_id TEXT, parent_idx INTEGER, searchable INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE services (service_idx INTEGER PRIMARY KEY, service_id TEXT NOT NULL);
        CREATE TABLE calendar (service_idx INTEGER PRIMARY KEY, weekdays INTEGER NOT NULL, start_date INTEGER NOT NULL, end_date INTEGER NOT NULL);
        CREATE TABLE calendar_dates (service_idx INTEGER NOT NULL, date INTEGER NOT NULL, exception_type INTEGER NOT NULL);
        CREATE TABLE trips (trip_idx INTEGER PRIMARY KEY, trip_id TEXT NOT NULL, route_idx INTEGER NOT NULL,
            service_idx INTEGER NOT NULL, headsign TEXT, direction INTEGER);
        CREATE TABLE stop_times (trip_idx INTEGER NOT NULL, seq INTEGER NOT NULL, stop_idx INTEGER NOT NULL,
            arrival INTEGER, departure INTEGER, pickup_type INTEGER NOT NULL, drop_off_type INTEGER NOT NULL,
            PRIMARY KEY (trip_idx, seq)) WITHOUT ROWID;
        CREATE TABLE transfers (from_stop_idx INTEGER NOT NULL, to_stop_idx INTEGER NOT NULL, type INTEGER NOT NULL, min_time INTEGER);
        CREATE TABLE stop_routes (stop_idx INTEGER NOT NULL, route_idx INTEGER NOT NULL, PRIMARY KEY (stop_idx, route_idx)) WITHOUT ROWID;
        """

    /// Imports into a temporary file and moves it into place only on success, so a failed or
    /// cancelled update never damages the feed that is already installed.
    public static func importFeed(zip zipURL: URL, to databaseURL: URL, feedID: String,
                                  progress: (ImportProgress) -> Void = { _ in }) throws {
        let temporaryURL = databaseURL.appendingPathExtension("importing")
        try? FileManager.default.removeItem(at: temporaryURL)
        do {
            try build(zip: zipURL, at: temporaryURL, feedID: feedID, progress: progress)
            if FileManager.default.fileExists(atPath: databaseURL.path) {
                _ = try FileManager.default.replaceItemAt(databaseURL, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: databaseURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    private static func build(zip zipURL: URL, at url: URL, feedID: String, progress: (ImportProgress) -> Void) throws {
        let archive = try ZipArchive(url: zipURL)
        let database = try SQLiteDatabase(url: url)
        // The file is disposable until it's moved into place, so trade durability for speed.
        try database.execute("PRAGMA journal_mode = OFF; PRAGMA synchronous = OFF; PRAGMA page_size = 8192;")
        try database.execute(schema)
        try database.execute("BEGIN")

        let files = ["routes.txt", "stops.txt", "calendar.txt", "calendar_dates.txt", "trips.txt", "stop_times.txt", "transfers.txt", "feed_info.txt"]
        let totalBytes = max(1, files.reduce(0) { $0 + (archive.entries[$1]?.uncompressedSize ?? 0) })
        var completedBytes = 0

        /// Streams one GTFS file through `makeHandler`'s row callback. Returns false if the file is absent.
        @discardableResult
        func load(_ file: String, required: Bool = false, _ makeHandler: (CSVHeader) throws -> (CSVRow) throws -> Void) throws -> Bool {
            guard let entry = archive.entries[file] else {
                if required { throw GTFSImportError.missingFile(file) }
                return false
            }
            var parser = CSVParser()
            var handler: ((CSVRow) throws -> Void)?
            var bytesRead = 0
            try withoutActuallyEscaping(makeHandler) { makeHandler in
                let onRow: (CSVRow) throws -> Void = { row in
                    if let handler {
                        try handler(row)
                    } else {
                        handler = try makeHandler(CSVHeader(row))
                    }
                }
                try archive.read(file) { chunk in
                    try Task.checkCancellation()
                    try parser.parse(chunk, onRow: onRow)
                    bytesRead += chunk.count
                    progress(ImportProgress(file: file, fraction: 0.9 * Double(completedBytes + bytesRead) / Double(totalBytes)))
                }
                try parser.finish(onRow: onRow)
            }
            completedBytes += entry.uncompressedSize
            return true
        }

        func column(_ header: CSVHeader, _ name: String, in file: String) throws -> Int {
            guard header.has(name) else { throw GTFSImportError.missingColumn(file: file, column: name) }
            return header[name]
        }

        var routeIndexes: [String: Int] = [:]
        var stopIndexes: [String: Int] = [:]
        var serviceIndexes: [String: Int] = [:]
        var tripIndexes: [String: Int] = [:]

        let insertService = try database.prepare("INSERT INTO services VALUES (?, ?)")
        func serviceIndex(_ id: String) throws -> Int {
            if let index = serviceIndexes[id] { return index }
            let index = serviceIndexes.count
            serviceIndexes[id] = index
            insertService.bind(index, at: 1)
            insertService.bind(id, at: 2)
            try insertService.run()
            return index
        }

        // routes.txt
        let insertRoute = try database.prepare("INSERT INTO routes VALUES (?, ?, ?, ?, ?, ?, ?, ?)")
        try load("routes.txt", required: true) { header in
            let id = try column(header, "route_id", in: "routes.txt")
            let (shortName, longName, type) = (header["route_short_name"], header["route_long_name"], header["route_type"])
            let (color, textColor, sortOrder) = (header["route_color"], header["route_text_color"], header["route_sort_order"])
            return { row in
                let index = routeIndexes.count
                routeIndexes[row.string(id)] = index
                insertRoute.bind(index, at: 1)
                insertRoute.bind(row.field(id), at: 2)
                insertRoute.bind(row.field(shortName), at: 3)
                insertRoute.bind(row.field(longName), at: 4)
                insertRoute.bind(row.int(type) ?? 3, at: 5)
                insertRoute.bind(row.field(color), at: 6)
                insertRoute.bind(row.field(textColor), at: 7)
                insertRoute.bind(row.int(sortOrder), at: 8)
                try insertRoute.run()
            }
        }

        // stops.txt
        let insertStop = try database.prepare("INSERT INTO stops (stop_idx, stop_id, name, lat, lon, location_type, parent_id) VALUES (?, ?, ?, ?, ?, ?, ?)")
        try load("stops.txt", required: true) { header in
            let id = try column(header, "stop_id", in: "stops.txt")
            let (name, lat, lon) = (header["stop_name"], header["stop_lat"], header["stop_lon"])
            let (locationType, parent) = (header["location_type"], header["parent_station"])
            return { row in
                // Entrances, generic nodes and boarding areas have no schedule role; stops without coordinates can't be mapped.
                let kind = row.int(locationType) ?? 0
                guard kind <= 1, let latitude = row.double(lat), let longitude = row.double(lon) else { return }
                let index = stopIndexes.count
                stopIndexes[row.string(id)] = index
                insertStop.bind(index, at: 1)
                insertStop.bind(row.field(id), at: 2)
                insertStop.bind(row.nonEmptyString(name) ?? row.string(id), at: 3)
                insertStop.bind(latitude, at: 4)
                insertStop.bind(longitude, at: 5)
                insertStop.bind(kind, at: 6)
                insertStop.bind(row.field(parent), at: 7)
                try insertStop.run()
            }
        }
        try database.execute("""
            CREATE UNIQUE INDEX stops_by_id ON stops (stop_id);
            UPDATE stops SET parent_idx = (SELECT p.stop_idx FROM stops p WHERE p.stop_id = stops.parent_id) WHERE parent_id IS NOT NULL;
            """)

        // calendar.txt + calendar_dates.txt (a feed may have either or both)
        let insertCalendar = try database.prepare("INSERT OR REPLACE INTO calendar VALUES (?, ?, ?, ?)")
        let hasCalendar = try load("calendar.txt") { header in
            let service = try column(header, "service_id", in: "calendar.txt")
            let days = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"].map { header[$0] }
            let (start, end) = (header["start_date"], header["end_date"])
            return { row in
                // Bit 0 = Monday ... bit 6 = Sunday.
                let weekdays = days.enumerated().reduce(0) { $0 | ((row.int($1.element) ?? 0) == 1 ? 1 << $1.offset : 0) }
                insertCalendar.bind(try serviceIndex(row.string(service)), at: 1)
                insertCalendar.bind(weekdays, at: 2)
                insertCalendar.bind(row.int(start) ?? 0, at: 3)
                insertCalendar.bind(row.int(end) ?? 99_991_231, at: 4)
                try insertCalendar.run()
            }
        }
        let insertCalendarDate = try database.prepare("INSERT INTO calendar_dates VALUES (?, ?, ?)")
        let hasCalendarDates = try load("calendar_dates.txt") { header in
            let service = try column(header, "service_id", in: "calendar_dates.txt")
            let date = try column(header, "date", in: "calendar_dates.txt")
            let exception = header["exception_type"]
            return { row in
                guard let day = row.int(date) else { return }
                insertCalendarDate.bind(try serviceIndex(row.string(service)), at: 1)
                insertCalendarDate.bind(day, at: 2)
                insertCalendarDate.bind(row.int(exception) ?? 1, at: 3)
                try insertCalendarDate.run()
            }
        }
        guard hasCalendar || hasCalendarDates else { throw GTFSImportError.missingFile("calendar.txt") }

        // trips.txt
        let insertTrip = try database.prepare("INSERT INTO trips VALUES (?, ?, ?, ?, ?, ?)")
        try load("trips.txt", required: true) { header in
            let id = try column(header, "trip_id", in: "trips.txt")
            let route = try column(header, "route_id", in: "trips.txt")
            let service = try column(header, "service_id", in: "trips.txt")
            let (headsign, direction) = (header["trip_headsign"], header["direction_id"])
            return { row in
                guard let routeIndex = routeIndexes[row.string(route)] else { return }
                let index = tripIndexes.count
                tripIndexes[row.string(id)] = index
                insertTrip.bind(index, at: 1)
                insertTrip.bind(row.field(id), at: 2)
                insertTrip.bind(routeIndex, at: 3)
                insertTrip.bind(try serviceIndex(row.string(service)), at: 4)
                insertTrip.bind(row.field(headsign), at: 5)
                insertTrip.bind(row.int(direction), at: 6)
                try insertTrip.run()
            }
        }

        // stop_times.txt — the big one. Rows are normally grouped by trip, so remember the last lookup.
        let insertStopTime = try database.prepare("INSERT OR IGNORE INTO stop_times VALUES (?, ?, ?, ?, ?, ?, ?)")
        try load("stop_times.txt", required: true) { header in
            let trip = try column(header, "trip_id", in: "stop_times.txt")
            let stop = try column(header, "stop_id", in: "stop_times.txt")
            let sequence = try column(header, "stop_sequence", in: "stop_times.txt")
            let (arrival, departure) = (header["arrival_time"], header["departure_time"])
            let (pickup, dropOff) = (header["pickup_type"], header["drop_off_type"])
            var lastTripBytes: [UInt8] = []
            var lastTripIndex: Int?
            return { row in
                let tripBytes = row.field(trip)
                if !tripBytes.elementsEqual(lastTripBytes) {
                    lastTripBytes = Array(tripBytes)
                    lastTripIndex = tripIndexes[row.string(trip)]
                }
                guard let tripIndex = lastTripIndex, let stopIndex = stopIndexes[row.string(stop)], let seq = row.int(sequence) else { return }
                let arrivalTime = row.gtfsTime(arrival)
                let departureTime = row.gtfsTime(departure)
                insertStopTime.bind(tripIndex, at: 1)
                insertStopTime.bind(seq, at: 2)
                insertStopTime.bind(stopIndex, at: 3)
                insertStopTime.bind(arrivalTime ?? departureTime, at: 4)
                insertStopTime.bind(departureTime ?? arrivalTime, at: 5)
                insertStopTime.bind(row.int(pickup) ?? 0, at: 6)
                insertStopTime.bind(row.int(dropOff) ?? 0, at: 7)
                try insertStopTime.run()
            }
        }

        // transfers.txt
        let insertTransfer = try database.prepare("INSERT INTO transfers VALUES (?, ?, ?, ?)")
        try load("transfers.txt") { header in
            let from = try column(header, "from_stop_id", in: "transfers.txt")
            let to = try column(header, "to_stop_id", in: "transfers.txt")
            let (type, minTime) = (header["transfer_type"], header["min_transfer_time"])
            return { row in
                guard let fromIndex = stopIndexes[row.string(from)], let toIndex = stopIndexes[row.string(to)] else { return }
                insertTransfer.bind(fromIndex, at: 1)
                insertTransfer.bind(toIndex, at: 2)
                insertTransfer.bind(row.int(type) ?? 0, at: 3)
                insertTransfer.bind(row.int(minTime), at: 4)
                try insertTransfer.run()
            }
        }

        var feedVersion: String?
        try load("feed_info.txt") { header in
            let version = header["feed_version"]
            return { row in feedVersion = feedVersion ?? row.nonEmptyString(version) }
        }

        progress(ImportProgress(file: nil, fraction: 0.9))
        try Task.checkCancellation()
        // Which routes serve each station (platforms roll up to their parent), and which stops a rider
        // would search for: stations, plus standalone stops, that actually have service.
        try database.execute("""
            INSERT OR IGNORE INTO stop_routes
                SELECT DISTINCT COALESCE(s.parent_idx, s.stop_idx), t.route_idx
                FROM stop_times st JOIN trips t ON t.trip_idx = st.trip_idx JOIN stops s ON s.stop_idx = st.stop_idx;
            UPDATE stops SET searchable = 1
                WHERE parent_idx IS NULL AND EXISTS (SELECT 1 FROM stop_routes r WHERE r.stop_idx = stops.stop_idx);
            CREATE INDEX stops_by_lat ON stops (lat) WHERE searchable = 1;
            CREATE INDEX calendar_dates_by_date ON calendar_dates (date);
            """)

        let insertMeta = try database.prepare("INSERT INTO meta VALUES (?, ?)")
        let meta: [String: String?] = [
            "schema_version": String(schemaVersion),
            "feed_id": feedID,
            "feed_version": feedVersion,
            "imported_at": String(Int(Date.now.timeIntervalSince1970)),
        ]
        for (key, value) in meta {
            insertMeta.bind(key, at: 1)
            insertMeta.bind(value, at: 2)
            try insertMeta.run()
        }

        try database.execute("COMMIT")
        progress(ImportProgress(file: nil, fraction: 1))
    }
}
