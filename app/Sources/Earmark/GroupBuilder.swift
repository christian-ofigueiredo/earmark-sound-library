import EarmarkCore
import EarmarkML
import Foundation

/// Makes and keeps the similarity groups inside each subcategory (`SoundGroups`), in the
/// background: after the library is read and as analysis brings in sounds (both models are
/// needed). New sounds join the nearest group; a subcategory is grouped afresh when a quarter
/// of it has changed, unless the owner has changed its groups (`SoundGroupPlan`). The whole
/// library takes about half a minute on one core. Groups live in Earmark's database.
@MainActor
final class GroupBuilder {
    private var task: Task<Void, Never>?
    /// Asked again while running: looks again when done.
    private var again = false

    nonisolated static let models = [PeavEmbedder.modelName, ClapEmbedder.modelName]
    nonisolated static let dimensions = 1024 + 512

    func update(model: AppModel) {
        guard let db = model.database, model.hasLoaded else { return }
        if task != nil { again = true; return }
        let work = SoundGroupPlan.work(sounds: buckets(model), stored: model.groups)
        guard !work.isEmpty else { return }
        task = Task {
            await run(work, model: model, db: db)
            task = nil
            if again {
                again = false
                update(model: model)
            }
        }
    }

    /// Each subcategory's sounds that can be grouped: analysed by both models, in the list (not
    /// a hidden format twin).
    private func buckets(_ model: AppModel) -> [String: [(id: Int64, fingerprint: String?)]] {
        let hidden = model.soundIndex.twins.hidden
        let clap = model.analysis.clapStatus, peav = model.analysis.peavStatus
        var out: [String: [(id: Int64, fingerprint: String?)]] = [:]
        for s in model.sounds {
            guard let id = s.id, let catID = s.catID, !hidden.contains(id),
                  SoundEmbedding.isCurrent(clap[id], model: ClapEmbedder.modelName, for: s),
                  SoundEmbedding.isCurrent(peav[id], model: PeavEmbedder.modelName, for: s) else { continue }
            out[catID, default: []].append((id, s.fingerprint))
        }
        return out
    }

    private func run(_ work: [SoundGroupWork], model: AppModel, db: LibraryDatabase) async {
        model.groupProgress = (0, work.count)
        defer { model.groupProgress = nil }
        let sounds = Dictionary(model.sounds.compactMap { s in s.id.map { ($0, s) } }, uniquingKeysWith: { a, _ in a })
        var libraryMean: [Float]?
        let started = Date()
        var shown = started
        for (i, item) in work.enumerated() {
            do {
                switch item {
                case .drop(let catID):
                    try await Task.detached(priority: .background) { try db.dropGroups(catID: catID) }.value
                case .regroup(let catID, let ids):
                    if libraryMean == nil {
                        libraryMean = try await Task.detached(priority: .background) { try Self.mean(db) }.value
                    }
                    let mean = libraryMean ?? []
                    let records = ids.compactMap { sounds[$0] }
                    try await Task.detached(priority: .background) {
                        try Self.regroup(catID: catID, sounds: records, mean: mean, db: db)
                    }.value
                case .update(let catID, let add, let remove):
                    let stored = model.groups
                    let records = add.compactMap { sounds[$0] }
                    try await Task.detached(priority: .background) {
                        try Self.join(catID: catID, sounds: records, remove: remove, stored: stored, db: db)
                    }.value
                }
            } catch {
                model.analysis.note("Couldn't group \(item): \(error)")
            }
            model.groupProgress = (i + 1, work.count)
            // Show groups as they come, every few seconds.
            if Date().timeIntervalSince(shown) > 3 || i == work.count - 1 {
                await model.reloadGroups()
                shown = Date()
            }
        }
        let made = work.count { if case .regroup = $0 { true } else { false } }
        model.analysis.note(String(format: "Similarity groups: %d subcategories grouped, %d updated in %.0f s",
                                   made, work.count - made, Date().timeIntervalSince(started)))
    }

    /// Every analysed sound's vector, averaged (the words that fit the whole library count less
    /// in names). Read one sound at a time.
    nonisolated static func mean(_ db: LibraryDatabase) throws -> [Float] {
        var sum = [Double](repeating: 0, count: dimensions), n = 0
        try db.forEachVectors(models: models) { _, blocks in
            for (c, v) in SoundMap.combine(blocks).enumerated() { sum[c] += Double(v) }
            n += 1
        }
        return sum.map { Float($0 / Double(max(1, n))) }
    }

    /// The sounds' combined vectors, row after row by sound id (sounds without both are left
    /// out), straight into a `PageBuffer`.
    nonisolated static func vectors(_ db: LibraryDatabase, ids: [Int64]) throws -> (ids: [Int64], buffer: PageBuffer) {
        var buffer = PageBuffer(count: 0)
        var found: [Int64] = []
        try db.forEachVectors(models: models, ids: ids, count: { buffer = PageBuffer(count: $0 * dimensions) }) { id, blocks in
            let r = found.count
            guard (r + 1) * dimensions <= buffer.count else { return }
            buffer.withFloats { x in for (c, v) in SoundMap.combine(blocks).enumerated() { x[r * dimensions + c] = v } }
            found.append(id)
        }
        return (found, buffer)
    }

    nonisolated static func regroup(catID: String, sounds: [SoundRecord], mean: [Float], db: LibraryDatabase) throws {
        let (ids, buffer) = try vectors(db, ids: sounds.compactMap(\.id))
        let byId = Dictionary(uniqueKeysWithValues: sounds.compactMap { s in s.id.map { ($0, s) } })
        let n = ids.count, d = dimensions
        guard n > 0 else { return }
        let ordered = ids.compactMap { byId[$0] }
        guard ordered.count == n else { return }
        let made: (rows: [[Int]], names: [SoundGroups.Name])? = buffer.withFloats { x in
            let x = UnsafeBufferPointer(x)
            guard let labels = SoundGroups.cluster(x, count: n, dimensions: d) else { return nil }
            let k = (labels.max() ?? -1) + 1
            let rows = (0 ..< k).map { g in labels.indices.filter { labels[$0] == g } }
            return (rows, SoundGroups.names(groups: rows, x: x, dimensions: d, members: ordered.map(SoundGroups.Member.init),
                                            libraryMean: mean, exclude: SoundGroups.excludedWords(for: ordered)))
        }
        guard let (rows, names) = made else { return }
        try db.replaceGroups(catID: catID, groups: rows.map { $0.map { (ids[$0], ordered[$0].fingerprint) } }, names: names)
    }

    /// New sounds join the group whose centre is nearest; sounds that left are taken out.
    nonisolated static func join(catID: String, sounds: [SoundRecord], remove: [Int64], stored: SoundGroupSnapshot,
                                 db: LibraryDatabase) throws {
        let groups = Set((stored.groups[catID] ?? []).compactMap(\.id))
        let removing = Set(remove)
        let members = stored.membership.filter { groups.contains($0.value) && !removing.contains($0.key) }
        let (ids, buffer) = try vectors(db, ids: Array(members.keys) + sounds.compactMap(\.id))
        let rows = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
        var byGroup: [Int64: [Int]] = [:]
        for (sound, group) in members { if let r = rows[sound] { byGroup[group, default: []].append(r) } }
        var add: [(id: Int64, fingerprint: String?, group: Int64)] = []
        buffer.withFloats { x in
            let all = UnsafeBufferPointer(x)
            for s in sounds {
                guard let id = s.id, let r = rows[id],
                      let g = SoundGroupPlan.nearest(Array(all[r * dimensions ..< (r + 1) * dimensions]), x: all, d: dimensions, members: byGroup)
                else { continue }
                add.append((id, s.fingerprint, g))
            }
        }
        try db.updateGroups(catID: catID, add: add, remove: remove)
    }
}
