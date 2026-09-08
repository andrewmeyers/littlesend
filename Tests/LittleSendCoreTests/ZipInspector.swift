import Foundation

/// Reads back archives produced by `ZipWriter`, so tests verify the real bytes
/// rather than trusting the writer's own bookkeeping.
enum ZipInspector {
    struct Entry {
        let name: String
        let contents: Data
    }

    enum Failure: Error {
        case endOfCentralDirectoryNotFound
        case malformed(String)
    }

    static func entries(in archive: Data) throws -> [Entry] {
        let bytes = [UInt8](archive)

        guard let eocd = findEndOfCentralDirectory(bytes) else {
            throw Failure.endOfCentralDirectoryNotFound
        }
        let count = Int(readLE16(bytes, eocd + 10))
        var offset = Int(readLE32(bytes, eocd + 16))

        var entries: [Entry] = []
        for _ in 0..<count {
            guard offset + 46 <= bytes.count, readLE32(bytes, offset) == 0x0201_4B50 else {
                throw Failure.malformed("bad central directory header at \(offset)")
            }
            let compression = readLE16(bytes, offset + 10)
            let size = Int(readLE32(bytes, offset + 24))
            let nameLength = Int(readLE16(bytes, offset + 28))
            let extraLength = Int(readLE16(bytes, offset + 30))
            let commentLength = Int(readLE16(bytes, offset + 32))
            let localOffset = Int(readLE32(bytes, offset + 42))

            guard compression == 0 else {
                throw Failure.malformed("unexpected compression method \(compression)")
            }

            let name = String(decoding: bytes[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)

            guard localOffset + 30 <= bytes.count, readLE32(bytes, localOffset) == 0x0403_4B50 else {
                throw Failure.malformed("bad local header for \(name)")
            }
            let localNameLength = Int(readLE16(bytes, localOffset + 26))
            let localExtraLength = Int(readLE16(bytes, localOffset + 28))
            let dataStart = localOffset + 30 + localNameLength + localExtraLength

            guard dataStart + size <= bytes.count else {
                throw Failure.malformed("truncated data for \(name)")
            }
            entries.append(Entry(name: name, contents: Data(bytes[dataStart..<(dataStart + size)])))

            offset += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    private static func findEndOfCentralDirectory(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 22 else { return nil }
        var index = bytes.count - 22
        while index >= 0 {
            if readLE32(bytes, index) == 0x0605_4B50 { return index }
            index -= 1
        }
        return nil
    }

    private static func readLE16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readLE32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}
