import EarmarkCore
import Foundation

/// Gives every folder whose sounds have no category one of Earmark's own: the folder's best
/// suggestion, applied without asking. Runs in the background after the library is read; the
/// user corrects what's wrong later (Folder Categories, or a sound's detail pane), and their
/// choice always wins. Guesses live in Earmark's database; files are never changed.
@MainActor
final class FolderGuesser {
    private var task: Task<Void, Never>?

    private struct Work {
        var folders: [(key: FolderMapper.Key, sounds: [SoundRecord], analysed: Int)]
        var stale: [FolderMapper.Key]
    }

    /// Called after every reload: guesses folders that have none, whose guess is from an older
    /// `FolderSuggester`, or whose sounds have been analysed since; forgets guesses of folders
    /// that no longer need one.
    func update(model: AppModel) {
        guard task == nil, let db = model.database else { return }
        let work = plan(model)
        guard !work.folders.isEmpty || !work.stale.isEmpty else { return }
        task = Task {
            await run(work, model: model, db: db)
            task = nil
        }
    }

    private func plan(_ model: AppModel) -> Work {
        let hidden = model.soundIndex.twins.hidden
        var open: [FolderMapper.Key: [SoundRecord]] = [:]
        for s in model.sounds where s.catID == nil || s.categorySource == FolderRules.source || s.categorySource == FolderRules.guessSource {
            guard let id = s.id, !hidden.contains(id) else { continue }
            open[FolderMapper.Key(libraryId: s.libraryId, folder: s.folder), default: []].append(s)
        }
        let guesses = Dictionary(model.folderGuesses.map { (FolderMapper.Key(libraryId: $0.libraryId, folder: $0.folder), $0) },
                                 uniquingKeysWith: { a, _ in a })
        let clap = model.analysis.clapStatus
        var folders: [(key: FolderMapper.Key, sounds: [SoundRecord], analysed: Int)] = []
        for (key, sounds) in open {
            let analysed = sounds.count { clap[$0.id ?? -1] != nil }
            if let g = guesses[key], g.version == FolderSuggester.version,
               analysed <= g.analysed + max(5, sounds.count / 5) { continue }
            folders.append((key, sounds, analysed))
        }
        folders.sort { $0.sounds.count != $1.sounds.count ? $0.sounds.count > $1.sounds.count : $0.key.folder < $1.key.folder }
        return Work(folders: folders, stale: guesses.keys.filter { open[$0] == nil })
    }

    private func run(_ work: Work, model: AppModel, db: LibraryDatabase) async {
        model.guessProgress = (0, work.folders.count)
        defer { model.guessProgress = nil }
        let index = try? await model.similarityIndex()
        let all = model.sounds
        let (labels, shared) = await Task.detached(priority: .utility) {
            (FolderSuggester.labels(all), FolderSuggester.sharedDescriptions(all))
        }.value
        var batch: [FolderGuess] = []
        var stale = work.stale.map { (libraryId: $0.libraryId, folder: $0.folder) }
        func save() async {
            do {
                try db.updateGuesses(saving: batch, removing: stale)
                batch = []
                stale = []
                await model.reload()
            } catch {
                model.show(error, title: "Couldn't save Earmark's guesses")
            }
        }
        for (i, folder) in work.folders.enumerated() {
            let options = await Task.detached(priority: .utility) {
                FolderSuggester.suggest(folder: folder.key.folder, sounds: folder.sounds, index: index, labels: labels,
                                        sharedDescriptions: shared)
            }.value
            if let top = options.first {
                batch.append(FolderGuess(libraryId: folder.key.libraryId, folder: folder.key.folder, catID: top.entry.catID,
                                         alternatives: options.dropFirst().map(\.entry.catID),
                                         reason: FolderMapper.reason(top), isUnsure: top.isWeak, analysed: folder.analysed))
            }
            model.guessProgress = (i + 1, work.folders.count)
            // In batches, so categories fill in while the rest is guessed.
            if batch.count >= 40 { await save() }
        }
        if !batch.isEmpty || !stale.isEmpty { await save() }
    }
}
