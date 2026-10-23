import Foundation

/// Technical facts from the file header.
public struct AudioTechnical: Sendable, Codable, Equatable {
    public var sampleRate: Double?
    public var channels: Int?
    public var bitsPerSample: Int?
    public var duration: Double?

    public init(sampleRate: Double? = nil, channels: Int? = nil, bitsPerSample: Int? = nil, duration: Double? = nil) {
        self.sampleRate = sampleRate; self.channels = channels
        self.bitsPerSample = bitsPerSample; self.duration = duration
    }
}

public struct AcidInfo: Sendable, Codable, Equatable {
    public var oneShot: Bool
    public var tempo: Double
    public var beats: Int
}

/// Everything read from the file's metadata chunks, before normalisation.
public struct RawMetadata: Sendable, Codable, Equatable {
    public var container: String?
    public var chunkIDs: [String] = []
    public var bext: [String: String] = [:]
    public var ixml: [String: String] = [:]
    public var xmp: [String: String] = [:]
    public var info: [String: String] = [:]
    public var aiff: [String: String] = [:]
    public var acid: AcidInfo?
    public var loopCount: Int?
    public var technical = AudioTechnical()
    public var warnings: [String] = []
}

/// Read-only reader for WAV/BWF/RF64/BW64 and AIFF metadata chunks. Audio
/// data is skipped, never loaded. Other formats return an empty result (the
/// app reads their tags with AVFoundation).
public enum MetadataReader {
    static let maxMetadataChunk: UInt64 = 16 * 1024 * 1024

    static let infoNames: [String: String] = [
        "INAM": "Title", "IART": "Artist", "ICMT": "Comment", "ICOP": "Copyright", "ICRD": "DateCreated",
        "IGNR": "Genre", "IKEY": "Keywords", "IPRD": "Product", "ISBJ": "Subject", "ISFT": "Software",
        "ISRC": "Source", "ITRK": "Track", "IENG": "Engineer", "ITCH": "Technician",
    ]

    public static func read(url: URL) -> RawMetadata {
        var raw = RawMetadata()
        guard let file = try? ReadOnlyFile(url: url) else {
            raw.warnings.append("could not open file")
            return raw
        }
        defer { file.close() }
        let header = file.read(at: 0, count: 12)
        guard header.count == 12 else { return raw }
        let magic = header.fourCC(at: 0), form = header.fourCC(at: 8)
        if ["RIFF", "RF64", "BW64"].contains(magic), form == "WAVE" {
            readWAV(file, magic: magic, into: &raw)
        } else if magic == "FORM", form == "AIFF" || form == "AIFC" {
            readAIFF(file, form: form, into: &raw)
        }
        return raw
    }

    // MARK: WAV

    private static func readWAV(_ file: ReadOnlyFile, magic: String, into raw: inout RawMetadata) {
        raw.container = magic
        var pos: UInt64 = 12
        var ds64DataSize: UInt64?
        var dataSize: UInt64?
        var blockAlign = 0
        var sampleRate = 0.0
        while pos + 8 <= file.size {
            let h = file.read(at: pos, count: 8)
            guard h.count == 8 else { break }
            let id = h.fourCC(at: 0)
            var size = UInt64(h.uint32LE(at: 4))
            if id == "data", size == 0xFFFF_FFFF, let real = ds64DataSize { size = real }
            if pos + 8 + size > file.size {
                raw.warnings.append("chunk '\(id)' runs past the end of the file")
                size = file.size - pos - 8
            }
            raw.chunkIDs.append(id)
            if id == "data" {
                dataSize = size
            } else if size <= maxMetadataChunk {
                let body = file.read(at: pos + 8, count: Int(size))
                switch id {
                case "ds64":
                    if body.count >= 16 { ds64DataSize = body.uint64LE(at: 8) }
                case "fmt ":
                    if body.count >= 16 {
                        raw.technical.channels = Int(body.uint16LE(at: 2))
                        sampleRate = Double(body.uint32LE(at: 4))
                        raw.technical.sampleRate = sampleRate
                        blockAlign = Int(body.uint16LE(at: 12))
                        raw.technical.bitsPerSample = Int(body.uint16LE(at: 14))
                    }
                case "bext": raw.bext = decodeBext(body)
                case "iXML", "IXML": raw.ixml = XMLFlattener.flatten(body)
                case "_PMX", "XMP ": raw.xmp = XMLFlattener.flatten(body)
                case "LIST":
                    if body.fourCC(at: 0) == "INFO" { raw.info.merge(decodeInfo(body)) { a, _ in a } }
                case "acid":
                    if body.count >= 24 {
                        raw.acid = AcidInfo(oneShot: body.uint32LE(at: 0) & 1 != 0,
                                            tempo: Double(body.float32LE(at: 20)),
                                            beats: Int(body.uint32LE(at: 12)))
                    }
                case "smpl":
                    if body.count >= 36 { raw.loopCount = Int(body.uint32LE(at: 28)) }
                default: break
                }
            } else {
                raw.warnings.append("skipped very large '\(id)' chunk")
            }
            pos += 8 + size + (size & 1)
        }
        if let d = dataSize, blockAlign > 0, sampleRate > 0 {
            raw.technical.duration = Double(d / UInt64(blockAlign)) / sampleRate
        }
    }

    static func decodeBext(_ b: Data) -> [String: String] {
        var out: [String: String] = [:]
        func put(_ key: String, _ value: String) { if !value.isEmpty { out[key] = value } }
        put("Description", b.metadataString(0 ..< 256))
        put("Originator", b.metadataString(256 ..< 288))
        put("OriginatorReference", b.metadataString(288 ..< 320))
        put("OriginationDate", b.metadataString(320 ..< 330))
        put("OriginationTime", b.metadataString(330 ..< 338))
        if b.count > 602 { put("CodingHistory", b.metadataString(602 ..< b.count)) }
        return out
    }

    static func decodeInfo(_ b: Data) -> [String: String] {
        var out: [String: String] = [:]
        var pos = 4
        while pos + 8 <= b.count {
            let id = b.fourCC(at: pos)
            let size = Int(b.uint32LE(at: pos + 4))
            let value = b.metadataString(pos + 8 ..< pos + 8 + size)
            if !value.isEmpty { out[infoNames[id] ?? id] = value }
            pos += 8 + size + (size & 1)
        }
        return out
    }

    // MARK: AIFF

    private static func readAIFF(_ file: ReadOnlyFile, form: String, into raw: inout RawMetadata) {
        raw.container = form
        let textChunks = ["NAME": "Title", "AUTH": "Author", "(c) ": "Copyright", "ANNO": "Annotation"]
        var pos: UInt64 = 12
        while pos + 8 <= file.size {
            let h = file.read(at: pos, count: 8)
            guard h.count == 8 else { break }
            let id = h.fourCC(at: 0)
            let size = min(UInt64(h.uint32BE(at: 4)), file.size - pos - 8)
            raw.chunkIDs.append(id)
            if id != "SSND", size <= maxMetadataChunk {
                let body = file.read(at: pos + 8, count: Int(size))
                if id == "COMM", body.count >= 18 {
                    let channels = Int(Int16(bitPattern: body.uint16BE(at: 0)))
                    let frames = Double(body.uint32BE(at: 2))
                    let bits = Int(Int16(bitPattern: body.uint16BE(at: 6)))
                    let rate = body.extended80BE(at: 8)
                    raw.technical = AudioTechnical(sampleRate: rate, channels: channels, bitsPerSample: bits,
                                                   duration: rate > 0 ? frames / rate : nil)
                } else if let name = textChunks[id] {
                    let v = body.metadataString()
                    if !v.isEmpty { raw.aiff[name] = v }
                } else if id == "iXML" || id == "IXML" {
                    raw.ixml = XMLFlattener.flatten(body)
                }
            }
            pos += 8 + size + (size & 1)
        }
    }
}
