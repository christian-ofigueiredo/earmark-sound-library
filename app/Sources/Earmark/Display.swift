import AppKit
import EarmarkCore

// MARK: formatting

/// "0:01.2" (precise, for sound effects) or "3:45".
func formatLength(_ seconds: Double?, precise: Bool = true) -> String {
    guard let s = seconds, s.isFinite, s >= 0 else { return "" }
    if precise {
        let tenths = Int((s * 10).rounded())
        return String(format: "%d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
    }
    let whole = Int(s.rounded())
    return String(format: "%d:%02d", whole / 60, whole % 60)
}

func formatBPM(_ bpm: Double) -> String {
    abs(bpm - bpm.rounded()) < 0.05 ? String(format: "%.0f", bpm) : String(format: "%.1f", bpm)
}

func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

/// Drag payload for Resolve, Finder and other apps: a reference to the original file.
func fileDragItem(_ url: URL) -> NSItemProvider {
    NSItemProvider(object: url as NSURL)
}

// MARK: sounds

extension SoundRecord {
    var displayName: String {
        if let fxName, !fxName.isEmpty { return fxName }
        return url.deletingPathExtension().lastPathComponent
    }

    var categoryText: String { ucsLabel?.capitalized ?? "" }
    var durationValue: Double { duration ?? 0 }

    var formatText: String {
        var parts: [String] = []
        if let sr = sampleRate, sr > 0 {
            parts.append(sr.truncatingRemainder(dividingBy: 1000) == 0
                ? "\(Int(sr / 1000)) kHz" : String(format: "%.1f kHz", sr / 1000))
        }
        if let bits = bitsPerSample, bits > 0 { parts.append("\(bits)-bit") }
        if let ch = channels, ch > 0 { parts.append(ch == 1 ? "Mono" : ch == 2 ? "Stereo" : "\(ch) ch") }
        return parts.joined(separator: " · ")
    }

    var searchText: String {
        [fileName, fxName, details, keywords, category, subcategory, catID, vendorLibrary, manufacturer, designer, folder]
            .compactMap { $0 }.joined(separator: " ").lowercased()
    }
}

struct SidebarNode: Identifiable, Hashable, Sendable {
    let id: SoundScope
    let title: String
    let count: Int
    var children: [SidebarNode]?
}

/// Lookups and counts for the sound list, built off the main thread.
struct SoundIndex: Sendable {
    var position: [Int64: Int] = [:]
    var haystacks: [String] = []
    var libraryCounts: [Int64: Int] = [:]
    var categories: [SidebarNode] = []
    var uncategorised = 0
    /// Sounds whose category is Earmark's guess for their folder.
    var guessed = 0
    /// MP3/WAV (etc.) copies of the same sound: only the best one is listed.
    var twins = FormatTwins.Groups()
    /// Sounds in the list, i.e. not counting hidden twins.
    var shownCount = 0

    init(_ sounds: [SoundRecord]) {
        haystacks.reserveCapacity(sounds.count)
        twins = FormatTwins.group(sounds)
        var byCategory: [String: [String: (name: String, count: Int)]] = [:]
        for (i, s) in sounds.enumerated() {
            if let id = s.id { position[id] = i }
            haystacks.append(s.searchText)
            if let id = s.id, twins.hidden.contains(id) { continue }
            shownCount += 1
            if s.categorySource == FolderRules.guessSource { guessed += 1 }
            libraryCounts[s.libraryId, default: 0] += 1
            if let category = s.category, let catID = s.catID {
                byCategory[category, default: [:]][catID, default: (s.subcategory ?? catID, 0)].count += 1
            } else {
                uncategorised += 1
            }
        }
        categories = byCategory.keys.sorted().map { category in
            let subs = byCategory[category, default: [:]]
                .map { SidebarNode(id: .catID($0.key), title: $0.value.name.capitalized, count: $0.value.count) }
                .sorted { $0.title < $1.title }
            return SidebarNode(id: .category(category), title: category.capitalized,
                               count: subs.reduce(0) { $0 + $1.count }, children: subs)
        }
    }
}

// MARK: music

extension MusicKey {
    /// All 24 keys in Camelot order (1A, 1B, 2A, …).
    static let wheel: [MusicKey] = (1 ... 12).flatMap { n in ["A", "B"].compactMap { MusicKey(parsing: "\(n)\($0)") } }

    /// Sort position on the Camelot wheel.
    var wheelOrder: Int { Self.wheel.firstIndex(of: self) ?? 99 }
}

extension SongRecord {
    var artistText: String { artist ?? "" }
    var bpmValue: Double { bpm ?? 0 }
    var durationValue: Double { duration ?? 0 }
    var keyOrder: Int { key?.wheelOrder ?? 99 }
    var relativeOrder: Int { key?.relative.wheelOrder ?? 99 }

    var searchText: String {
        [fileName, title, artist, album, folder, key?.name, key?.camelot].compactMap { $0 }.joined(separator: " ").lowercased()
    }
}

struct SongIndex: Sendable {
    var position: [Int64: Int] = [:]
    var haystacks: [String] = []
    var libraryCounts: [Int64: Int] = [:]
    var analysed = 0

    init(_ songs: [SongRecord]) {
        haystacks.reserveCapacity(songs.count)
        for (i, s) in songs.enumerated() {
            if let id = s.id { position[id] = i }
            haystacks.append(s.searchText)
            libraryCounts[s.libraryId, default: 0] += 1
            if s.bpm != nil || s.key != nil { analysed += 1 }
        }
    }
}

// MARK: sorting

/// Sorts records by a table's sort order with each record's keys worked out once. Sorting the
/// 28,827 sounds with the key paths directly took ~3.4 s on the main thread: Finder-style
/// string comparison is slow and `displayName` builds a URL on every call.
enum FastSort {
    /// One sort column: text keys (`textKey`) or numbers, and its direction.
    private struct Column {
        var texts: [String]?
        var numbers: [Double]?
        var reverse: Bool
    }

    static func sorted<R>(_ items: [R], by order: [KeyPathComparator<R>]) -> [R] {
        guard !order.isEmpty, items.count > 1 else { return items }
        var columns: [Column] = []
        for comparator in order {
            let reverse = comparator.order == .reverse
            switch comparator.keyPath {
            case let path as KeyPath<R, String>: columns.append(Column(texts: items.map { textKey($0[keyPath: path]) }, reverse: reverse))
            case let path as KeyPath<R, Double>: columns.append(Column(numbers: items.map { $0[keyPath: path] }, reverse: reverse))
            case let path as KeyPath<R, Int>: columns.append(Column(numbers: items.map { Double($0[keyPath: path]) }, reverse: reverse))
            default: return items.sorted(using: order)   // a column type this doesn't know
            }
        }
        let indices = items.indices.sorted { a, b in
            for c in columns {
                if let t = c.texts, t[a] != t[b] { return (t[a] < t[b]) != c.reverse }
                if let n = c.numbers, n[a] != n[b] { return (n[a] < n[b]) != c.reverse }
            }
            return a < b   // stable
        }
        return indices.map { items[$0] }
    }

    /// A key whose plain order is Finder's: case and accents ignored, numbers by value
    /// ("Hit 2" before "Hit 10").
    static func textKey(_ s: String) -> String {
        var out = "", digits = ""
        func flush() {
            guard !digits.isEmpty else { return }
            out += String(repeating: "0", count: max(0, 12 - digits.count)) + digits
            digits = ""
        }
        for c in s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) {
            if c.isASCII, c.isNumber { digits.append(c) } else { flush(); out.append(c) }
        }
        flush()
        return out
    }
}
