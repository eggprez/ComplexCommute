import Compression
import Foundation

public enum ZipError: Error, Equatable {
    case notAZipFile
    case zip64Unsupported
    case unsupportedCompression(UInt16)
    case corrupt
}

/// Minimal streaming ZIP reader: enough for GTFS bundles (stored + deflate, no ZIP64, no encryption).
/// Entries are decompressed in chunks so a 200 MB stop_times.txt never sits in memory.
public struct ZipArchive {
    public struct Entry: Sendable {
        public let path: String
        public let compressedSize: Int
        public let uncompressedSize: Int
        let method: UInt16
        let localHeaderOffset: Int
    }

    /// Keyed by lowercased file name without any directory prefix (some feeds nest files in a folder).
    public let entries: [String: Entry]
    private let url: URL

    public init(url: URL) throws {
        self.url = url
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let fileSize = Int(try handle.seekToEnd())
        let tailSize = min(fileSize, 65_557)
        try handle.seek(toOffset: UInt64(fileSize - tailSize))
        let tail = [UInt8](try handle.read(upToCount: tailSize) ?? Data())

        guard tail.count >= 22,
              let eocd = stride(from: tail.count - 22, through: 0, by: -1).first(where: { tail.u32($0) == 0x0605_4b50 }) else {
            throw ZipError.notAZipFile
        }
        let directorySize = Int(tail.u32(eocd + 12))
        let directoryOffset = Int(tail.u32(eocd + 16))
        guard directoryOffset != 0xFFFF_FFFF else { throw ZipError.zip64Unsupported }

        try handle.seek(toOffset: UInt64(directoryOffset))
        let directory = [UInt8](try handle.read(upToCount: directorySize) ?? Data())

        var entries: [String: Entry] = [:]
        var offset = 0
        while offset + 46 <= directory.count, directory.u32(offset) == 0x0201_4b50 {
            let nameLength = Int(directory.u16(offset + 28))
            let extraLength = Int(directory.u16(offset + 30))
            let commentLength = Int(directory.u16(offset + 32))
            guard offset + 46 + nameLength <= directory.count else { throw ZipError.corrupt }
            let path = String(decoding: directory[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)
            let entry = Entry(
                path: path,
                compressedSize: Int(directory.u32(offset + 20)),
                uncompressedSize: Int(directory.u32(offset + 24)),
                method: directory.u16(offset + 10),
                localHeaderOffset: Int(directory.u32(offset + 42))
            )
            if !path.hasSuffix("/") {
                entries[(path as NSString).lastPathComponent.lowercased()] = entry
            }
            offset += 46 + nameLength + extraLength + commentLength
        }
        self.entries = entries
    }

    /// Streams the decompressed bytes of `name` to `body`. Returns false if the archive has no such file.
    @discardableResult
    public func read(_ name: String, chunkSize: Int = 1 << 18, _ body: (UnsafeBufferPointer<UInt8>) throws -> Void) throws -> Bool {
        guard let entry = entries[name.lowercased()] else { return false }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        try handle.seek(toOffset: UInt64(entry.localHeaderOffset))
        let header = [UInt8](try handle.read(upToCount: 30) ?? Data())
        guard header.count == 30, header.u32(0) == 0x0403_4b50 else { throw ZipError.corrupt }
        let dataOffset = entry.localHeaderOffset + 30 + Int(header.u16(26)) + Int(header.u16(28))
        try handle.seek(toOffset: UInt64(dataOffset))

        var remaining = entry.compressedSize
        func nextInput() throws -> Data {
            let data = try handle.read(upToCount: min(chunkSize, remaining)) ?? Data()
            guard !data.isEmpty || remaining == 0 else { throw ZipError.corrupt }
            remaining -= data.count
            return data
        }

        switch entry.method {
        case 0:
            while remaining > 0 {
                try nextInput().withUnsafeBytes { try body($0.bindMemory(to: UInt8.self)) }
            }
        case 8:
            try inflate(nextInput: nextInput, hasMoreInput: { remaining > 0 }, chunkSize: chunkSize, body)
        default:
            throw ZipError.unsupportedCompression(entry.method)
        }
        return true
    }

    private func inflate(nextInput: () throws -> Data, hasMoreInput: () -> Bool, chunkSize: Int,
                         _ body: (UnsafeBufferPointer<UInt8>) throws -> Void) throws {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        // COMPRESSION_ZLIB is raw deflate, which is exactly what ZIP stores.
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ZipError.corrupt
        }
        defer { compression_stream_destroy(stream) }

        let source = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer {
            source.deallocate()
            destination.deallocate()
        }
        stream.pointee.src_size = 0

        var status = COMPRESSION_STATUS_OK
        while status == COMPRESSION_STATUS_OK {
            if stream.pointee.src_size == 0, hasMoreInput() {
                let input = try nextInput()
                input.copyBytes(to: source, count: input.count)
                stream.pointee.src_ptr = UnsafePointer(source)
                stream.pointee.src_size = input.count
            }
            stream.pointee.dst_ptr = destination
            stream.pointee.dst_size = chunkSize

            let flags = hasMoreInput() ? 0 : Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
            status = compression_stream_process(stream, flags)
            guard status != COMPRESSION_STATUS_ERROR else { throw ZipError.corrupt }

            let produced = chunkSize - stream.pointee.dst_size
            if produced > 0 {
                try body(UnsafeBufferPointer(start: destination, count: produced))
            }
        }
    }
}

private extension Array where Element == UInt8 {
    func u16(_ offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func u32(_ offset: Int) -> UInt32 {
        UInt32(self[offset]) | UInt32(self[offset + 1]) << 8 | UInt32(self[offset + 2]) << 16 | UInt32(self[offset + 3]) << 24
    }
}
