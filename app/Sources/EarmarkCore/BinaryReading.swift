import Foundation

extension Data {
    func uint16LE(at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        return withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self)) }
    }

    func uint32LE(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        return withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }

    func uint64LE(at offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= count else { return 0 }
        return withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }
    }

    func int16LE(at offset: Int) -> Int16 { Int16(bitPattern: uint16LE(at: offset)) }

    func uint16BE(at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        return withUnsafeBytes { UInt16(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self)) }
    }

    func uint32BE(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        return withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }

    func float32LE(at offset: Int) -> Float { Float(bitPattern: uint32LE(at: offset)) }

    func fourCC(at offset: Int) -> String {
        guard offset >= 0, offset + 4 <= count else { return "" }
        return String(decoding: self[startIndex + offset ..< startIndex + offset + 4], as: UTF8.self)
    }

    /// Text up to the first NUL, trying UTF-8 then Windows-1252/Latin-1.
    func metadataString(_ range: Range<Int>) -> String {
        let lo = Swift.max(0, range.lowerBound), hi = Swift.min(count, range.upperBound)
        guard lo < hi else { return "" }
        var bytes = self[startIndex + lo ..< startIndex + hi]
        if let nul = bytes.firstIndex(of: 0) { bytes = bytes[..<nul] }
        let d = Data(bytes)
        let s = String(data: d, encoding: .utf8) ?? String(data: d, encoding: .windowsCP1252)
            ?? String(data: d, encoding: .isoLatin1) ?? ""
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func metadataString() -> String { metadataString(0 ..< count) }

    /// 80-bit IEEE extended float (AIFF sample rate).
    func extended80BE(at offset: Int) -> Double {
        guard offset >= 0, offset + 10 <= count else { return 0 }
        let expField = Int(uint16BE(at: offset))
        let hi = UInt64(uint32BE(at: offset + 2)), lo = UInt64(uint32BE(at: offset + 6))
        let mantissa = (hi << 32) | lo
        let sign: Double = expField & 0x8000 != 0 ? -1 : 1
        let exponent = expField & 0x7FFF
        if exponent == 0 && mantissa == 0 { return 0 }
        return sign * Double(mantissa) * pow(2.0, Double(exponent - 16383 - 63))
    }
}

/// Reads a file through a read-only handle without loading it all.
struct ReadOnlyFile {
    let handle: FileHandle
    let size: UInt64

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        size = (try? handle.seekToEnd()) ?? 0
    }

    func read(at offset: UInt64, count: Int) -> Data {
        guard offset < size, count > 0 else { return Data() }
        do {
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: count) ?? Data()
        } catch {
            return Data()
        }
    }

    func close() { try? handle.close() }
}
