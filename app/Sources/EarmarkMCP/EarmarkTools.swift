import EarmarkCore
import Foundation
import MCP

/// The tools Earmark offers agents over MCP (docs/mcp-plan.md): finding sounds in the owner's
/// libraries and putting them on the timeline open in DaVinci Resolve. Reads Earmark's database
/// read-only (works with Earmark closed); never writes sound files or Earmark's data.
public actor EarmarkTools {
    /// Ways out of the process, so tests can stand in for them.
    public struct Outside: Sendable {
        /// Opens a URL (earmark://sound/<id>).
        public var open: @Sendable (URL) -> Void
        public var resolveStatus: @Sendable () async throws -> ResolveBridge.Status
        public var resolveAdd: @Sendable ([ResolveBridge.Item], Bool) async throws -> ResolveBridge.Added
        /// Where save_timeline_file writes (~/Movies/Earmark).
        public var timelineFolder: URL

        public init(open: @escaping @Sendable (URL) -> Void,
                    resolveStatus: @escaping @Sendable () async throws -> ResolveBridge.Status,
                    resolveAdd: @escaping @Sendable ([ResolveBridge.Item], Bool) async throws -> ResolveBridge.Added,
                    timelineFolder: URL = FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Movies/Earmark", isDirectory: true)) {
            self.open = open; self.resolveStatus = resolveStatus; self.resolveAdd = resolveAdd
            self.timelineFolder = timelineFolder
        }

        public static let live = Outside(
            open: { url in
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                p.arguments = [url.absoluteString]
                try? p.run()
            },
            resolveStatus: { try await ResolveBridge.status() },
            resolveAdd: { items, preview in try await ResolveBridge.add(items, preview: preview) })
    }

    let database: () throws -> LibraryDatabase
    let outside: Outside
    /// Earmark's database file, to see when it changed (nil: no file, e.g. tests).
    let path: String?
    private var catalog: SoundCatalog?
    private var catalogAt = Date.distantPast
    private var catalogStamp: [Date?] = []
    private var similarity: SimilarityIndex?
    private var similarityFor = -1

    /// `path`: Earmark's database, opened read-only.
    public init(databasePath path: String, outside: Outside = .live) {
        self.path = path
        self.database = { try LibraryDatabase(path: path, readOnly: true) }
        self.outside = outside
    }

    /// An open database (tests).
    public init(database: LibraryDatabase, outside: Outside) {
        self.path = nil
        self.database = { database }
        self.outside = outside
    }

    // MARK: reading

    private var db: LibraryDatabase?
    private func openDatabase() throws -> LibraryDatabase {
        if let db { return db }
        let opened = try database()
        db = opened
        return opened
    }

    /// The catalog, read again when Earmark has saved something since (at most every 10 s, as
    /// analysis saves often).
    func current() throws -> SoundCatalog {
        let stamp = path.map { p in [p, p + "-wal"].map { (try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate]) as? Date } } ?? []
        if let catalog, stamp == catalogStamp || Date().timeIntervalSince(catalogAt) < 10 { return catalog }
        let fresh = try SoundCatalog(try openDatabase())
        catalog = fresh
        catalogAt = Date()
        catalogStamp = stamp
        return fresh
    }

    func similarityIndex(_ c: SoundCatalog) throws -> SimilarityIndex {
        if let similarity, similarityFor == c.analysed.count { return similarity }
        let index = SimilarityIndex(vectors: try openDatabase().vectors(model: "clap-general"))
        similarity = index
        similarityFor = c.analysed.count
        return index
    }

    // MARK: calls

    /// Runs a tool. Problems come back as an error result for the agent to read, not a failure.
    public func call(_ name: String, _ arguments: [String: Value]) async -> CallTool.Result {
        do {
            switch name {
            case "library_overview": return try result(overview())
            case "search_sounds": return try result(search(Arguments(arguments)))
            case "get_sound": return try result(details(Arguments(arguments)))
            case "find_similar": return try result(similar(Arguments(arguments)))
            case "list_groups": return try result(groups(Arguments(arguments)))
            case "show_in_earmark": return try result(show(Arguments(arguments)))
            case "resolve_status": return try result(try await outside.resolveStatus())
            case "add_to_resolve": return try result(try await add(Arguments(arguments)))
            case "save_timeline_file": return try result(try saveTimelineFile(Arguments(arguments)))
            default: throw ToolError("There's no tool “\(name)”.")
            }
        } catch {
            return CallTool.Result(content: [.text(text: (error as? LocalizedError)?.errorDescription ?? "\(error)", annotations: nil, _meta: nil)],
                                   isError: true)
        }
    }

    /// The answer as JSON text (for any client) and as structured content.
    func result<T: Encodable>(_ value: T) throws -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        let structured = try JSONDecoder().decode(Value.self, from: data)
        return CallTool.Result(content: [.text(text: String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil)],
                               structuredContent: Optional(structured), isError: false)
    }

    // MARK: answers

    struct Row: Codable, Equatable {
        var id: Int64
        var name: String
        var file: String
        var category: String?
        var catID: String?
        var group: String?
        var groupId: Int64?
        /// Seconds.
        var length: Double?
        var format: String
        var library: String
        var folder: String
        var path: String
        /// Integrated loudness, LUFS.
        var loudness: Double?
        /// Cosine similarity, for find_similar.
        var similarity: Double?
    }

    func row(_ s: SoundRecord, _ c: SoundCatalog, similarity: Float? = nil) -> Row {
        let g = c.group(of: s)
        let facts = s.id.flatMap { c.facts[$0] }.flatMap { $0.isCurrent(for: s) ? $0 : nil }
        return Row(id: s.id ?? -1, name: s.displayName, file: s.fileName, category: s.ucsLabel?.capitalized, catID: s.catID,
                   group: g?.title, groupId: g?.id, length: s.duration.map { ($0 * 1000).rounded() / 1000 }, format: s.formatText,
                   library: c.library(s.libraryId)?.name ?? "", folder: s.folder, path: s.path,
                   loudness: facts?.loudness.map { ($0 * 10).rounded() / 10 }, similarity: similarity.map { (Double($0) * 1000).rounded() / 1000 })
    }

    struct Overview: Codable {
        struct LibraryInfo: Codable { var id: Int64; var name: String; var path: String; var online: Bool; var sounds: Int }
        struct Sub: Codable { var catID: String; var name: String; var sounds: Int; var groups: Int }
        struct Category: Codable { var category: String; var sounds: Int; var subcategories: [Sub] }
        var libraries: [LibraryInfo]
        var sounds: Int
        var analysed: Int
        var songs: Int
        var duplicates: Int
        var categories: [Category]
        var uncategorised: Int
    }

    func overview() throws -> Overview {
        let c = try current()
        let shown = c.sounds.filter(c.isShown)
        var bySub: [String: (category: String, name: String, count: Int)] = [:]
        for s in shown {
            guard let catID = s.catID, let category = s.category else { continue }
            bySub[catID, default: (category, s.subcategory ?? catID, 0)].count += 1
        }
        let categories = Dictionary(grouping: bySub, by: \.value.category).map { category, subs in
            Overview.Category(category: category.capitalized, sounds: subs.reduce(0) { $0 + $1.value.count },
                              subcategories: subs.map { Overview.Sub(catID: $0.key, name: $0.value.name.capitalized, sounds: $0.value.count,
                                                                     groups: c.groups.groups[$0.key]?.count ?? 0) }
                                  .sorted { $0.sounds > $1.sounds })
        }.sorted { $0.category < $1.category }
        let sounds = c.libraries.filter { $0.kind == .sounds }.map { lib in
            Overview.LibraryInfo(id: lib.id ?? -1, name: lib.name, path: lib.path, online: lib.isOnline,
                                 sounds: shown.filter { $0.libraryId == lib.id }.count)
        }
        return Overview(libraries: sounds, sounds: shown.count, analysed: shown.filter { c.analysed.contains($0.id ?? -1) }.count,
                        songs: c.songCount, duplicates: c.duplicates.setOf.count, categories: categories,
                        uncategorised: shown.filter { $0.catID == nil }.count)
    }

    struct Found: Codable { var total: Int; var offset: Int; var sounds: [Row] }

    func search(_ a: Arguments) throws -> Found {
        let c = try current()
        let filter = SoundCatalog.Filter(query: a.string("query"), category: a.string("category"), groupId: a.int64("group_id"),
                                         libraryId: a.int64("library_id"), minLength: a.double("min_length"),
                                         maxLength: a.double("max_length"), source: a.string("source"))
        let all = c.search(filter)
        let offset = max(0, a.int("offset") ?? 0), limit = min(200, max(1, a.int("limit") ?? 25))
        return Found(total: all.count, offset: offset, sounds: all.dropFirst(offset).prefix(limit).map { row($0, c) })
    }

    struct Details: Codable {
        struct Other: Codable { var id: Int64; var path: String; var similarity: Double? }
        struct GroupInfo: Codable { var id: Int64; var name: String; var keywords: [String] }
        var sound: Row
        var description: String?
        var keywords: String?
        var vendorLibrary: String?
        var manufacturer: String?
        var designer: String?
        var categorySource: String
        var groupInfo: GroupInfo?
        var peak: Double?
        var sampleRate: Double?
        var channels: Int?
        var bitsPerSample: Int?
        var analysed: Bool
        var online: Bool
        /// The same sound in other formats in its pack (hidden from lists).
        var otherFormats: [String]
        /// Byte-identical copies, and the same recording in other files.
        var copies: [Other]
        var sameRecording: [Other]
    }

    func sound(_ a: Arguments, _ c: SoundCatalog, key: String = "sound_id") throws -> SoundRecord {
        guard let id = a.int64(key) else { throw ToolError("Give “\(key)”, a sound's id from search_sounds.") }
        guard let s = c.sound(id) else { throw ToolError("There's no sound \(id).") }
        return s
    }

    func details(_ a: Arguments) throws -> Details {
        let c = try current()
        let s = try sound(a, c)
        let id = s.id ?? -1
        let g = c.group(of: s)
        let facts = c.facts[id].flatMap { $0.isCurrent(for: s) ? $0 : nil }
        let others = c.duplicates.others[id] ?? []
        return Details(sound: row(s, c), description: s.details, keywords: s.keywords, vendorLibrary: s.vendorLibrary,
                       manufacturer: s.manufacturer, designer: s.designer, categorySource: SoundCatalog.sourceText(s),
                       groupInfo: g.map { .init(id: $0.id ?? -1, name: $0.title, keywords: $0.keywordList) },
                       peak: facts?.peak, sampleRate: s.sampleRate, channels: s.channels, bitsPerSample: s.bitsPerSample,
                       analysed: c.analysed.contains(id), online: c.library(s.libraryId)?.isOnline ?? false,
                       otherFormats: (c.twins.alternates[id] ?? []).compactMap { c.sound($0)?.path },
                       copies: others.filter(\.identical).compactMap { o in c.sound(o.id).map { .init(id: o.id, path: $0.path, similarity: nil) } },
                       sameRecording: others.filter { !$0.identical }.compactMap { o in
                           c.sound(o.id).map { .init(id: o.id, path: $0.path, similarity: Double(o.similarity)) }
                       })
    }

    struct Similar: Codable { var sound: Row; var similar: [Row] }

    func similar(_ a: Arguments) throws -> Similar {
        let c = try current()
        let s = try sound(a, c)
        let index = try similarityIndex(c)
        guard let id = s.id, index.contains(id) else { throw ToolError("Sound \(s.id ?? -1) hasn't been analysed yet.") }
        // As the app's Find Similar Sounds: hidden format twins and byte-identical copies left out.
        var skip = c.twins.hidden
        if let fp = s.fingerprint { for other in c.sounds where other.fingerprint == fp && other.id != id { if let o = other.id { skip.insert(o) } } }
        let limit = min(100, max(1, a.int("limit") ?? 20))
        let found = index.nearest(to: id, count: limit, excluding: skip)
        return Similar(sound: row(s, c), similar: found.compactMap { m in c.sound(m.id).map { row($0, c, similarity: m.score) } })
    }

    struct Groups: Codable {
        struct Group: Codable { var id: Int64; var name: String; var keywords: [String]; var sounds: Int; var renamedByOwner: Bool }
        var catID: String
        var subcategory: String
        var groups: [Group]
    }

    func groups(_ a: Arguments) throws -> Groups {
        let c = try current()
        guard let key = a.string("subcategory"), let entry = UCSCatalog.shared.entry(catID: key)
                ?? UCSCatalog.shared.entries.first(where: { $0.label.lowercased() == key.lowercased() }) else {
            throw ToolError("Give “subcategory”: a CatID (“FEETHmn”) or “Category / Subcategory”, as library_overview lists them.")
        }
        var counts: [Int64: Int] = [:]
        for s in c.sounds where c.isShown(s) { if let g = c.group(of: s)?.id { counts[g, default: 0] += 1 } }
        let list = (c.groups.groups[entry.catID] ?? []).map {
            Groups.Group(id: $0.id ?? -1, name: $0.title, keywords: $0.keywordList, sounds: counts[$0.id ?? -1] ?? 0,
                         renamedByOwner: $0.userName != nil)
        }
        return Groups(catID: entry.catID, subcategory: entry.label.capitalized, groups: list)
    }

    struct Shown: Codable { var shown: Int64; var name: String }

    func show(_ a: Arguments) throws -> Shown {
        let c = try current()
        let s = try sound(a, c)
        outside.open(URL(string: "earmark://sound/\(s.id ?? -1)")!)
        return Shown(shown: s.id ?? -1, name: s.displayName)
    }

    struct Placed: Codable {
        struct Item: Codable {
            var sound_id: Int64
            var placed: Bool
            var track: Int?
            var trackName: String?
            var start: String?
            var end: String?
            var newTrack: Bool?
            var problem: String?
        }
        var preview: Bool
        var project: String
        var timeline: String
        var items: [Item]
    }

    func add(_ a: Arguments) async throws -> Placed {
        let c = try current()
        guard let list = a.list("items"), !list.isEmpty else {
            throw ToolError("Give “items”: a list of { sound_id, start, end, at, track }.")
        }
        let preview = a.bool("preview") ?? false
        var items: [ResolveBridge.Item] = [], ids: [Int64] = []
        for (n, entry) in list.enumerated() {
            let e = Arguments(entry.objectValue ?? [:])
            guard let id = e.int64("sound_id"), let s = c.sound(id) else { throw ToolError("Item \(n + 1): no such sound_id.") }
            guard FileManager.default.fileExists(atPath: s.path) else {
                throw ToolError("Item \(n + 1): “\(s.displayName)” is offline (its drive isn't connected).")
            }
            let at: ResolveBridge.At? = e.double("at").map { .seconds($0) } ?? e.string("at").map { .timecode($0) }
            let track: ResolveBridge.Track = e.int("track").map { .index($0) } ?? (e.string("track") == "free" ? .free : .earmark)
            items.append(.init(path: s.path, start: e.double("start"), end: e.double("end"), at: at, track: track,
                               length: s.duration, channels: s.channels))
            ids.append(id)
        }
        let added = try await outside.resolveAdd(items, preview)
        return Placed(preview: preview, project: added.project, timeline: added.timeline,
                      items: zip(ids, added.items).map { id, p in
                          .init(sound_id: id, placed: p.ok == true, track: p.track, trackName: p.trackName, start: p.start, end: p.end,
                                newTrack: p.newTrack, problem: p.problem)
                      })
    }
}

extension EarmarkTools {
    struct SavedTimeline: Codable {
        struct Item: Codable {
            var sound_id: Int64
            var track: Int
            var start: String
            var end: String
        }
        var path: String
        var frameRate: String
        var items: [Item]
        var howToImport: String
    }

    /// The items as an FCPXML timeline file (docs/timeline-file-plan.md), for the free DaVinci
    /// Resolve or Final Cut Pro. Writes only into `outside.timelineFolder`.
    func saveTimelineFile(_ a: Arguments) throws -> SavedTimeline {
        let c = try current()
        guard let list = a.list("items"), !list.isEmpty else {
            throw ToolError("Give “items”: a list of { sound_id, start, end, at }.")
        }
        let rateName = a.string("frame_rate") ?? a.double("frame_rate").map { String(format: "%g", $0) } ?? "25"
        guard let rate = TimelineFile.Rate.named(rateName) else {
            throw ToolError("“frame_rate” must be one of: " + TimelineFile.Rate.all.map(\.name).joined(separator: ", ") + ".")
        }
        var clips: [TimelineFile.Clip] = [], ids: [Int64] = []
        for (n, entry) in list.enumerated() {
            let e = Arguments(entry.objectValue ?? [:])
            guard let id = e.int64("sound_id"), let s = c.sound(id) else { throw ToolError("Item \(n + 1): no such sound_id.") }
            guard FileManager.default.fileExists(atPath: s.path) else {
                throw ToolError("Item \(n + 1): “\(s.displayName)” is offline (its drive isn't connected).")
            }
            guard let length = s.duration, length > 0 else { throw ToolError("Item \(n + 1): Earmark doesn't know its length.") }
            clips.append(.init(path: s.path, name: s.displayName, length: length, sampleRate: Int(s.sampleRate ?? 48000),
                               channels: s.channels ?? 2, timeReference: MetadataReader.timeReference(url: URL(fileURLWithPath: s.path)),
                               start: e.double("start"), end: e.double("end"), at: e.double("at")))
            ids.append(id)
        }
        let rawName = a.string("name") ?? "Earmark sounds"
        let name = rawName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let file = try TimelineFile.fcpxml(clips, rate: rate, startTimecode: a.string("start_timecode") ?? "01:00:00:00",
                                           name: name.isEmpty ? "Earmark sounds" : name)
        let folder = outside.timelineFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder.appendingPathComponent((name.isEmpty ? "Earmark sounds" : name) + ".fcpxml")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name.isEmpty ? "Earmark sounds" : name) \(n).fcpxml")
            n += 1
        }
        try Data(file.xml.utf8).write(to: url, options: .withoutOverwriting)
        return SavedTimeline(path: url.path, frameRate: rate.name,
                             items: zip(ids, file.placements).map { .init(sound_id: $0, track: $1.lane, start: $1.start, end: $1.end) },
                             howToImport: "DaVinci Resolve: File ▸ Import ▸ Timeline… (a new timeline; copy its clips into yours). "
                                + "Final Cut Pro: File ▸ Import ▸ XML…")
    }
}

/// A problem with a tool call, told to the agent.
struct ToolError: Error, LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// A tool call's arguments, read leniently (agents send numbers as strings at times).
struct Arguments {
    var values: [String: Value]
    init(_ values: [String: Value]) { self.values = values }

    func string(_ key: String) -> String? {
        switch values[key] {
        case .string(let s)?: s.isEmpty ? nil : s
        case .int(let i)?: String(i)
        case .double(let d)?: String(d)
        default: nil
        }
    }

    func double(_ key: String) -> Double? {
        switch values[key] {
        case .double(let d)?: d
        case .int(let i)?: Double(i)
        case .string(let s)?: Double(s)
        default: nil
        }
    }

    func int(_ key: String) -> Int? {
        switch values[key] {
        case .int(let i)?: i
        case .double(let d)? where d == d.rounded(): Int(d)
        case .string(let s)?: Int(s)
        default: nil
        }
    }

    func int64(_ key: String) -> Int64? { int(key).map(Int64.init) }

    func bool(_ key: String) -> Bool? {
        switch values[key] {
        case .bool(let b)?: b
        case .string(let s)?: ["true", "yes", "1"].contains(s.lowercased())
        default: nil
        }
    }

    func list(_ key: String) -> [Value]? { values[key]?.arrayValue }
}
