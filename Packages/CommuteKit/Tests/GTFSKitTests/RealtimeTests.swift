import Foundation
import Testing
@testable import GTFSKit

/// Minimal protobuf writer, so fixtures are built from the GTFS-realtime field numbers rather than opaque bytes.
struct ProtobufWriter {
    private(set) var data = Data()

    init(_ build: (inout ProtobufWriter) -> Void = { _ in }) {
        build(&self)
    }

    private mutating func varint(_ value: UInt64) {
        var value = value
        while value >= 0x80 {
            data.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        data.append(UInt8(value))
    }

    mutating func int(_ field: Int, _ value: Int) {
        varint(UInt64(field << 3))
        varint(UInt64(bitPattern: Int64(value)))
    }

    mutating func string(_ field: Int, _ value: String) {
        bytes(field, Data(value.utf8))
    }

    mutating func message(_ field: Int, _ build: (inout ProtobufWriter) -> Void) {
        bytes(field, ProtobufWriter(build).data)
    }

    private mutating func bytes(_ field: Int, _ value: Data) {
        varint(UInt64(field << 3 | 2))
        varint(UInt64(value.count))
        data.append(value)
    }
}

@Suite struct RealtimeFeedTests {
    @Test func decodesTripUpdates() throws {
        let data = ProtobufWriter { feed in
            feed.message(1) { $0.string(1, "2.0"); $0.int(3, 1_800_000_000) }
            feed.message(2) { entity in
                entity.string(1, "e1")
                entity.message(3) { update in
                    update.message(1) { $0.string(1, "044950_N..N"); $0.string(3, "20260920"); $0.string(5, "N") }
                    update.message(2) { stop in
                        stop.message(2) { $0.int(2, 1_800_000_100) }
                        stop.message(3) { $0.int(1, -45); $0.int(2, 1_800_000_130) }
                        stop.string(4, "R03N")
                    }
                    update.message(2) { $0.int(1, 7); $0.int(5, 1) }
                    update.message(1001) { $0.string(1, "an agency extension we don't understand") }
                }
            }
            feed.message(2) { entity in
                entity.string(1, "e2")
                entity.message(3) { $0.message(1) { $0.string(1, "gone"); $0.int(4, 3) } }
            }
        }.data

        let feed = try RealtimeFeed(data: data)
        #expect(feed.timestamp == 1_800_000_000)
        #expect(feed.tripUpdates.map(\.tripID) == ["044950_N..N", "gone"])
        let update = feed.tripUpdates[0]
        #expect(update.startDate == 20260920)
        #expect(update.routeID == "N")
        #expect(!update.isCanceled)
        #expect(update.stopTimes[0].stopID == "R03N")
        #expect(update.stopTimes[0].arrival == 1_800_000_100)
        #expect(update.stopTimes[0].departure == 1_800_000_130)
        #expect(update.stopTimes[0].departureDelay == -45)
        #expect(update.stopTimes[1].stopSequence == 7)
        #expect(update.stopTimes[1].isSkipped)
        #expect(feed.tripUpdates[1].isCanceled)
    }

    @Test func decodesAlertsPreferringPlainEnglish() throws {
        let data = ProtobufWriter { feed in
            feed.message(2) { entity in
                entity.string(1, "lmm:alert:1")
                entity.message(5) { alert in
                    alert.message(1) { $0.int(1, 100); $0.int(2, 200) }
                    alert.message(1) { $0.int(1, 500) }
                    alert.message(5) { $0.string(1, "MTASBWY"); $0.string(2, "F") }
                    alert.message(5) { $0.string(5, "D17") }
                    alert.message(5) { $0.message(4) { $0.string(5, "M") } }
                    alert.message(10) { text in
                        text.message(1) { $0.string(1, "<p>Delays</p>"); $0.string(2, "en-html") }
                        text.message(1) { $0.string(1, " [F] trains are delayed "); $0.string(2, "en") }
                    }
                }
            }
        }.data

        let alert = try #require(try RealtimeFeed(data: data).alerts.first)
        #expect(alert.id == "lmm:alert:1")
        #expect(alert.header == "[F] trains are delayed")
        #expect(alert.routeIDs == ["F", "M"])
        #expect(alert.stopIDs == ["D17"])
        #expect(alert.isActive(at: 150))
        #expect(!alert.isActive(at: 300))
        #expect(alert.isActive(at: 10_000))
    }

    @Test func rejectsTruncatedData() {
        let data = ProtobufWriter { $0.message(2) { $0.string(1, "entity") } }.data
        #expect(throws: ProtobufError.self) { try RealtimeFeed(data: data.dropLast(3)) }
    }

    @Test func matchesSubwayTripsByOriginRouteAndDirection() throws {
        let subway = try #require(FeedCatalog.feed(id: "mta-subway")?.realtime)
        #expect(subway.matchKey(forTripID: "BSP26GEN-N061-Sunday-00_044950_N..N34R") == "044950_N..N")
        #expect(subway.matchKey(forTripID: "044950_N..N") == "044950_N..N")
        #expect(subway.matchKey(forTripID: "045700_N..S23R") == "045700_N..S")
        #expect(subway.matchKey(forTripID: "SIR-FA2017-SI017-Weekday-08_054000_GS.N01R") == "054000_GS.N")
        #expect(subway.matchKey(forTripID: "051100_6..S04X001") == "051100_6..S")
        #expect(subway.matchKey(forTripID: "unusual") == "unusual")

        let lirr = try #require(FeedCatalog.feed(id: "mta-lirr")?.realtime)
        #expect(lirr.matchKey(forTripID: "GO202_26_8712") == "GO202_26_8712")
    }
}
