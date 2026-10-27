import AppKit
import EarmarkCore
import SwiftUI

// MARK: export and import of analysis files (File ▸ Export Analysis… / Import Analysis…)

/// The libraries the Export sheet starts with ticked.
struct ExportRequest: Identifiable {
    let id = UUID()
    var libraryIds: Set<Int64>
}

extension AppModel {
    /// Opens the Export sheet, with these libraries ticked (all of them by default).
    func chooseExport(_ libraries: [Library]? = nil) {
        exportRequest = ExportRequest(libraryIds: Set((libraries ?? soundLibraries + musicLibraries).compactMap(\.id)))
    }

    /// One analysis file per library, in a folder the user picks: never inside a library.
    func export(libraryIds: Set<Int64>, includeEmbeddings: Bool) {
        let all = soundLibraries + musicLibraries
        let libraries = all.filter { libraryIds.contains($0.id ?? -1) }
        guard let db = database, !libraries.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a folder for the analysis files, one per library (not inside one of your libraries)."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        if let lib = AnalysisFile.library(containing: folder, in: all) {
            alert = AppAlert(title: "Choose a folder outside your libraries",
                             message: "“\(folder.lastPathComponent)” is inside “\(lib.name)”. Earmark never writes anything inside your libraries.")
            return
        }
        Task {
            var written: [(url: URL, bytes: Int)] = []
            defer { activity = nil }
            for lib in libraries {
                activity = "Exporting the analysis of “\(lib.name)”…"
                let url = folder.appendingPathComponent(AnalysisFile.fileName(for: lib))
                do {
                    let bytes = try await Task.detached(priority: .userInitiated) {
                        try db.writeAnalysisFile(for: lib, includeEmbeddings: includeEmbeddings, to: url)
                    }.value
                    written.append((url, bytes))
                } catch {
                    show(error, title: "Couldn't export the analysis of “\(lib.name)”")
                    return
                }
            }
            let files = written.map { "\($0.url.lastPathComponent) (\(ByteCountFormatter.string(fromByteCount: Int64($0.bytes), countStyle: .file)))" }
            alert = AppAlert(
                title: written.count == 1 ? "Exported the analysis of “\(libraries[0].name)”" : "Exported the analysis of \(written.count) libraries",
                message: files.joined(separator: "\n") + "\n\nIn “\(folder.path)”. On the other Mac, use File ▸ Import Analysis… in Earmark.",
                actionTitle: "Show in Finder"
            ) {
                NSWorkspace.shared.activateFileViewerSelecting(written.map(\.url))
            }
        }
    }

    /// Imports Earmark analysis files and Phase 0's music_analysis.json. An import only fills
    /// gaps: nothing already here is overwritten.
    func chooseImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = true
        panel.prompt = "Import"
        panel.message = "Choose Earmark analysis files, or music_analysis.json from a Phase 0 music report."
        guard panel.runModal() == .OK, !panel.urls.isEmpty, let db = database else { return }
        let urls = panel.urls
        Task {
            defer { activity = nil }
            var report = AnalysisImportReport()
            var imported = 0
            for url in urls {
                activity = "Importing “\(url.lastPathComponent)”…"
                do {
                    let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
                    if AnalysisFile.formatOf(data) == AnalysisFile.formatName {
                        report = report + (try await Task.detached(priority: .userInitiated) {
                            try db.importAnalysis(try AnalysisFile.read(data))
                        }.value)
                        imported += 1
                    } else {
                        // Phase 0's music_analysis.json (its own matching, and the offer to add the folder).
                        let entries = try Phase0MusicImport.read(data)
                        show(.music)
                        await applyPhase0(entries, offerFolder: true)
                    }
                } catch {
                    show(error, title: "Couldn't import “\(url.lastPathComponent)”")
                }
            }
            guard imported > 0 else { return }
            // What's done now is read again, so the background analysis doesn't redo it.
            analysis.reloadStatus()
            await reload()
            alert = AppAlert(title: Self.importTitle(report, files: imported), message: Self.importMessage(report))
        }
    }

    static func importTitle(_ r: AnalysisImportReport, files: Int) -> String {
        let added = r.facts + r.embeddings + r.folderCategories + r.soundCategories + r.songAnalyses + r.corrections
        return added == 0 ? "Nothing new to import" : "Imported the analysis from \(files == 1 ? "1 file" : "\(files) files")"
    }

    static func importMessage(_ r: AnalysisImportReport) -> String {
        func n(_ x: Int) -> String { x.formatted() }
        var lines: [String] = []
        if r.sounds > 0 {
            var added = [r.facts > 0 ? "loudness for \(n(r.facts))" : nil,
                         r.embeddings > 0 ? "\(n(r.embeddings)) embeddings" : nil,
                         r.folderCategories > 0 ? "\(n(r.folderCategories)) folder categories" : nil,
                         r.soundCategories > 0 ? "your categories for \(n(r.soundCategories)) sounds" : nil].compactMap { $0 }
            if added.isEmpty { added = ["nothing new"] }
            lines.append("Sounds: \(n(r.soundsMatched)) of \(n(r.sounds)) found here; added \(added.joined(separator: ", ")).")
        }
        if r.songs > 0 {
            var added = [r.songAnalyses > 0 ? "tempo and key for \(n(r.songAnalyses))" : nil,
                         r.corrections > 0 ? "\(n(r.corrections)) of your corrections" : nil].compactMap { $0 }
            if added.isEmpty { added = ["nothing new"] }
            lines.append("Songs: \(n(r.songsMatched)) of \(n(r.songs)) found here; added \(added.joined(separator: ", ")).")
        }
        let missing = (r.sounds - r.soundsMatched) + (r.songs - r.songsMatched)
        if missing > 0 {
            lines.append("\(n(missing)) aren't in your libraries here, or have changed since; Earmark analyses those itself.")
        }
        lines.append("What Earmark already had, and your own choices and corrections, were kept.")
        return lines.joined(separator: "\n\n")
    }
}

/// File ▸ Export Analysis…: which libraries, and whether to include the embeddings.
struct ExportAnalysisSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("exportEmbeddings") private var includeEmbeddings = true
    @State private var chosen: Set<Int64>

    init(request: ExportRequest) { _chosen = State(initialValue: request.libraryIds) }

    var body: some View {
        let libraries = model.soundLibraries + model.musicLibraries
        let sounds = model.soundLibraries.filter { chosen.contains($0.id ?? -1) }
            .reduce(0) { $0 + (model.soundIndex.libraryCounts[$1.id ?? -1] ?? 0) }
        VStack(alignment: .leading, spacing: 14) {
            Text("Export Analysis").font(.title2.weight(.semibold))
            Text("One file per library, to import into Earmark on another Mac. Files are matched by their content there, "
                 + "so another drive name or folder layout is fine. Your libraries aren't touched.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(libraries) { lib in
                    Toggle(isOn: Binding(get: { chosen.contains(lib.id ?? -1) },
                                         set: { on in if let id = lib.id { if on { chosen.insert(id) } else { chosen.remove(id) } } })) {
                        HStack(spacing: 6) {
                            Image(systemName: lib.kind == .sounds ? "square.grid.2x2" : "music.note.list").foregroundStyle(.secondary)
                            Text(lib.name)
                            Text(count(lib)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Toggle("Include sound embeddings", isOn: $includeEmbeddings)
                    .disabled(sounds == 0)
                Text(sounds == 0 ? "For sound libraries only."
                     : "About \(ByteCountFormatter.string(fromByteCount: Int64(sounds) * 8_500, countStyle: .file)) for "
                       + "\(sounds.formatted()) sounds. They're the slow part to redo: without them, the other Mac works them out again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") {
                    let ids = chosen, embeddings = includeEmbeddings && sounds > 0
                    dismiss()
                    // After the sheet has gone: the folder panel can't open over it.
                    DispatchQueue.main.async { model.export(libraryIds: ids, includeEmbeddings: embeddings) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func count(_ lib: Library) -> String {
        let id = lib.id ?? -1
        return lib.kind == .sounds
            ? "\((model.soundIndex.libraryCounts[id] ?? 0).formatted()) sounds"
            : "\((model.songIndex.libraryCounts[id] ?? 0).formatted()) songs"
    }
}
