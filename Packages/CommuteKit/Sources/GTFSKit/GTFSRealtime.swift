import Foundation

/// The parts of a GTFS-realtime feed the app uses, decoded straight from protobuf wire format.
/// Unknown fields (including agency extensions like NYCT's) are skipped, so no generated code is needed.
public struct RealtimeFeed: Sendable {
    public struct TripUpdate: Sendable {
        public var tripID: String
        public var routeID: String?
        /// yyyymmdd of the trip's service day, when the agency sends it.
        public var startDate: Int?
        public var isCanceled = false
        public var stopTimes: [StopTimeUpdate] = []

        public init(tripID: String) {
            self.tripID = tripID
        }
    }

    public struct StopTimeUpdate: Sendable {
        public var stopID: String?
        public var stopSequence: Int?
        /// POSIX times.
        public var arrival: Int?
        public var departure: Int?
        public var arrivalDelay: Int?
        public var departureDelay: Int?
        public var isSkipped = false

        public init() {}
    }

    public struct Alert: Sendable {
        public var id: String
        public var activePeriods: [ClosedRange<Int>] = []
        public var routeIDs: Set<String> = []
        public var stopIDs: Set<String> = []
        public var header: String = ""
        public var details: String = ""
        public var url: String?

        public func isActive(at time: Int) -> Bool {
            activePeriods.isEmpty || activePeriods.contains { $0.contains(time) }
        }
    }

    public var timestamp: Int?
    public var tripUpdates: [TripUpdate] = []
    public var alerts: [Alert] = []

    public init(data: Data) throws {
        var message = ProtobufReader(data)
        while let field = try message.nextField() {
            switch field.number {
            case 1:
                var header = try field.message()
                while let field = try header.nextField() {
                    if field.number == 3 { timestamp = field.int }
                }
            case 2:
                try decodeEntity(field.message())
            default:
                break
            }
        }
    }

    private mutating func decodeEntity(_ reader: ProtobufReader) throws {
        var reader = reader
        var id = ""
        while let field = try reader.nextField() {
            switch field.number {
            case 1: id = field.string
            case 3: tripUpdates.append(try Self.tripUpdate(field.message()))
            case 5: alerts.append(try Self.alert(field.message(), id: id))
            default: break
            }
        }
    }

    private static func tripUpdate(_ reader: ProtobufReader) throws -> TripUpdate {
        var reader = reader
        var update = TripUpdate(tripID: "")
        while let field = try reader.nextField() {
            switch field.number {
            case 1:
                var trip = try field.message()
                while let field = try trip.nextField() {
                    switch field.number {
                    case 1: update.tripID = field.string
                    case 3: update.startDate = Int(field.string)
                    case 4: update.isCanceled = field.int == 3
                    case 5: update.routeID = field.string
                    default: break
                    }
                }
            case 2:
                update.stopTimes.append(try stopTimeUpdate(field.message()))
            default:
                break
            }
        }
        return update
    }

    private static func stopTimeUpdate(_ reader: ProtobufReader) throws -> StopTimeUpdate {
        var reader = reader
        var update = StopTimeUpdate()

        func event(_ reader: ProtobufReader) throws -> (delay: Int?, time: Int?) {
            var reader = reader
            var result: (delay: Int?, time: Int?) = (nil, nil)
            while let field = try reader.nextField() {
                switch field.number {
                case 1: result.delay = field.signedInt32
                case 2: result.time = field.int
                default: break
                }
            }
            return result
        }

        while let field = try reader.nextField() {
            switch field.number {
            case 1: update.stopSequence = field.int
            case 2: (update.arrivalDelay, update.arrival) = try event(field.message())
            case 3: (update.departureDelay, update.departure) = try event(field.message())
            case 4: update.stopID = field.string
            case 5: update.isSkipped = field.int == 1
            default: break
            }
        }
        return update
    }

    private static func alert(_ reader: ProtobufReader, id: String) throws -> Alert {
        var reader = reader
        var alert = Alert(id: id)

        /// Prefers English plain text; MTA also sends an "en-html" variant of every string.
        func text(_ reader: ProtobufReader) throws -> String {
            var reader = reader
            var best: (text: String, rank: Int)?
            while let field = try reader.nextField() {
                guard field.number == 1 else { continue }
                var translation = try field.message()
                var (value, language) = ("", "")
                while let field = try translation.nextField() {
                    if field.number == 1 { value = field.string }
                    if field.number == 2 { language = field.string.lowercased() }
                }
                let rank = language == "en" ? 0 : language.isEmpty ? 1 : language.contains("html") ? 3 : 2
                if best.map({ rank < $0.rank }) ?? true {
                    best = (value, rank)
                }
            }
            return best?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        while let field = try reader.nextField() {
            switch field.number {
            case 1:
                var period = try field.message()
                var (start, end) = (0, Int.max)
                while let field = try period.nextField() {
                    if field.number == 1 { start = field.int }
                    if field.number == 2 { end = field.int }
                }
                if start <= end { alert.activePeriods.append(start...end) }
            case 5:
                var entity = try field.message()
                while let field = try entity.nextField() {
                    switch field.number {
                    case 2: alert.routeIDs.insert(field.string)
                    case 5: alert.stopIDs.insert(field.string)
                    case 4:
                        // A trip selector can carry the route too.
                        var trip = try field.message()
                        while let field = try trip.nextField() {
                            if field.number == 5 { alert.routeIDs.insert(field.string) }
                        }
                    default: break
                    }
                }
            case 8: alert.url = try text(field.message())
            case 10: alert.header = try text(field.message())
            case 11: alert.details = try text(field.message())
            default: break
            }
        }
        return alert
    }
}

public enum ProtobufError: Error {
    case truncated
    case malformed
}

/// Just enough of the protobuf wire format to walk a message: varints, fixed-width and length-delimited fields.
struct ProtobufReader {
    struct Field {
        let number: Int
        fileprivate let varint: UInt64
        fileprivate let bytes: Data

        var int: Int { Int(truncatingIfNeeded: varint) }
        /// int32 fields are sign-extended to 64 bits on the wire.
        var signedInt32: Int { Int(Int32(truncatingIfNeeded: varint)) }
        var string: String { String(decoding: bytes, as: UTF8.self) }

        func message() throws -> ProtobufReader { ProtobufReader(bytes) }
    }

    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    mutating func nextField() throws -> Field? {
        guard offset < data.endIndex else { return nil }
        let key = try readVarint()
        let number = Int(key >> 3)
        switch key & 7 {
        case 0:
            return Field(number: number, varint: try readVarint(), bytes: Data())
        case 1:
            return Field(number: number, varint: 0, bytes: try read(8))
        case 2:
            let length = Int(try readVarint())
            return Field(number: number, varint: 0, bytes: try read(length))
        case 5:
            return Field(number: number, varint: 0, bytes: try read(4))
        default:
            throw ProtobufError.malformed
        }
    }

    private mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < data.endIndex {
            let byte = data[offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            guard shift < 64 else { throw ProtobufError.malformed }
        }
        throw ProtobufError.truncated
    }

    private mutating func read(_ count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.endIndex else { throw ProtobufError.truncated }
        defer { offset += count }
        return data[offset..<(offset + count)]
    }
}
