import Foundation

/// One subcategory of the Universal Category System (UCS v8.2.1, public domain).
public struct UCSEntry: Sendable, Hashable, Codable {
    public let category: String
    public let subcategory: String
    public let catID: String
    public let catShort: String
    public let explanation: String
    public let synonyms: [String]

    public var label: String { "\(category) / \(subcategory)" }
}

/// A UCS-style filename: `CatID_FXName_CreatorID_SourceID[_UserData]`.
public struct UCSFilename: Sendable, Equatable {
    public let entry: UCSEntry
    public let fxName: String?
    public let creatorID: String?
    public let sourceID: String?
    public let userData: String?
}

public enum UCSError: Error {
    case missingResource
    case badHeader
}

public final class UCSCatalog: Sendable {
    public let entries: [UCSEntry]
    private let byLowerCatID: [String: UCSEntry]
    private let byCategory: [String: [UCSEntry]]

    /// The UCS list bundled with Earmark.
    public static let shared: UCSCatalog = {
        do { return try UCSCatalog.loadBundled() } catch { fatalError("UCS list missing from the app bundle: \(error)") }
    }()

    public static func loadBundled() throws -> UCSCatalog {
        guard let url = bundledResource("ucs_v8.2.1", withExtension: "csv") else { throw UCSError.missingResource }
        return try UCSCatalog(csv: String(contentsOf: url, encoding: .utf8))
    }

    /// SwiftPM looks for the resource bundle at the top of an .app, but a signed
    /// .app keeps it in Contents/Resources, so look there first.
    static func bundledResource(_ name: String, withExtension ext: String) -> URL? {
        for base in [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap({ $0 }) {
            if let bundle = Bundle(url: base.appendingPathComponent("Earmark_EarmarkCore.bundle")),
               let url = bundle.url(forResource: name, withExtension: ext) {
                return url
            }
        }
        return Bundle.module.url(forResource: name, withExtension: ext)
    }

    public init(csv: String) throws {
        let rows = CSV.parse(csv)
        guard let header = rows.first, header.starts(with: ["Category", "SubCategory", "CatID"]) else {
            throw UCSError.badHeader
        }
        var entries: [UCSEntry] = []
        for r in rows.dropFirst() where r.count >= 6 && !r[2].isEmpty {
            entries.append(UCSEntry(
                category: r[0], subcategory: r[1], catID: r[2], catShort: r[3], explanation: r[4],
                synonyms: r[5].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            ))
        }
        self.entries = entries
        self.byLowerCatID = Dictionary(entries.map { ($0.catID.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        self.byCategory = Dictionary(grouping: entries, by: { $0.category })
    }

    public var categories: [String] { byCategory.keys.sorted() }

    public func subcategories(of category: String) -> [UCSEntry] { byCategory[category] ?? [] }

    public func entry(catID: String?) -> UCSEntry? {
        guard let id = catID?.trimmingCharacters(in: .whitespaces), !id.isEmpty else { return nil }
        return byLowerCatID[id.lowercased()]
    }

    /// Match free-text Category/SubCategory fields, including the
    /// "CATEGORY-SUBCATEGORY" form used by CategoryFull.
    public func entry(category: String?, subcategory: String?) -> UCSEntry? {
        guard var cat = category?.trimmingCharacters(in: .whitespaces).uppercased(), !cat.isEmpty else { return nil }
        var sub = (subcategory ?? "").trimmingCharacters(in: .whitespaces).uppercased()
        if sub.isEmpty, let dash = cat.firstIndex(of: "-") {
            sub = String(cat[cat.index(after: dash)...]).trimmingCharacters(in: .whitespaces)
            cat = String(cat[..<dash]).trimmingCharacters(in: .whitespaces)
        }
        return byCategory[cat]?.first { $0.subcategory.uppercased() == sub }
    }

    /// Parse a UCS filename. The CatID must be exact-case ("AMBForst") or all
    /// capitals ("AMBFORST"), so ordinary words ("rain_01") don't count.
    public func parseFilename(_ stem: String) -> UCSFilename? {
        let parts = stem.split(separator: "_", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return nil }
        let catID = String(parts[0].split(separator: "-", maxSplits: 1).first ?? "")
        guard let entry = entry(catID: catID), catID == entry.catID || catID == catID.uppercased() && catID != catID.lowercased() else {
            return nil
        }
        func part(_ i: Int) -> String? {
            guard i < parts.count else { return nil }
            let v = parts[i].trimmingCharacters(in: .whitespaces)
            return v.isEmpty ? nil : v
        }
        return UCSFilename(entry: entry, fxName: part(1), creatorID: part(2), sourceID: part(3),
                           userData: parts.count > 4 ? parts[4...].joined(separator: "_") : nil)
    }

    /// Folder names only count when unmistakably UCS: an exact-case CatID
    /// ("WHSH", "AMBForst_Woods") or "CATEGORY-SUBCATEGORY" in capitals.
    public func entry(folderName name: String) -> UCSEntry? {
        let name = name.trimmingCharacters(in: .whitespaces)
        let head = String(name.split(separator: "_", maxSplits: 1).first ?? "")
        if let e = entry(catID: head), e.catID == head { return e }
        if name == name.uppercased(), name.contains("-") { return entry(category: name, subcategory: nil) }
        return nil
    }
}
