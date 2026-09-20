import CommuteCore
import Foundation
import Testing
@testable import GTFSKit

/// Writes a tiny two-line GTFS feed and zips it with the system `zip` tool.
private struct Fixture {
    let directory: URL
    let zipURL: URL

    static let files: [String: String] = [
        "routes.txt": """
            route_id,route_short_name,route_long_name,route_type,route_color,route_text_color
            R1,1,Broadway Local,1,EE352E,FFFFFF
            RX,1,Broadway Express,1,EE352E,FFFFFF
            R1X,1X,Broadway Super Express,1,EE352E,FFFFFF
            B9,M9,"Avenue C, Crosstown",3,,
            """,
        // BOM + CRLF + quoted commas and quotes, like real agency exports.
        "stops.txt": "\u{FEFF}stop_id,stop_name,stop_lat,stop_lon,location_type,parent_station\r\n"
            + "S1,\"Times Sq-42 St\",40.7553,-73.9869,1,\r\n"
            + "S1N,Times Sq-42 St,40.7553,-73.9869,0,S1\r\n"
            + "S1S,Times Sq-42 St,40.7553,-73.9869,0,S1\r\n"
            + "S2,\"34 St-Penn \"\"Station\"\"\",40.7506,-73.9911,1,\r\n"
            + "S2N,34 St-Penn Station,40.7506,-73.9911,0,S2\r\n"
            + "E1,Entrance,40.7553,-73.9869,2,S1\r\n"
            + "B1,\"Avenue C, E 14 St\",40.7290,-73.9780,,\r\n"
            + "GHOST,Unserved Stop,40.7,-73.9,0,\r\n",
        "calendar.txt": """
            service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
            WKD,1,1,1,1,1,0,0,20260101,20261231
            """,
        "calendar_dates.txt": """
            service_id,date,exception_type
            WKD,20261126,2
            HOLIDAY,20261126,1
            """,
        "trips.txt": """
            route_id,service_id,trip_id,trip_headsign,direction_id
            R1,WKD,T1,Uptown,0
            RX,WKD,T2,Uptown,0
            B9,HOLIDAY,T3,Crosstown,1
            R1X,WKD,T4,Uptown,0
            R1,WKD,ORPHAN,Nowhere,0
            """,
        "stop_times.txt": """
            trip_id,arrival_time,departure_time,stop_id,stop_sequence
            T1,08:00:00,08:00:30,S2N,1
            T1,8:03:00,8:03:30,S1N,2
            T2,25:10:00,25:10:00,S2N,1
            T2,,,S1N,2
            T3,09:00:00,09:00:00,B1,1
            T4,10:00:00,10:00:00,S2N,1
            T4,10:02:00,10:02:00,S1N,2
            T3,09:05:00,09:05:00,NOPE,2
            """,
        "transfers.txt": """
            from_stop_id,to_stop_id,transfer_type,min_transfer_time
            S1N,S1S,2,180
            """,
        "feed_info.txt": """
            feed_publisher_name,feed_version
            Test,v42
            """,
    ]

    init(compressed: Bool = true) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("gtfs-\(UUID().uuidString)")
        let source = directory.appendingPathComponent("feed")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for (name, contents) in Self.files {
            try contents.write(to: source.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        zipURL = directory.appendingPathComponent("feed.zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = source
        zip.arguments = ["-q", compressed ? "-9" : "-0", zipURL.path] + Self.files.keys.sorted()
        try zip.run()
        zip.waitUntilExit()
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}

@Suite struct CSVParserTests {
    private func rows(_ text: String, chunkSize: Int) throws -> [[String]] {
        var parser = CSVParser()
        var rows: [[String]] = []
        let collect: (CSVRow) -> Void = { row in rows.append((0..<row.count).map(row.string)) }
        let bytes = Array(text.utf8)
        for start in stride(from: 0, to: bytes.count, by: chunkSize) {
            try bytes[start..<min(start + chunkSize, bytes.count)].withUnsafeBufferPointer { try parser.parse($0, onRow: collect) }
        }
        try parser.finish(onRow: collect)
        return rows
    }

    @Test(arguments: [1, 3, 1024])
    func handlesQuotingLineEndingsAndChunkBoundaries(chunkSize: Int) throws {
        let text = "\u{FEFF}a,b,c\r\n1,\"x, \"\"y\"\"\",\n\n\"multi\nline\",,z"
        #expect(try rows(text, chunkSize: chunkSize) == [["a", "b", "c"], ["1", "x, \"y\"", ""], ["multi\nline", "", "z"]])
    }

    @Test func parsesTypedFields() throws {
        var parser = CSVParser()
        var checked = false
        try Array("25:10:05,7:01:00,-12, 40.5 ,abc,".utf8).withUnsafeBufferPointer { try parser.parse($0) { _ in } }
        try parser.finish { row in
            #expect(row.gtfsTime(0) == 25 * 3600 + 10 * 60 + 5)
            #expect(row.gtfsTime(1) == 7 * 3600 + 60)
            #expect(row.int(2) == -12)
            #expect(row.double(3) == 40.5)
            #expect(row.int(4) == nil)
            #expect(row.gtfsTime(5) == nil)
            #expect(row.int(99) == nil)
            checked = true
        }
        #expect(checked)
    }
}

@Suite struct ZipArchiveTests {
    @Test(arguments: [true, false])
    func streamsEntries(compressed: Bool) throws {
        let fixture = try Fixture(compressed: compressed)
        defer { fixture.cleanUp() }
        let archive = try ZipArchive(url: fixture.zipURL)
        #expect(archive.entries.count == Fixture.files.count)

        var bytes: [UInt8] = []
        // A tiny chunk size forces many inflate iterations.
        let found = try archive.read("stop_times.txt", chunkSize: 16) { bytes.append(contentsOf: $0) }
        #expect(found)
        #expect(String(decoding: bytes, as: UTF8.self) == Fixture.files["stop_times.txt"])
        #expect(try archive.read("shapes.txt") { _ in } == false)
    }

    @Test func rejectsNonZipFiles() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).zip")
        try Data("<html>401 Unauthorized</html>".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: ZipError.notAZipFile) { try ZipArchive(url: url) }
    }
}

@Suite struct ExpiredCalendarTests {
    @Test func fallsBackToTheSameWeekdayInTheLastPublishedWeek() {
        // Within the calendar: unchanged.
        #expect(FeedDatabase.fallbackDate(for: 20260601, lastServiceDate: 20260601) == 20260601)
        // 2026-06-01 is a Monday. Monday 2026-09-21 maps back onto it; Sunday 2026-09-20 onto Sunday 2026-05-31.
        #expect(FeedDatabase.fallbackDate(for: 20260921, lastServiceDate: 20260601) == 20260601)
        #expect(FeedDatabase.fallbackDate(for: 20260920, lastServiceDate: 20260601) == 20260531)
        #expect(FeedDatabase.fallbackDate(for: 20260602, lastServiceDate: 20260601) == 20260526)
    }
}

@Suite struct FeedLibraryTests {
    @Test func importsAndSearches() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let library = FeedLibrary(directory: fixture.directory.appendingPathComponent("feeds"))

        let info = try await library.install(feedID: "test", zip: fixture.zipURL)
        #expect(info.feedID == "test")
        #expect(info.version == "v42")
        #expect(info.lastServiceDate == 20261231)
        #expect(info.routeCount == 4)
        // Two stations + one standalone bus stop; platforms, entrances and unserved stops aren't searchable.
        #expect(info.stopCount == 3)

        let timesSquare = await library.searchStops(matching: "times sq")
        #expect(timesSquare.map(\.stopID) == ["S1"])
        // Platform service rolls up to the station; the duplicate "1" and the "1X" express fold into one badge.
        #expect(timesSquare.first?.routes.map(\.name) == ["1"])
        #expect(timesSquare.first?.routes.first?.colorHex == "EE352E")

        #expect(await library.searchStops(matching: "penn \"station\"").map(\.stopID) == ["S2"])
        #expect(await library.searchStops(matching: "avenue c").first?.routes.map(\.name) == ["M9"])
        #expect(await library.searchStops(matching: "unserved").isEmpty)
        #expect(await library.searchStops(matching: "100%_").isEmpty)

        let nearby = await library.stops(near: Coordinate(latitude: 40.7550, longitude: -73.9870), radiusMeters: 700)
        #expect(nearby.map(\.stopID) == ["S1", "S2"])
    }

    @Test func survivesRelaunchReinstallAndRemoval() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let directory = fixture.directory.appendingPathComponent("feeds")
        _ = try await FeedLibrary(directory: directory).install(feedID: "test", zip: fixture.zipURL)

        let relaunched = FeedLibrary(directory: directory)
        #expect(await relaunched.installedFeeds().map(\.feedID) == ["test"])
        _ = try await relaunched.install(feedID: "test", zip: fixture.zipURL)
        #expect(await relaunched.searchStops(matching: "times").count == 1)

        try await relaunched.remove(feedID: "test")
        #expect(await relaunched.installedFeeds().isEmpty)
        #expect(await relaunched.searchStops(matching: "times").isEmpty)
    }

    @Test func failedImportLeavesInstalledFeedIntact() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let library = FeedLibrary(directory: fixture.directory.appendingPathComponent("feeds"))
        _ = try await library.install(feedID: "test", zip: fixture.zipURL)

        let bogus = fixture.directory.appendingPathComponent("bogus.zip")
        try Data("not a zip".utf8).write(to: bogus)
        await #expect(throws: ZipError.notAZipFile) {
            _ = try await library.install(feedID: "test", zip: bogus)
        }
        #expect(await library.searchStops(matching: "times").count == 1)
    }
}
