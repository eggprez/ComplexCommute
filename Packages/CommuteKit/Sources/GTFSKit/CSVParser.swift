import Foundation

/// One parsed CSV record. Only valid inside the row callback; fields are views into a reused buffer.
public struct CSVRow {
    let bytes: UnsafeBufferPointer<UInt8>
    let ends: [Int]

    public var count: Int { ends.count }

    public func field(_ index: Int) -> UnsafeBufferPointer<UInt8> {
        guard index >= 0, index < ends.count else { return UnsafeBufferPointer(start: nil, count: 0) }
        let start = index == 0 ? 0 : ends[index - 1]
        return UnsafeBufferPointer(rebasing: bytes[start..<ends[index]])
    }

    public func string(_ index: Int) -> String {
        String(decoding: field(index), as: UTF8.self)
    }

    /// Nil when the field is missing or empty.
    public func nonEmptyString(_ index: Int) -> String? {
        let bytes = field(index)
        return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
    }

    public func int(_ index: Int) -> Int? {
        let bytes = field(index)
        guard !bytes.isEmpty else { return nil }
        var value = 0
        var negative = false
        for (position, byte) in bytes.enumerated() {
            if position == 0, byte == UInt8(ascii: "-") {
                negative = true
            } else if byte >= 48, byte <= 57 {
                value = value * 10 + Int(byte - 48)
            } else if byte != UInt8(ascii: " ") {
                return nil
            }
        }
        return negative ? -value : value
    }

    public func double(_ index: Int) -> Double? {
        Double(string(index).trimmingCharacters(in: .whitespaces))
    }

    /// GTFS "H:MM:SS" / "HH:MM:SS" (hours may exceed 24) as seconds after midnight of the service day.
    public func gtfsTime(_ index: Int) -> Int? {
        var parts = [0, 0, 0]
        var part = 0
        var sawDigit = false
        for byte in field(index) {
            if byte == UInt8(ascii: ":") {
                part += 1
                guard part < 3 else { return nil }
            } else if byte >= 48, byte <= 57 {
                parts[part] = parts[part] * 10 + Int(byte - 48)
                sawDigit = true
            } else if byte != UInt8(ascii: " ") {
                return nil
            }
        }
        guard sawDigit, part == 2 else { return nil }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }
}

/// Push-style RFC 4180 parser working on raw bytes, so multi-hundred-MB files stream through
/// without ever becoming Strings. Handles quoted fields, escaped quotes, CRLF and a UTF-8 BOM.
public struct CSVParser {
    private enum State {
        case fieldStart, unquoted, quoted, quoteInQuoted
    }

    private var state = State.fieldStart
    private var row: [UInt8] = []
    private var ends: [Int] = []
    private var bomBytesToCheck = 3
    private var isAtRecordStart = true

    public init() {
        row.reserveCapacity(512)
    }

    public mutating func parse(_ chunk: UnsafeBufferPointer<UInt8>, onRow: (CSVRow) throws -> Void) throws {
        for byte in chunk {
            if bomBytesToCheck > 0 {
                let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
                if byte == bom[3 - bomBytesToCheck] {
                    bomBytesToCheck -= 1
                    continue
                }
                bomBytesToCheck = 0
            }

            switch state {
            case .fieldStart, .unquoted:
                switch byte {
                case UInt8(ascii: "\""):
                    if state == .fieldStart {
                        state = .quoted
                        isAtRecordStart = false
                    } else {
                        row.append(byte)
                    }
                case UInt8(ascii: ","):
                    ends.append(row.count)
                    state = .fieldStart
                    isAtRecordStart = false
                case UInt8(ascii: "\n"):
                    try endRecord(onRow)
                case UInt8(ascii: "\r"):
                    break
                default:
                    row.append(byte)
                    state = .unquoted
                    isAtRecordStart = false
                }
            case .quoted:
                if byte == UInt8(ascii: "\"") {
                    state = .quoteInQuoted
                } else {
                    row.append(byte)
                }
            case .quoteInQuoted:
                switch byte {
                case UInt8(ascii: "\""):
                    row.append(byte)
                    state = .quoted
                case UInt8(ascii: ","):
                    ends.append(row.count)
                    state = .fieldStart
                case UInt8(ascii: "\n"):
                    try endRecord(onRow)
                default:
                    state = .unquoted
                }
            }
        }
    }

    /// Flushes a final record that has no trailing newline.
    public mutating func finish(onRow: (CSVRow) throws -> Void) throws {
        try endRecord(onRow)
    }

    private mutating func endRecord(_ onRow: (CSVRow) throws -> Void) throws {
        defer {
            row.removeAll(keepingCapacity: true)
            ends.removeAll(keepingCapacity: true)
            state = .fieldStart
            isAtRecordStart = true
        }
        // Blank lines are not records.
        guard !isAtRecordStart else { return }
        ends.append(row.count)
        try row.withUnsafeBufferPointer { try onRow(CSVRow(bytes: $0, ends: ends)) }
    }
}

/// Maps GTFS column names to positions; optional columns resolve to -1, which rows treat as empty.
public struct CSVHeader {
    private let columns: [String: Int]

    init(_ row: CSVRow) {
        var columns: [String: Int] = [:]
        for index in 0..<row.count {
            columns[row.string(index).trimmingCharacters(in: .whitespaces).lowercased()] = index
        }
        self.columns = columns
    }

    public subscript(_ name: String) -> Int {
        columns[name] ?? -1
    }

    public func has(_ name: String) -> Bool {
        columns[name] != nil
    }
}
