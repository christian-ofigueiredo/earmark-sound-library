import AppKit
import EarmarkCore
import SwiftUI

/// Map Folders to Categories: the user picks a UCS category for folders whose sounds have
/// none, helped by suggestions from the folder's name and from what its sounds sound like.
/// Nothing is saved until the user ticks a folder and saves; files are never changed.
@MainActor @Observable
final class FolderMapper {
    struct Key: Hashable, Sendable, Identifiable {
        var libraryId: Int64
        var folder: String
        var id: Self { self }
    }

    /// A folder with sounds that have no category.
    struct Row: Identifiable, Sendable {
        var id: Key
        /// Its sounds in the list (not hidden format twins) that have no category.
        var soundIds: [Int64]
    }

    /// A folder the user has given a category.
    struct MappedRow: Identifiable {
        var id: Key { Key(libraryId: rule.libraryId, folder: rule.folder) }
        var rule: FolderRule
        /// Sounds that take their category from this rule.
        var soundIds: [Int64]
    }

    enum Tab: Hashable { case toMap, mapped }

    var tab = Tab.toMap
    var search = ""
    var selection: Set<Key> = []
    var mappedSelection: Set<Key> = []
    /// Folders ticked to be saved.
    var ticked: Set<Key> = []
    /// The folder whose category is being chosen from the whole UCS list.
    var choosing: Key?

    private(set) var rows: [Row] = []
    private(set) var mapped: [MappedRow] = []
    private(set) var suggestions: [Key: [FolderSuggester.Option]] = [:]
    /// The folder a sample is playing from.
    private(set) var playing: Key?
    /// Categories the user picked; otherwise the best suggestion is used.
    private var picked: [Key: String] = [:]
    private var lastSample: [Key: Int64] = [:]
    /// The folder `focus` selected, so opening the window on it doesn't start playing it.
    private var focused: Key?
    private var builtFor = -1
    @ObservationIgnored private var suggesting: Task<Void, Never>?

    var visibleRows: [Row] { filter(rows, \.id.folder) }
    var visibleMapped: [MappedRow] { filter(mapped, \.rule.folder) }

    private func filter<T>(_ items: [T], _ folder: KeyPath<T, String>) -> [T] {
        let terms = search.lowercased().split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return items }
        return items.filter { item in
            let f = item[keyPath: folder].lowercased()
            return terms.allSatisfy { f.contains($0) }
        }
    }

    func catID(for key: Key) -> String? { picked[key] ?? suggestions[key]?.first?.entry.catID }

    func isMapped(_ key: Key) -> Bool { mapped.contains { $0.id == key } }

    /// Folders still waiting for suggestions.
    var pending: Int { rows.count { suggestions[$0.id] == nil } }

    var tickedSoundCount: Int { rows.filter { ticked.contains($0.id) }.reduce(0) { $0 + $1.soundIds.count } }

    /// Picking a category for a folder also ticks it.
    func pick(_ catID: String, for key: Key) {
        picked[key] = catID
        ticked.insert(key)
    }

    /// Space and the context menu: tick the selected folders, or untick them if all are ticked.
    func toggleTicks(_ keys: Set<Key>) {
        if keys.isSubset(of: ticked) { ticked.subtract(keys) } else { ticked.formUnion(keys) }
    }

    /// Shows one folder (from a sound's detail pane).
    func focus(_ key: Key) {
        tab = isMapped(key) ? .mapped : .toMap
        search = key.folder
        focused = key
        if tab == .toMap { selection = [key] } else { mappedSelection = [key] }
    }

    /// Selecting one folder plays a sound from it (to review with the arrow keys).
    func selectionChanged(model: AppModel) {
        defer { focused = nil }
        guard selection.count == 1, let key = selection.first, key != focused else { return }
        playSample(key, model: model)
    }

    func save(_ model: AppModel) {
        let rules = ticked.compactMap { key in
            catID(for: key).map { FolderRule(libraryId: key.libraryId, folder: key.folder, catID: $0) }
        }
        model.saveFolderRules(rules)
        ticked.removeAll()
    }

    /// Plays a different sound from the folder each time, or stops if it is playing.
    func playSample(_ key: Key, model: AppModel) {
        if playing == key, model.player.isPlaying {
            model.player.stop()
            return
        }
        let ids = rows.first { $0.id == key }?.soundIds ?? mapped.first { $0.id == key }?.soundIds ?? []
        guard !ids.isEmpty, model.isOnline(libraryId: key.libraryId) else { return }
        var id = ids.randomElement()!
        while ids.count > 1, id == lastSample[key] { id = ids.randomElement()! }
        guard let sound = model.sound(id: id) else { return }
        lastSample[key] = id
        playing = key
        model.player.play(sound.url)
    }

    func isPlaying(_ key: Key, model: AppModel) -> Bool { playing == key && model.player.isPlaying }

    // MARK: building the lists

    func refresh(from model: AppModel) {
        guard builtFor != model.version else { return }
        builtFor = model.version
        let hidden = model.soundIndex.twins.hidden
        var open: [Key: [Int64]] = [:]
        var ruled: [Key: [Int64]] = [:]
        let rules = Set(model.folderRules.map { Key(libraryId: $0.libraryId, folder: $0.folder) })
        for s in model.sounds {
            guard let id = s.id, !hidden.contains(id) else { continue }
            if s.catID == nil {
                open[Key(libraryId: s.libraryId, folder: s.folder), default: []].append(id)
            } else if s.categorySource == FolderRules.source {
                // The nearest rule at or above the sound's folder is the one that applied.
                var folder = s.folder
                while !rules.contains(Key(libraryId: s.libraryId, folder: folder)), let slash = folder.lastIndex(of: "/") {
                    folder = String(folder[..<slash])
                }
                ruled[Key(libraryId: s.libraryId, folder: folder), default: []].append(id)
            }
        }
        rows = open.map { Row(id: $0.key, soundIds: $0.value) }.sorted {
            $0.soundIds.count != $1.soundIds.count ? $0.soundIds.count > $1.soundIds.count : $0.id.folder < $1.id.folder
        }
        mapped = model.folderRules.map { rule in
            MappedRow(rule: rule, soundIds: ruled[Key(libraryId: rule.libraryId, folder: rule.folder)] ?? [])
        }.sorted { $0.rule.folder.localizedStandardCompare($1.rule.folder) == .orderedAscending }
        ticked.formIntersection(open.keys)
        selection.formIntersection(open.keys)
        mappedSelection.formIntersection(rules)
        startSuggesting(model)
    }

    /// Suggestions for folders that don't have them yet (a fraction of a second each).
    private func startSuggesting(_ model: AppModel) {
        suggesting?.cancel()
        guard pending > 0 else { return }
        // Only categories that came with the files teach the suggestions, not the user's rules.
        var labels: [Int64: String] = [:]
        for s in model.sounds where s.categorySource != FolderRules.source {
            if let id = s.id, let catID = s.catID { labels[id] = catID }
        }
        let known = labels
        suggesting = Task { [weak self] in
            let index = try? await model.similarityIndex()
            while !Task.isCancelled, let row = self?.nextToSuggest() {
                let options = await Task.detached(priority: .userInitiated) {
                    FolderSuggester.suggest(folder: row.id.folder, soundIds: row.soundIds, index: index, labels: known)
                }.value
                guard let self, !Task.isCancelled else { return }
                self.suggestions[row.id] = options
            }
        }
    }

    /// The folders on screen first (a search, or a folder opened from a sound), then the largest.
    private func nextToSuggest() -> Row? {
        visibleRows.first { suggestions[$0.id] == nil } ?? rows.first { suggestions[$0.id] == nil }
    }

    /// Stops suggesting while the window is closed; it carries on when it opens again.
    func pause() {
        suggesting?.cancel()
        suggesting = nil
        builtFor = -1
    }

    // MARK: describing suggestions

    static func title(_ catID: String?) -> String {
        catID.flatMap { UCSCatalog.shared.entry(catID: $0)?.label.capitalized } ?? "Choose…"
    }

    /// Why a category is suggested: words of the folder name, and how many of the most
    /// similar sounds (with a category from their files) are in it.
    static func reason(_ option: FolderSuggester.Option) -> String {
        var parts: [String] = []
        if !option.words.isEmpty { parts.append("name “\(option.words.joined(separator: " "))”") }
        if option.soundShare >= 0.1 { parts.append("\(Int((option.soundShare * 100).rounded()))% of similar sounds") }
        return parts.isEmpty ? "similar sounds are in this category" : parts.joined(separator: " · ")
    }

    /// No word of the name and few similar sounds agree: worth listening before saving.
    static func isWeak(_ option: FolderSuggester.Option) -> Bool { option.words.isEmpty && option.soundShare < 0.3 }
}

struct FolderMapView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var mapper = model.folderMapper
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Show", selection: $mapper.tab) {
                    Text("Not Categorised (\(mapper.rows.count))").tag(FolderMapper.Tab.toMap)
                    Text("Your Folder Categories (\(mapper.mapped.count))").tag(FolderMapper.Tab.mapped)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                if mapper.pending > 0 {
                    ProgressView().controlSize(.small)
                    Text("Suggesting categories: \(mapper.pending) folders to go")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            switch mapper.tab {
            case .toMap: FoldersToMapTable()
            case .mapped: MappedFoldersTable()
            }
            Divider()
            HStack(spacing: 12) {
                Text("Sounds without a category take their folder's. A category from the file itself always wins. Earmark keeps this in its own database; your files aren't changed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if mapper.tab == .toMap {
                    if !mapper.ticked.isEmpty {
                        Text("\(mapper.ticked.count) \(mapper.ticked.count == 1 ? "folder" : "folders"), \(mapper.tickedSoundCount.formatted()) sounds")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Button("Save Categories") { mapper.save(model) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(mapper.ticked.isEmpty)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .searchable(text: $mapper.search, placement: .toolbar, prompt: "Folder")
        .task(id: model.version) { mapper.refresh(from: model) }
        .onDisappear {
            mapper.pause()
            if mapper.playing != nil { model.player.stop() }
        }
        .sheet(item: $mapper.choosing) { key in
            UCSChooser(folder: key.folder, current: mapper.catID(for: key)) { catID in
                if mapper.isMapped(key) {
                    model.saveFolderRules([FolderRule(libraryId: key.libraryId, folder: key.folder, catID: catID)])
                } else {
                    mapper.pick(catID, for: key)
                }
            }
        }
    }
}

struct FoldersToMapTable: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var mapper = model.folderMapper
        Table(of: FolderMapper.Row.self, selection: $mapper.selection) {
            TableColumn("") { row in
                Toggle("Save", isOn: Binding(
                    get: { mapper.ticked.contains(row.id) },
                    set: { if $0 { mapper.ticked.insert(row.id) } else { mapper.ticked.remove(row.id) } }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(mapper.catID(for: row.id) == nil)
            }
            .width(22)
            TableColumn("Folder") { row in
                FolderPath(folder: row.id.folder)
            }
            .width(min: 200, ideal: 340)
            TableColumn("Sounds") { row in
                Text(row.soundIds.count.formatted()).monospacedDigit()
            }
            .width(min: 50, ideal: 56, max: 80)
            TableColumn("Category") { row in FolderCategoryMenu(model: model, key: row.id) }
                .width(min: 180, ideal: 230)
            TableColumn("Why") { row in FolderReason(model: model, key: row.id) }
                .width(min: 160, ideal: 260)
            TableColumn("") { row in SampleButton(model: model, key: row.id) }
                .width(24)
        } rows: {
            ForEach(mapper.visibleRows) { TableRow($0) }
        }
        .contextMenu(forSelectionType: FolderMapper.Key.self) { keys in
            if !keys.isEmpty {
                Button(keys.isSubset(of: mapper.ticked) ? "Untick" : "Tick") { mapper.toggleTicks(keys) }
            }
            if keys.count == 1, let key = keys.first {
                Button("Choose Category…") { mapper.choosing = key }
                Button("Play a Sound") { mapper.playSample(key, model: model) }
                FolderFinderButton(model: model, key: key)
            }
        } primaryAction: { keys in
            if keys.count == 1, let key = keys.first { mapper.playSample(key, model: model) }
        }
        .onKeyPress(.space) {
            guard !mapper.selection.isEmpty else { return .ignored }
            mapper.toggleTicks(mapper.selection)
            return .handled
        }
        .onChange(of: mapper.selection) { mapper.selectionChanged(model: model) }
        .overlay {
            if mapper.rows.isEmpty {
                ContentUnavailableView("Every Folder Has a Category", systemImage: "checkmark.circle",
                                       description: Text("All sounds have a category from their files or their folder."))
            } else if mapper.visibleRows.isEmpty {
                ContentUnavailableView.search(text: mapper.search)
            }
        }
    }
}

struct MappedFoldersTable: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var mapper = model.folderMapper
        Table(of: FolderMapper.MappedRow.self, selection: $mapper.mappedSelection) {
            TableColumn("Folder") { row in
                FolderPath(folder: row.rule.folder)
            }
            .width(min: 200, ideal: 360)
            TableColumn("Sounds") { row in
                Text(row.soundIds.count.formatted()).monospacedDigit()
            }
            .width(min: 50, ideal: 56, max: 80)
            TableColumn("Category") { row in
                HStack {
                    Text(FolderMapper.title(row.rule.catID))
                    Spacer()
                    Button("Change…") { mapper.choosing = row.id }
                        .buttonStyle(.link)
                }
            }
            .width(min: 200, ideal: 280)
            TableColumn("") { row in
                Button("Remove") { model.removeFolderRule(row.rule) }
                    .buttonStyle(.link)
                    .help("Its sounds go back to Not Categorised Yet")
            }
            .width(60)
            TableColumn("") { row in SampleButton(model: model, key: row.id) }
                .width(24)
        } rows: {
            ForEach(mapper.visibleMapped) { TableRow($0) }
        }
        .contextMenu(forSelectionType: FolderMapper.Key.self) { keys in
            if keys.count == 1, let key = keys.first, let row = mapper.mapped.first(where: { $0.id == key }) {
                Button("Change Category…") { mapper.choosing = key }
                Button("Remove") { model.removeFolderRule(row.rule) }
                Button("Play a Sound") { mapper.playSample(key, model: model) }
                FolderFinderButton(model: model, key: key)
            }
        } primaryAction: { keys in
            if keys.count == 1, let key = keys.first { mapper.playSample(key, model: model) }
        }
        .overlay {
            if mapper.mapped.isEmpty {
                ContentUnavailableView("No Folder Categories Yet", systemImage: "folder",
                                       description: Text("Folders you give a category appear here."))
            } else if mapper.visibleMapped.isEmpty {
                ContentUnavailableView.search(text: mapper.search)
            }
        }
    }
}

// The views in table cells and context menus are given the model rather than reading it from
// the environment: a table can update the cell of a row it has just removed, outside the window.

/// The suggested categories for a folder, with Other… for the whole UCS list.
struct FolderCategoryMenu: View {
    let model: AppModel
    let key: FolderMapper.Key

    var body: some View {
        let mapper = model.folderMapper
        if let options = mapper.suggestions[key] {
            let current = mapper.catID(for: key)
            Menu(FolderMapper.title(current)) {
                if let current, !options.contains(where: { $0.entry.catID == current }) {
                    Toggle(FolderMapper.title(current), isOn: .constant(true))
                }
                ForEach(options, id: \.entry.catID) { option in
                    Toggle(option.entry.label.capitalized, isOn: Binding(
                        get: { current == option.entry.catID },
                        set: { _ in mapper.pick(option.entry.catID, for: key) }
                    ))
                }
                Divider()
                Button("Other…") { mapper.choosing = key }
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Suggesting…").foregroundStyle(.tertiary)
        }
    }
}

struct FolderReason: View {
    let model: AppModel
    let key: FolderMapper.Key

    var body: some View {
        let mapper = model.folderMapper
        if let options = mapper.suggestions[key] {
            let current = mapper.catID(for: key)
            if let option = options.first(where: { $0.entry.catID == current }) {
                Text(FolderMapper.reason(option) + (FolderMapper.isWeak(option) ? " — listen first" : ""))
                    .foregroundStyle(FolderMapper.isWeak(option) ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .help("Words of the folder name that match this category, and the share of the most similar sounds "
                        + "(from other folders, with a category from their files) that are in it.")
            } else if current != nil {
                Text("Your choice").foregroundStyle(.secondary)
            } else {
                Text("No suggestion").foregroundStyle(.secondary)
            }
        }
    }
}

struct SampleButton: View {
    let model: AppModel
    let key: FolderMapper.Key

    var body: some View {
        let playing = model.folderMapper.isPlaying(key, model: model)
        Button {
            model.folderMapper.playSample(key, model: model)
        } label: {
            Image(systemName: playing ? "stop.fill" : "play.fill")
        }
        .buttonStyle(.borderless)
        .disabled(!model.isOnline(libraryId: key.libraryId))
        .help(playing ? "Stop" : "Play a sound from this folder (a different one each time)")
    }
}

/// The enclosing folders dimmed, then the folder's own name; cut from the left when narrow.
struct FolderPath: View {
    let folder: String

    var body: some View {
        let cut = folder.lastIndex(of: "/").map { folder.index(after: $0) } ?? folder.startIndex
        Text("\(Text(String(folder[..<cut])).foregroundStyle(.secondary))\(String(folder[cut...]))")
            .lineLimit(1)
            .truncationMode(.head)
            .help(folder)
    }
}

struct FolderFinderButton: View {
    let model: AppModel
    let key: FolderMapper.Key

    var body: some View {
        if let library = model.library(id: key.libraryId), library.isOnline {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([library.url.appendingPathComponent(key.folder)])
            }
        }
    }
}

/// The whole UCS list, searchable by name, CatID and synonyms.
struct UCSChooser: View {
    let folder: String
    let current: String?
    let onChoose: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var selection: String?
    @FocusState private var searchFocused: Bool

    private static let haystacks: [(entry: UCSEntry, text: String)] = UCSCatalog.shared.entries.map { e in
        (e, ([e.category, e.subcategory, e.catID] + e.synonyms).joined(separator: " ").lowercased())
    }

    private var entries: [UCSEntry] {
        let terms = search.lowercased().split(whereSeparator: \.isWhitespace)
        return Self.haystacks.filter { h in terms.allSatisfy { h.text.contains($0) } }.map(\.entry)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Category for “\(folder.split(separator: "/").last.map(String.init) ?? folder)”")
                .font(.headline)
            TextField("Search, e.g. door, rain, whoosh", text: $search)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
            ScrollViewReader { proxy in
                List(entries, id: \.catID, selection: $selection) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(e.label.capitalized)
                            Spacer()
                            Text(e.catID).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        if !e.explanation.isEmpty {
                            Text(e.explanation).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
                .contextMenu(forSelectionType: String.self) { _ in
                } primaryAction: { ids in
                    if let id = ids.first { choose(id) }
                }
                .onAppear {
                    selection = current
                    if let current { proxy.scrollTo(current, anchor: .center) }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Choose") { if let chosen { choose(chosen) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen == nil)
            }
        }
        .padding(20)
        .frame(width: 540, height: 560)
        .onAppear { searchFocused = true }
    }

    /// The selected category, if the search still shows it.
    private var chosen: String? {
        guard let selection, entries.contains(where: { $0.catID == selection }) else { return nil }
        return selection
    }

    private func choose(_ catID: String) {
        onChoose(catID)
        dismiss()
    }
}

/// Opens the Map Folders to Categories window (menus, sidebar).
struct MapFoldersButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openWindow(id: FolderMapView.windowID)
        } label: {
            Label("Map Folders to Categories…", systemImage: "folder.badge.gearshape")
        }
    }
}

extension FolderMapView {
    static let windowID = "folder-map"
}
