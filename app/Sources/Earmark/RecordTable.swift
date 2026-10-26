import AppKit
import SwiftUI

/// One column of a `RecordTable`.
struct RecordColumn<Record> {
    /// Also the key its width, order and visibility are saved under.
    let id: String
    let title: String
    var minWidth: CGFloat = 40
    var width: CGFloat = 160
    var maxWidth: CGFloat = 10_000
    /// The column's sort, ascending; nil when it doesn't sort.
    var sort: KeyPathComparator<Record>?
    /// Monospaced digits, for numbers that line up.
    var digits = false
    var secondary = false
    /// Offered in the header's menu; the others are always shown, or follow `hiddenColumns`.
    var canHide = true
    /// Typing a name selects the row whose text in this column starts with it.
    var typeSelect = false
    /// The playing row shows a speaker before its text here.
    var marksPlaying = false
    let text: (Record) -> String
}

/// An entry of a `RecordTable`'s context menu.
enum RecordMenuItem {
    case action(String, enabled: Bool = true, () -> Void)
    case divider
}

/// A big list drawn by AppKit's own table. SwiftUI's `Table` goes through every row on each
/// change: clearing a search inserted 28k rows one by one (1–2 s, AppKit measuring each row),
/// and even with fixed row heights SwiftUI's own pass took ~0.4 s. This reloads only the rows
/// on screen, with plain text cells.
struct RecordTable<Record: Identifiable>: NSViewRepresentable {
    var rows: [Record]
    /// Changes whenever `rows` does (the browser's refresh count): the table reloads then.
    var rowsVersion: Int
    /// What the list shows (scope, search, sort, filters). When a reload comes with a new one,
    /// the list scrolls to the selection, or to the top; other reloads keep the scroll.
    var filter: AnyHashable
    var columns: [RecordColumn<Record>]
    /// Columns hidden by state (Match outside Find Similar Sounds).
    var hiddenColumns: Set<String> = []
    @Binding var selection: Set<Record.ID>
    @Binding var sortOrder: [KeyPathComparator<Record>]
    /// False while the other section is shown: both stay built, the hidden one hidden in AppKit.
    var shown: Bool
    var autosaveName: String
    var accessibilityLabel: String
    var url: (Record) -> URL
    var menu: (Set<Record.ID>) -> [RecordMenuItem]
    /// Double-click, Return and Space.
    var primaryAction: (Set<Record.ID>) -> Void
    /// The row playing or paused, marked with a speaker (blue playing, grey paused).
    var playing: Record.ID?
    var playingPaused = false
    /// Bumped to scroll the list to the selection (Show, in the detail pane's Now Playing).
    var revealRequest = 0
    /// Faded out during a section switch (Core Animation, so it stays smooth while the app works).
    var faded = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = KeyTableView()
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.allowsTypeSelect = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.usesAutomaticRowHeights = false
        table.rowHeight = 24
        table.setAccessibilityLabel(accessibilityLabel)
        for spec in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id))
            column.title = spec.title
            column.minWidth = spec.minWidth
            column.maxWidth = spec.maxWidth
            column.width = spec.width
            if spec.sort != nil { column.sortDescriptorPrototype = NSSortDescriptor(key: spec.id, ascending: true) }
            table.addTableColumn(column)
        }
        // After the columns: restores the widths, order and hidden columns saved last time.
        table.autosaveName = autosaveName
        table.autosaveTableColumns = true

        let coordinator = context.coordinator
        coordinator.table = table
        table.dataSource = coordinator
        table.delegate = coordinator
        table.target = coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked)
        table.onPrimaryKey = { [weak coordinator] in coordinator?.primary() }
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        let rowMenu = NSMenu()
        rowMenu.autoenablesItems = false
        rowMenu.delegate = coordinator
        table.menu = rowMenu
        let headerMenu = NSMenu()
        headerMenu.delegate = coordinator
        table.headerView?.menu = headerMenu
        coordinator.headerMenu = headerMenu

        let scroll = NSScrollView()
        scroll.documentView = table
        // The columns share the width (uniform autoresizing), so no sideways scrolling.
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let table = scroll.documentView as? KeyTableView else { return }
        coordinator.specs = Dictionary(columns.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var columnsChanged = false
        for column in table.tableColumns {
            guard let spec = coordinator.specs[column.identifier.rawValue], !spec.canHide else { continue }
            let hide = hiddenColumns.contains(spec.id)
            if column.isHidden != hide { column.isHidden = hide; columnsChanged = true }
        }
        // The columns share the width again, rather than running past it.
        if columnsChanged { table.sizeToFit() }
        coordinator.showSort(sortOrder)
        if rowsVersion != coordinator.version {
            coordinator.reload(rows, version: rowsVersion, filter: filter, selection: selection)
        } else if coordinator.selectedIDs != selection {
            coordinator.select(selection)
        }
        coordinator.showPlaying(playing, paused: playingPaused)
        if revealRequest != coordinator.revealed {
            coordinator.revealed = revealRequest
            if let row = table.selectedRowIndexes.first { table.scrollRowToVisible(row) }
        }
        table.isShownSection = shown
        if shown {
            if scroll.isHidden {
                scroll.alphaValue = faded ? 0 : 1
                scroll.isHidden = false
            }
            if coordinator.faded != faded {
                coordinator.faded = faded
                SectionViews.fade(scroll, to: faded ? 0 : 1, animated: true)
            }
            // Once both sections have updated.
            if !coordinator.wasShown { DispatchQueue.main.async { table.takeKeyboardIfFree() } }
        } else if !scroll.isHidden {
            // Not during SwiftUI's update: hiding the list with the keyboard there made AppKit
            // look for the next key view, and SwiftUI, asked from inside its own update, never
            // answered (the app hung). The shown list has usually taken the keyboard by then.
            DispatchQueue.main.async {
                guard !table.isShownSection else { return }
                if let window = table.window, window.firstResponder === table { window.makeFirstResponder(nil) }
                scroll.isHidden = true
            }
        }
        coordinator.wasShown = shown
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: RecordTable
        var specs: [String: RecordColumn<Record>] = [:]
        weak var table: NSTableView?
        weak var headerMenu: NSMenu?
        var wasShown = false
        var faded = false
        var revealed = 0
        private(set) var version = Int.min
        private var rows: [Record] = []
        /// Row of each ID, made when a selection needs it.
        private var positions: [Record.ID: Int]?
        private var reloadedFilter: AnyHashable?
        private var playingID: Record.ID?
        private var playingPaused = false
        /// Set while the table is changed from the bindings, so it doesn't write them back.
        private var updating = false

        init(_ parent: RecordTable) { self.parent = parent }

        var selectedIDs: Set<Record.ID> {
            guard let table else { return [] }
            return Set(table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0].id : nil })
        }

        func reload(_ rows: [Record], version: Int, filter: AnyHashable, selection: Set<Record.ID>) {
            guard let table else { return }
            self.rows = rows
            self.version = version
            positions = nil
            updating = true
            table.reloadData()
            updating = false
            select(selection)
            if filter != reloadedFilter {
                reloadedFilter = filter
                if let first = table.selectedRowIndexes.first { table.scrollRowToVisible(first) }
                else if !rows.isEmpty { table.scrollRowToVisible(0) }
            }
        }

        func select(_ ids: Set<Record.ID>) {
            guard let table else { return }
            let indexes = IndexSet(ids.compactMap(row(of:)))
            guard indexes != table.selectedRowIndexes else { return }
            updating = true
            table.selectRowIndexes(indexes, byExtendingSelection: false)
            updating = false
        }

        private func row(of id: Record.ID) -> Int? {
            if positions == nil {
                positions = Dictionary(rows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
            }
            return positions?[id]
        }

        /// Redraws the speaker on the rows that gain or lose it.
        func showPlaying(_ id: Record.ID?, paused: Bool) {
            guard let table, id != playingID || paused != playingPaused else { return }
            let before = playingID
            playingID = id
            playingPaused = paused
            let changed = IndexSet([before, id].compactMap { $0 }.compactMap(row(of:)))
            let columns = IndexSet(table.tableColumns.indices.filter {
                specs[table.tableColumns[$0].identifier.rawValue]?.marksPlaying == true
            })
            if !changed.isEmpty, !columns.isEmpty { table.reloadData(forRowIndexes: changed, columnIndexes: columns) }
        }

        func showSort(_ order: [KeyPathComparator<Record>]) {
            guard let table else { return }
            // Already shown, maybe on another column with the same sort (Key and Camelot).
            if comparators(table.sortDescriptors) == order { return }
            let descriptors = order.compactMap { comparator -> NSSortDescriptor? in
                guard let spec = parent.columns.first(where: { $0.sort?.keyPath == comparator.keyPath }) else { return nil }
                return NSSortDescriptor(key: spec.id, ascending: comparator.order == .forward)
            }
            guard descriptors != table.sortDescriptors else { return }
            updating = true
            table.sortDescriptors = descriptors
            updating = false
        }

        func primary() {
            let ids = selectedIDs
            if !ids.isEmpty { parent.primaryAction(ids) }
        }

        @objc func doubleClicked() {
            guard let table, table.clickedRow >= 0 else { return }
            primary()
        }

        // MARK: data source and delegate

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, row < rows.count, let spec = specs[tableColumn.identifier.rawValue] else { return nil }
            let cell = tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? TextCell
                ?? TextCell(identifier: tableColumn.identifier, marks: spec.marksPlaying)
            cell.show(spec.text(rows[row]), digits: spec.digits, secondary: spec.secondary)
            if spec.marksPlaying {
                cell.showMark(playingID != nil && rows[row].id == playingID ? (playingPaused ? .paused : .playing) : nil)
            }
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating else { return }
            let ids = selectedIDs
            if ids != parent.selection { parent.selection = ids }
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !updating else { return }
            let order = comparators(tableView.sortDescriptors)
            if !order.isEmpty { parent.sortOrder = order }
        }

        private func comparators(_ descriptors: [NSSortDescriptor]) -> [KeyPathComparator<Record>] {
            descriptors.compactMap { descriptor in
                guard let key = descriptor.key, var comparator = specs[key]?.sort else { return nil }
                comparator.order = descriptor.ascending ? .forward : .reverse
                return comparator
            }
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            row < rows.count ? parent.url(rows[row]) as NSURL : nil
        }

        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            guard let tableColumn, row < rows.count, let spec = specs[tableColumn.identifier.rawValue], spec.typeSelect else { return nil }
            return spec.text(rows[row])
        }

        // MARK: menus

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table else { return }
            if menu === headerMenu {
                for column in table.tableColumns {
                    guard let spec = specs[column.identifier.rawValue], spec.canHide else { continue }
                    let item = ClosureMenuItem(spec.title) { [weak table] in
                        column.isHidden.toggle()
                        table?.sizeToFit()
                    }
                    item.state = column.isHidden ? .off : .on
                    menu.addItem(item)
                }
                return
            }
            // The clicked row's menu acts on the selection if the row is in it, else on that row.
            let row = table.clickedRow
            guard row >= 0, row < rows.count else { return }
            let ids = table.selectedRowIndexes.contains(row) ? selectedIDs : [rows[row].id]
            for entry in parent.menu(ids) {
                switch entry {
                case .divider:
                    menu.addItem(.separator())
                case .action(let title, let enabled, let action):
                    let item = ClosureMenuItem(title, action: action)
                    item.isEnabled = enabled
                    menu.addItem(item)
                }
            }
        }
    }
}

/// Takes Return and Space for the list's primary action (play), and the keyboard when it's
/// shown and nothing else in the window has it.
final class KeyTableView: NSTableView {
    var onPrimaryKey: () -> Void = {}
    /// False once the other section is shown (the list is hidden a moment later).
    var isShownSection = true
    private var wantsKeyboard = false

    /// Every list, to find the shown one.
    private static let all = NSHashTable<KeyTableView>.weakObjects()

    override init(frame: NSRect) {
        super.init(frame: frame)
        Self.all.add(self)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func keyDown(with event: NSEvent) {
        // A key pressed just after a switch, before the shown list took the keyboard.
        if !isShownSection, let window,
           let shown = Self.all.allObjects.first(where: { $0 !== self && $0.window === window && $0.isShownSection }) {
            window.makeFirstResponder(shown)
            shown.keyDown(with: event)
            return
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        if modifiers.isEmpty, ["\r", "\u{3}", " "].contains(event.charactersIgnoringModifiers ?? "") {
            onPrimaryKey()
        } else {
            super.keyDown(with: event)
        }
    }

    /// The keyboard comes here unless a shown view other than the window has it (the search
    /// field, the sidebar): at launch, and after a switch from the section that had it.
    func takeKeyboardIfFree() {
        guard let window else { wantsKeyboard = true; return }
        wantsKeyboard = false
        guard isShownSection, !isHiddenOrHasHiddenAncestor else { return }
        let current = window.firstResponder
        let free = current == nil || current === window
            || (current as? KeyTableView)?.isShownSection == false
            || (current as? NSView)?.isHiddenOrHasHiddenAncestor == true
        if free { window.makeFirstResponder(self) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if wantsKeyboard, window != nil { DispatchQueue.main.async { self.takeKeyboardIfFree() } }
    }
}

/// A row's text in one column, after the playing speaker in the column that shows it.
final class TextCell: NSTableCellView {
    enum Mark { case playing, paused }

    private static let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    private static let digitsFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    private var markView: NSImageView?
    private var mark: Mark?

    /// `marks`: room for the speaker before the text, on every row so the names line up.
    init(identifier: NSUserInterfaceItemIdentifier, marks: Bool = false) {
        super.init(frame: .zero)
        self.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.allowsExpansionToolTips = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        textField = label
        var leading = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2)
        if marks {
            let speaker = NSImageView()
            speaker.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil)
            speaker.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
            speaker.translatesAutoresizingMaskIntoConstraints = false
            speaker.isHidden = true
            addSubview(speaker)
            markView = speaker
            NSLayoutConstraint.activate([
                speaker.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                speaker.widthAnchor.constraint(equalToConstant: 18),
                speaker.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            leading = label.leadingAnchor.constraint(equalTo: speaker.trailingAnchor, constant: 3)
        }
        NSLayoutConstraint.activate([
            leading,
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ text: String, digits: Bool, secondary: Bool) {
        guard let label = textField else { return }
        label.stringValue = text
        label.font = digits ? Self.digitsFont : Self.font
        label.textColor = secondary ? .secondaryLabelColor : .labelColor
    }

    func showMark(_ mark: Mark?) {
        self.mark = mark
        markView?.isHidden = mark == nil
        markView?.setAccessibilityLabel(mark == .paused ? "Paused" : "Playing")
        tintMark()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { tintMark() }
    }

    /// Blue while playing, grey while paused; white on the selection's colour.
    private func tintMark() {
        guard let markView, let mark else { return }
        markView.contentTintColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor
            : mark == .playing ? .systemBlue : .secondaryLabelColor
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, action run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(runAction), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func runAction() { run() }
}
