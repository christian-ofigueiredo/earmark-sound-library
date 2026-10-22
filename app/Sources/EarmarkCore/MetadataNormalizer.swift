import Foundation

public enum MetadataField: String, CaseIterable, Sendable, Codable, CodingKeyRepresentable {
    case description, fxName, category, subcategory, catID, keywords, library, manufacturer, designer, notes, bpm, key
}

public struct UCSAssignment: Sendable, Codable, Equatable {
    public var catID: String
    public var category: String
    public var subcategory: String
    /// Where it came from, e.g. "iXML USER/CATID", "UCS filename".
    public var source: String
}

/// One normalized record per file: the useful fields, where each came from,
/// and the UCS category if the vendor provided one.
public struct NormalizedMetadata: Sendable, Codable, Equatable {
    public var fields: [MetadataField: String] = [:]
    public var sources: [MetadataField: String] = [:]
    public var ucs: UCSAssignment?

    public subscript(_ f: MetadataField) -> String? { fields[f] }
}

public enum MetadataNormalizer {
    /// iXML leaf names (case-insensitive), most specific first. Soundminer
    /// writes these under USER; game audio uses ASWG.
    static let ixmlNames: [(MetadataField?, String, [String])] = [
        (.description, "description", ["DESCRIPTION", "BWF_DESCRIPTION", "NOTE"]),
        (.fxName, "fxname", ["FXNAME", "TRACKTITLE", "TITLE"]),
        (.category, "category", ["CATEGORY"]),
        (.subcategory, "subcategory", ["SUBCATEGORY"]),
        (.catID, "catid", ["CATID"]),
        (nil, "categoryfull", ["CATEGORYFULL"]),
        (.keywords, "keywords", ["KEYWORDS"]),
        (.library, "library", ["LIBRARY", "SHOW", "PROJECT"]),
        (.manufacturer, "manufacturer", ["MANUFACTURER", "VENDOR", "BWF_ORIGINATOR", "ORIGINATOR"]),
        (.designer, "designer", ["DESIGNER", "CREATORID", "RECORDIST"]),
        (.notes, "notes", ["NOTES"]),
        (.bpm, "bpm", ["BPM", "TEMPO"]),
        (.key, "key", ["KEY", "MUSICALKEY", "INITIALKEY"]),
    ]
    static let sectionOrder = ["USER", "ASWG", "STEINBERG", "BEXT", ""]

    /// Web addresses, download-site watermarks and binary junk that some packs
    /// put in the description field.
    static let junkPattern = #"(www\.|https?:|\.com\b|\.ru\b|\.net\b|GET MORE ASSETS|^[0-9A-Fa-f]{24,}$)"#

    public static func isJunk(_ s: String) -> Bool {
        s.range(of: junkPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func ixmlFind(_ ixml: [String: String], _ names: [String]) -> (String, String)? {
        for name in names {
            let hits = ixml.filter { k, v in
                !k.contains("@") && k.split(separator: "/").last.map { $0.uppercased() == name } == true
                    && !v.trimmingCharacters(in: .whitespaces).isEmpty
            }.sorted { $0.key < $1.key }
            guard !hits.isEmpty else { continue }
            for section in sectionOrder {
                if let hit = hits.first(where: { k, _ in
                    section.isEmpty || k.split(separator: "/").dropLast().map { $0.uppercased() }.contains(section)
                }) {
                    return (hit.value, hit.key)
                }
            }
        }
        return nil
    }

    public static func normalize(_ raw: RawMetadata, url: URL, catalog: UCSCatalog = .shared) -> NormalizedMetadata {
        var out = NormalizedMetadata()
        var categoryFull: String?

        func put(_ field: MetadataField, _ value: String?, _ source: String) {
            guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty, out.fields[field] == nil else { return }
            if field == .description, isJunk(v) { return }
            out.fields[field] = v
            out.sources[field] = source
        }

        for (field, _, names) in ixmlNames {
            guard let (value, path) = ixmlFind(raw.ixml, names) else { continue }
            if let field { put(field, value, "iXML \(path)") } else if categoryFull == nil { categoryFull = value }
        }
        put(.description, raw.bext["Description"], "bext Description")
        put(.manufacturer, raw.bext["Originator"], "bext Originator")

        for (k, v) in raw.xmp.sorted(by: { $0.key < $1.key }) {
            if k.hasSuffix("description/Alt/li") { put(.description, v, "XMP \(k)") }
            else if k.hasSuffix("title/Alt/li") { put(.fxName, v, "XMP \(k)") }
            else if k.hasSuffix("subject/Bag/li") { put(.keywords, v.replacingOccurrences(of: " | ", with: ", "), "XMP \(k)") }
        }

        put(.fxName, raw.info["Title"], "INFO INAM")
        put(.description, raw.info["Comment"] ?? raw.info["Subject"], "INFO ICMT/ISBJ")
        put(.keywords, raw.info["Keywords"], "INFO IKEY")
        put(.library, raw.info["Product"], "INFO IPRD")
        put(.designer, raw.info["Artist"] ?? raw.info["Engineer"], "INFO IART/IENG")
        put(.category, raw.info["Genre"], "INFO IGNR")
        if let acid = raw.acid, !acid.oneShot, acid.tempo > 0 { put(.bpm, String(format: "%.2f", acid.tempo), "acid chunk") }
        put(.fxName, raw.aiff["Title"], "AIFF NAME")
        put(.description, raw.aiff["Annotation"], "AIFF ANNO")
        put(.designer, raw.aiff["Author"], "AIFF AUTH")

        // UCS: explicit CatID, then Category/SubCategory text, then filename, then folders.
        var entry = catalog.entry(catID: out.fields[.catID])
        var source = entry != nil ? out.sources[.catID] : nil
        if entry == nil {
            entry = catalog.entry(category: out.fields[.category] ?? categoryFull, subcategory: out.fields[.subcategory])
            source = entry != nil ? out.sources[.category] : nil
        }
        let stem = url.deletingPathExtension().lastPathComponent
        if let parsed = catalog.parseFilename(stem) {
            put(.fxName, parsed.fxName, "UCS filename")
            put(.designer, parsed.creatorID, "UCS filename")
            put(.library, parsed.sourceID, "UCS filename")
            if entry == nil { entry = parsed.entry; source = "UCS filename" }
        }
        if entry == nil {
            var dir = url.deletingLastPathComponent()
            for _ in 0 ..< 3 {
                if let e = catalog.entry(folderName: dir.lastPathComponent) {
                    entry = e; source = "folder name '\(dir.lastPathComponent)'"
                    break
                }
                dir = dir.deletingLastPathComponent()
            }
        }
        if let e = entry {
            let src = source ?? "metadata"
            out.ucs = UCSAssignment(catID: e.catID, category: e.category, subcategory: e.subcategory, source: src)
            out.fields[.catID] = e.catID; out.sources[.catID] = out.sources[.catID] ?? src
            out.fields[.category] = e.category; out.sources[.category] = out.sources[.category] ?? src
            out.fields[.subcategory] = e.subcategory; out.sources[.subcategory] = out.sources[.subcategory] ?? src
        }
        return out
    }
}
