import Foundation

/// CRC-32 (IEEE 802.3), as required by the ZIP format.
enum CRC32 {
    private static let table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    static func checksum(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data {
            c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
        }
        return c ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendLE16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendLE32(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}

/// Minimal ZIP archive writer. Every entry is written with the "stored"
/// (uncompressed) method, which keeps the implementation dependency-free and
/// satisfies the EPUB requirement that the `mimetype` entry be uncompressed.
/// Articles are small enough that skipping deflate costs little.
public struct ZipWriter {
    private struct Entry {
        let name: String
        let crc: UInt32
        let size: UInt32
        let offset: UInt32
    }

    private var payload = Data()
    private var entries: [Entry] = []

    public init() {}

    public mutating func addFile(name: String, contents: Data) {
        let offset = UInt32(payload.count)
        let crc = CRC32.checksum(contents)
        let nameBytes = Data(name.utf8)
        let size = UInt32(contents.count)

        var header = Data()
        header.appendLE32(0x0403_4B50)          // local file header signature
        header.appendLE16(10)                    // version needed (1.0 = stored)
        header.appendLE16(0)                     // general purpose flags
        header.appendLE16(0)                     // compression method: stored
        header.appendLE16(0)                     // last mod time
        header.appendLE16(0x21)                  // last mod date: 1980-01-01
        header.appendLE32(crc)
        header.appendLE32(size)                  // compressed size
        header.appendLE32(size)                  // uncompressed size
        header.appendLE16(UInt16(nameBytes.count))
        header.appendLE16(0)                     // extra field length

        payload.append(header)
        payload.append(nameBytes)
        payload.append(contents)

        entries.append(Entry(name: name, crc: crc, size: size, offset: offset))
    }

    public mutating func addFile(name: String, string: String) {
        addFile(name: name, contents: Data(string.utf8))
    }

    public func finalized() -> Data {
        var archive = payload
        let centralDirectoryOffset = UInt32(archive.count)

        for entry in entries {
            let nameBytes = Data(entry.name.utf8)
            var header = Data()
            header.appendLE32(0x0201_4B50)      // central directory signature
            header.appendLE16(20)                // version made by
            header.appendLE16(10)                // version needed
            header.appendLE16(0)                 // flags
            header.appendLE16(0)                 // stored
            header.appendLE16(0)                 // time
            header.appendLE16(0x21)              // date
            header.appendLE32(entry.crc)
            header.appendLE32(entry.size)
            header.appendLE32(entry.size)
            header.appendLE16(UInt16(nameBytes.count))
            header.appendLE16(0)                 // extra length
            header.appendLE16(0)                 // comment length
            header.appendLE16(0)                 // disk number start
            header.appendLE16(0)                 // internal attributes
            header.appendLE32(0)                 // external attributes
            header.appendLE32(entry.offset)
            archive.append(header)
            archive.append(nameBytes)
        }

        let centralDirectorySize = UInt32(archive.count) - centralDirectoryOffset

        var end = Data()
        end.appendLE32(0x0605_4B50)              // end of central directory
        end.appendLE16(0)                        // this disk
        end.appendLE16(0)                        // disk with central directory
        end.appendLE16(UInt16(entries.count))
        end.appendLE16(UInt16(entries.count))
        end.appendLE32(centralDirectorySize)
        end.appendLE32(centralDirectoryOffset)
        end.appendLE16(0)                        // comment length
        archive.append(end)

        return archive
    }
}
