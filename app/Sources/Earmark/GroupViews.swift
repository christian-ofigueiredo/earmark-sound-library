import EarmarkCore
import SwiftUI

/// Naming a group: renaming one, or making one from selected sounds.
enum GroupNaming: Identifiable {
    case rename(SoundGroupRecord)
    case new(sounds: [Int64], catID: String)

    var id: String {
        switch self {
        case .rename(let g): "rename-\(g.id ?? -1)"
        case .new(let sounds, _): "new-\(sounds.hashValue)"
        }
    }
}

struct GroupNameSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let naming: GroupNaming
    @State private var name: String

    init(naming: GroupNaming) {
        self.naming = naming
        switch naming {
        case .rename(let g): _name = State(initialValue: g.title)
        case .new: _name = State(initialValue: "")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch naming {
            case .rename(let g):
                Text("Rename Group").font(.title3.weight(.semibold))
                Text(g.userName == nil ? "Earmark called it “\(g.name)”." : "Earmark called it “\(g.name)”. Leave it empty to go back to that.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .new(let sounds, _):
                Text("New Group").font(.title3.weight(.semibold))
                Text(sounds.count == 1 ? "A group of the selected sound, moved out of the group it's in."
                     : "A group of the \(sounds.count) selected sounds, moved out of the groups they're in.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Make Group" : "Rename", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isNew && name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var isNew: Bool { if case .new = naming { true } else { false } }

    private func save() {
        switch naming {
        case .rename(let g):
            model.renameGroup(g, to: name)
        case .new(let sounds, _):
            guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            model.newGroup(from: sounds, name: name.trimmingCharacters(in: .whitespaces))
        }
        dismiss()
    }
}

/// A group's menu in the sidebar.
struct GroupMenu: View {
    @Environment(AppModel.self) private var model
    let group: SoundGroupRecord

    var body: some View {
        let others = model.groups(catID: group.catID).filter { $0.id != group.id }
        Button("Rename…") { model.groupNaming = .rename(group) }
        Menu("Merge Into") {
            ForEach(others) { other in
                Button(other.title) { model.merge([group], into: other) }
            }
        }
        .disabled(others.isEmpty)
        Divider()
        Button("Regroup “\(subcategoryTitle)” Automatically…") {
            model.confirmRegroup(catID: group.catID, title: subcategoryTitle)
        }
    }

    private var subcategoryTitle: String { UCSCatalog.shared.entry(catID: group.catID)?.subcategory.capitalized ?? group.catID }
}

/// The list's row menu items for groups: move the selected sounds, or make a new group of them.
@MainActor
func groupMenuItems(for sounds: [SoundRecord], model: AppModel) -> [RecordMenuItem] {
    guard let catID = sounds.first?.catID, sounds.allSatisfy({ $0.catID == catID }) else { return [] }
    let groups = model.groups(catID: catID)
    guard !groups.isEmpty else { return [] }
    let ids = sounds.compactMap(\.id)
    let current = Set(sounds.compactMap { model.group(of: $0)?.id })
    let moves = groups.map { g in
        RecordMenuItem.action(g.title, checked: current == [g.id!]) { model.move(ids, to: g) }
    }
    return [.divider, .submenu("Move to Group", moves),
            .action("New Group from Selection…") { model.groupNaming = .new(sounds: ids, catID: catID) }]
}

/// The detail pane's line about the sound's group: its name (selects it in the sidebar) and the
/// words its files share.
struct GroupLine: View {
    @Environment(AppModel.self) private var model
    let sound: SoundRecord

    var body: some View {
        if let group = model.group(of: sound), model.groups(catID: sound.catID).count > 1 {
            HStack(spacing: 6) {
                Image(systemName: "circle.grid.2x2").foregroundStyle(.secondary).font(.caption)
                Button(group.title) { model.soundBrowser.scope = .group(group.id!) }
                    .buttonStyle(.link)
                    .font(.caption)
                    .lineLimit(1)
                    .layoutPriority(1)
                    .help("Show this group: sounds in “\(sound.subcategory?.capitalized ?? "")” that sound alike")
                if !group.keywordList.isEmpty {
                    Text(group.keywordList.map { "#\($0)" }.joined(separator: " "))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help("Words most of the group's files share: " + group.keywordList.joined(separator: ", "))
                }
                Menu {
                    ForEach(model.groups(catID: sound.catID)) { g in
                        Button { model.move([sound.id!], to: g) } label: {
                            if g.id == group.id { Label(g.title, systemImage: "checkmark") } else { Text(g.title) }
                        }
                    }
                    Divider()
                    Button("New Group…") { model.groupNaming = .new(sounds: [sound.id!], catID: sound.catID!) }
                    Button("Rename “\(group.title)”…") { model.groupNaming = .rename(group) }
                } label: {
                    Text("Move")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(.caption)
            }
        }
    }
}

/// Sounds whose category the owner is choosing (the chooser sheet).
struct CategoryChoosing: Identifiable {
    var sounds: [Int64]
    var id: [Int64] { sounds }
}

/// Change ▸ For This Sound… / For Its Folder… / back to its folder's: in the detail pane.
struct CategoryChangeMenu: View {
    @Environment(AppModel.self) private var model
    let sound: SoundRecord
    let title: String
    let mapFolder: () -> Void

    var body: some View {
        Menu {
            Button("For This Sound…") { model.categoryChoosing = CategoryChoosing(sounds: [sound.id!]) }
            // A folder's category only reaches sounds without one in their files.
            if !hasOwnCategory {
                Button("For Its Folder…", action: mapFolder)
            }
            switch sound.categorySource {
            case SoundCategories.ownerSource:
                Divider()
                Button("Remove Your Category") { model.setCategory([sound.id!], to: nil) }
            case SoundCategories.soundGuessSource:
                if let folders = model.soundChoices[sound.id ?? -1]?.replaced, let e = UCSCatalog.shared.entry(catID: folders) {
                    Divider()
                    Button("Use Its Folder's: \(e.label.capitalized)") { model.setCategory([sound.id!], to: e.catID) }
                }
            default:
                EmptyView()
            }
        } label: {
            Text(title)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// The file says its category itself (UCS file name, iXML).
    private var hasOwnCategory: Bool {
        guard let source = sound.categorySource else { return false }
        return ![FolderRules.source, FolderRules.guessSource, SoundCategories.soundGuessSource, SoundCategories.ownerSource].contains(source)
    }
}
