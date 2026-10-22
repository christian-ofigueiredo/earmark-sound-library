import Foundation

/// Builds small WAV/AIFF files with metadata chunks for tests.
enum TestFiles {
    static func chunk(_ id: String, _ body: Data) -> Data {
        var d = Data(id.utf8)
        d.append(le32(UInt32(body.count)))
        d.append(body)
        if body.count % 2 == 1 { d.append(0) }
        return d
    }

    static func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    static func be16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
    static func be32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }

    static func fixed(_ s: String, _ n: Int) -> Data {
        var d = Data(s.utf8.prefix(n))
        d.append(Data(count: n - d.count))
        return d
    }

    static func bext(description: String, originator: String) -> Data {
        var b = Data()
        b.append(fixed(description, 256)); b.append(fixed(originator, 32)); b.append(fixed("REF", 32))
        b.append(fixed("2026-01-01", 10)); b.append(fixed("12:00:00", 8))
        b.append(Data(count: 602 - b.count))
        return b
    }

    static func ixml(_ user: [(String, String)]) -> Data {
        let inner = user.map { "<\($0.0)>\($0.1)</\($0.0)>" }.joined()
        return Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><BWFXML><IXML_VERSION>2.1</IXML_VERSION><USER>\(inner)</USER></BWFXML>".utf8)
    }

    static func info(_ items: [(String, String)]) -> Data {
        var b = Data("INFO".utf8)
        for (id, v) in items { b.append(chunk(id, Data(v.utf8) + Data([0]))) }
        return b
    }

    /// 16-bit mono WAV with `seconds` of silence plus the given extra chunks.
    static func wav(seconds: Double = 0.5, sampleRate: UInt32 = 48000, extra: [Data] = []) -> Data {
        var fmt = Data()
        fmt.append(le16(1)); fmt.append(le16(1)); fmt.append(le32(sampleRate)); fmt.append(le32(sampleRate * 2))
        fmt.append(le16(2)); fmt.append(le16(16))
        var body = Data("WAVE".utf8)
        body.append(chunk("fmt ", fmt))
        for e in extra { body.append(e) }
        body.append(chunk("data", Data(count: Int(Double(sampleRate) * seconds) * 2)))
        var file = Data("RIFF".utf8)
        file.append(le32(UInt32(body.count)))
        file.append(body)
        return file
    }

    static func aiff(seconds: Double, sampleRate: Double = 44100, name: String) -> Data {
        var comm = Data()
        comm.append(be16(2))
        let frames = UInt32(sampleRate * seconds)
        comm.append(be32(frames)); comm.append(be16(16))
        // 80-bit extended for the sample rate
        var exponent = 16383 + 63
        var mantissa = UInt64(sampleRate)
        while mantissa & (1 << 63) == 0 { mantissa <<= 1; exponent -= 1 }
        comm.append(be16(UInt16(exponent))); comm.append(be32(UInt32(mantissa >> 32))); comm.append(be32(UInt32(mantissa & 0xFFFF_FFFF)))
        func ch(_ id: String, _ b: Data) -> Data {
            var d = Data(id.utf8); d.append(be32(UInt32(b.count))); d.append(b); if b.count % 2 == 1 { d.append(0) }; return d
        }
        var body = Data("AIFF".utf8)
        body.append(ch("COMM", comm))
        body.append(ch("NAME", Data(name.utf8)))
        body.append(ch("SSND", Data(count: 8 + Int(frames) * 4)))
        var file = Data("FORM".utf8)
        file.append(be32(UInt32(body.count)))
        file.append(body)
        return file
    }

    static func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("earmark-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func write(_ data: Data, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
    }
}
