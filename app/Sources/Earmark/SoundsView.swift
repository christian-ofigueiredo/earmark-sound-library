import AppKit
import EarmarkCore
import SwiftUI

enum SoundScope: Hashable, Sendable {
    case all
    case library(Int64)
    case category(String)
    case catID(String)
    case uncategorised
}

/// What the sound list shows: scope, search, sort and selection.
@MainActor @Observable
final class SoundBrowser {
    var scope: SoundScope? = .all
    var search = ""
    var selection: Set<SoundRecord.ID> = []
    var sortOrder = [KeyPathComparator(\SoundRecord.displayName)]
    private(set) var visible: [SoundRecord] = []

    struct FilterKey: Hashable {
        var scope: SoundScope?
        var search: String
        var sortOrder: [KeyPathComparator<SoundRecord>]
        var version: Int
    }

    func filterKey(version: Int) -> FilterKey {
        FilterKey(scope: scope, search: search, sortOrder: sortOrder, version: version)
    }

    func refresh(from model: AppModel) {
        let terms = search.lowercased().split(whereSeparator: \.isWhitespace)
        let scope = self.scope ?? .all
        let sounds = model.sounds, haystacks = model.soundIndex.haystacks
        visible = sounds.indices.filter { i in
            let s = sounds[i]
            switch scope {
            case .all: break
            case .library(let id): if s.libraryId != id { return false }
            case .category(let c): if s.category != c { return false }
            case .catID(let c): if s.catID != c { return false }
            case .uncategorised: if s.catID != nil { return false }
            }
            return terms.allSatisfy { haystacks[i].contains($0) }
        }
        .map { sounds[$0] }
        .sorted(using: sortOrder)
    }
}

struct SoundsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("autoplaySounds") private var autoplay = false

    var body: some View {
        @Bindable var browser = model.soundBrowser
        NavigationSplitView {
            SoundSidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 380)
        } content: {
            SoundTable()
                .navigationSplitViewColumnWidth(min: 420, ideal: 680)
                .searchable(text: $browser.search, placement: .toolbar, prompt: "Name, description, keywords")
        } detail: {
            SoundDetailPane()
                .navigationSplitViewColumnWidth(min: 300, ideal: 380)
        }
        .toolbar {
            ToolbarItem {
                Toggle(isOn: $autoplay) {
                    Label("Auto-play", systemImage: autoplay ? "play.circle.fill" : "play.circle")
                }
                .help("Play sounds as you select them")
            }
        }
        .task(id: browser.filterKey(version: model.version)) { model.soundBrowser.refresh(from: model) }
        .onChange(of: browser.selection) { _, ids in
            guard autoplay, ids.count == 1, let s = model.sound(id: ids.first ?? nil),
                  model.isOnline(libraryId: s.libraryId) else { return }
            model.player.play(s.url)
        }
    }
}

struct SoundSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var browser = model.soundBrowser
        List(selection: $browser.scope) {
            Label("All Sounds", systemImage: "square.grid.2x2")
                .badge(model.sounds.count)
                .tag(SoundScope.all)
            Section("Libraries") {
                ForEach(model.soundLibraries) { lib in
                    LibraryRow(library: lib, count: model.soundIndex.libraryCounts[lib.id ?? -1] ?? 0,
                               scanning: model.isScanning(lib))
                        .tag(SoundScope.library(lib.id ?? -1))
                        .contextMenu { LibraryMenu(library: lib) }
                }
                Button {
                    model.chooseLibrary(.sounds)
                } label: {
                    Label("Add Library…", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            if !model.sounds.isEmpty {
                Section("Categories") {
                    OutlineGroup(model.soundIndex.categories, children: \.children) { node in
                        Text(node.title).badge(node.count).tag(node.id)
                    }
                    Label("Not Categorised Yet", systemImage: "questionmark.folder")
                        .badge(model.soundIndex.uncategorised)
                        .tag(SoundScope.uncategorised)
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct SoundTable: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var browser = model.soundBrowser
        Table(of: SoundRecord.self, selection: $browser.selection, sortOrder: $browser.sortOrder) {
            TableColumn("Name", value: \.displayName)
            TableColumn("Category", value: \.categoryText)
            TableColumn("Length", value: \.durationValue) { s in
                Text(formatLength(s.duration)).monospacedDigit()
            }
            .width(min: 50, ideal: 64, max: 90)
            TableColumn("Folder", value: \.folder)
            TableColumn("Format", value: \.formatText)
                .width(min: 80, ideal: 150)
        } rows: {
            ForEach(browser.visible) { s in
                TableRow(s).itemProvider { fileDragItem(s.url) }
            }
        }
        .contextMenu(forSelectionType: SoundRecord.ID.self) { ids in
            let picked = ids.compactMap { model.sound(id: $0) }
            if picked.count == 1, let s = picked.first {
                Button("Play") { model.player.play(s.url) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([s.url]) }
            } else if !picked.isEmpty {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(picked.map(\.url)) }
            }
            if !picked.isEmpty {
                Button(picked.count == 1 ? "Copy Path" : "Copy Paths") {
                    copyToPasteboard(picked.map(\.path).joined(separator: "\n"))
                }
            }
        } primaryAction: { ids in
            if let s = model.sound(id: ids.first ?? nil) { model.player.toggle(s.url) }
        }
        .onKeyPress(.space) {
            guard let s = model.sound(id: browser.selection.first ?? nil) else { return .ignored }
            model.player.toggle(s.url)
            return .handled
        }
        .overlay {
            if model.soundLibraries.isEmpty {
                ContentUnavailableView {
                    Label("No Sound Libraries Yet", systemImage: "waveform")
                } description: {
                    Text("Add the folders where your sound effects live. Earmark reads their metadata and never changes them.")
                } actions: {
                    Button("Add Sound Library…") { model.chooseLibrary(.sounds) }
                }
            } else if browser.visible.isEmpty && !browser.search.isEmpty {
                ContentUnavailableView.search(text: browser.search)
            } else if browser.visible.isEmpty && model.scanning.isEmpty {
                ContentUnavailableView("No Sounds Here", systemImage: "tray")
            }
        }
    }
}

struct SoundDetailPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let ids = model.soundBrowser.selection
        if ids.count == 1, let sound = model.sound(id: ids.first ?? nil) {
            SoundDetail(sound: sound).id(sound.id)
        } else if ids.count > 1 {
            ContentUnavailableView("\(ids.count) Sounds Selected", systemImage: "square.stack")
        } else {
            ContentUnavailableView("No Sound Selected", systemImage: "waveform",
                                   description: Text("Select a sound to hear it. Drag it into DaVinci Resolve to use it."))
        }
    }
}

struct SoundDetail: View {
    @Environment(AppModel.self) private var model
    let sound: SoundRecord

    var body: some View {
        let online = model.isOnline(libraryId: sound.libraryId)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(sound.displayName)
                        .font(.title2.weight(.semibold))
                        .textSelection(.enabled)
                    if let label = sound.ucsLabel {
                        HStack(spacing: 6) {
                            Text(label.capitalized).font(.callout.weight(.medium))
                            if let catID = sound.catID {
                                Text(catID).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                        if let source = sound.categorySource {
                            Text("Category from \(source)").font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Not categorised yet").font(.callout).foregroundStyle(.secondary)
                    }
                }
                if online {
                    PlayerPanel(url: sound.url, knownDuration: sound.duration)
                    FileChip(url: sound.url)
                } else {
                    OfflineNotice(library: model.library(id: sound.libraryId))
                }
                InfoGrid([
                    ("Description", sound.details),
                    ("Keywords", sound.keywords),
                    ("Library", sound.vendorLibrary),
                    ("Manufacturer", sound.manufacturer),
                    ("Designer", sound.designer),
                    ("Format", sound.formatText),
                    ("Length", formatLength(sound.duration)),
                    ("Folder", sound.folder),
                    ("File", sound.fileName),
                ])
                FileActions(url: sound.url, online: online)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
