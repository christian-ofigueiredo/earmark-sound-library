import AppKit
import EarmarkCore
import SwiftUI

// MARK: state

/// The sound list as a map (View ▸ Sound Map, ⇧⌘M): one dot per sound, sounds that sound alike
/// close together (`SoundMap`, from the PE-AV and CLAP embeddings). The map is of the sidebar's
/// choice (all, a library, a category, Similar…); a search dims the rest instead of moving them.
@MainActor @Observable
final class SoundMapState {
    var showing = UserDefaults.standard.bool(forKey: "soundMapShowing") {
        didSet {
            UserDefaults.standard.set(showing, forKey: "soundMapShowing")
            if !showing { release() }
        }
    }
    /// Moving over dots plays each one.
    var playOnHover = UserDefaults.standard.bool(forKey: "soundMapPlayOnHover") {
        didSet { UserDefaults.standard.set(playOnHover, forKey: "soundMapPlayOnHover") }
    }
    /// A category (or subcategory) lit up from the legend; the rest dimmed.
    var highlight: String?

    struct Layout {
        var key: Int
        var ids: [Int64]
        var points: [SIMD2<Float>]
        var row: [Int64: Int]
    }
    private(set) var layout: Layout?
    /// 0…1 while a layout is being worked out.
    private(set) var progress: Double?
    /// Sounds of the sidebar's choice that have no embeddings yet, so aren't on the map.
    private(set) var missing = 0
    private(set) var inScope = 0
    /// Bumped to fit the whole map in view (Fit, and each new layout).
    private(set) var fitRequest = 0

    @ObservationIgnored private var cache: [Int: Layout] = [:]
    @ObservationIgnored private var recent: [Int] = []
    /// PE-AV + CLAP combined, one row per sound in id order: loaded while the map shows (177 MB
    /// for 29k sounds, in one piece).
    private struct Vectors: Sendable {
        var ids: [Int64]
        /// `dimensions` floats per sound, in `ids` order.
        var flat: PageBuffer
        var dimensions: Int
        var row: [Int64: Int]
    }
    @ObservationIgnored private var vectors: Vectors?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var currentKey: Int?

    func fit() { fitRequest += 1 }

    /// The map for these sounds (the sidebar's choice): from the cache, or worked out in the background.
    func update(scoped sounds: [SoundRecord], database: LibraryDatabase?) {
        let ids = sounds.compactMap(\.id).sorted()
        let key = ids.hashValue
        guard key != currentKey else { return }
        currentKey = key
        task?.cancel()
        highlight = nil
        inScope = ids.count
        if let cached = cache[key] {
            layout = cached
            missing = ids.count - cached.ids.count
            progress = nil
            fitRequest += 1
            return
        }
        layout = nil
        guard let database, !ids.isEmpty else { progress = nil; missing = 0; return }
        progress = 0
        task = Task { [weak self] in
            guard let self else { return }
            if vectors == nil {
                vectors = await Task.detached(priority: .userInitiated) { Self.loadVectors(database) }.value
            }
            guard !Task.isCancelled, let vectors else { return }
            let rows = ids.compactMap { vectors.row[$0] }   // in id order, as the vectors are
            let have = rows.map { vectors.ids[$0] }
            missing = ids.count - have.count
            let flag = CancellationFlag()
            let ticker = ProgressRelay { [weak self] p in self?.progress = p }
            let points: [SIMD2<Float>]? = await withTaskCancellationHandler {
                await Task.detached(priority: .userInitiated) {
                    let d = vectors.dimensions
                    // Every sound with vectors: the vectors as they are. Part of them: a copy of those rows.
                    let x = rows.count == vectors.ids.count ? vectors.flat : PageBuffer(count: rows.count * d)
                    if x !== vectors.flat {
                        vectors.flat.withFloats { all in
                            x.withFloats { part in
                                for (i, r) in rows.enumerated() { for c in 0 ..< d { part[i * d + c] = all[r * d + c] } }
                            }
                        }
                    }
                    return x.withFloats { f in
                        SoundMap.layout(flat: UnsafeBufferPointer(rebasing: f[0 ..< rows.count * d]), count: rows.count, dimensions: d,
                                        progress: { ticker.send($0) }, isCancelled: { flag.isSet })
                    }
                }.value
            } onCancel: {
                flag.set()
            }
            guard let points, !Task.isCancelled, currentKey == key else { return }
            let made = Layout(key: key, ids: have, points: points,
                              row: Dictionary(uniqueKeysWithValues: have.enumerated().map { ($0.element, $0.offset) }))
            cache[key] = made
            recent.removeAll { $0 == key }
            recent.append(key)
            if recent.count > 8 { cache[recent.removeFirst()] = nil }
            layout = made
            progress = nil
            fitRequest += 1
        }
    }

    /// The memory the map needs goes back while it isn't shown (the layouts stay: small).
    private func release() {
        task?.cancel()
        task = nil
        currentKey = nil
        vectors = nil
        progress = nil
    }

    nonisolated private static func loadVectors(_ db: LibraryDatabase) -> Vectors {
        var ids: [Int64] = [], row: [Int64: Int] = [:], flat: PageBuffer?, d = 0, capacity = 0
        try? db.forEachVectors(models: ["pe-av-large", "clap-general"], count: { capacity = $0 }) { id, blocks in
            let combined = SoundMap.combine(blocks)
            if flat == nil {
                d = combined.count
                flat = PageBuffer(count: capacity * d)
            }
            guard let flat, combined.count == d, ids.count < capacity else { return }
            let at = ids.count * d
            flat.withFloats { f in for c in 0 ..< d { f[at + c] = combined[c] } }
            row[id] = ids.count
            ids.append(id)
        }
        return Vectors(ids: ids, flat: flat ?? PageBuffer(count: 0), dimensions: d, row: row)
    }
}

/// Hands layout progress from the worker to the main actor, a few times a second at most.
private final class ProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1.0
    private let deliver: @MainActor (Double) -> Void

    init(_ deliver: @escaping @MainActor (Double) -> Void) { self.deliver = deliver }

    func send(_ p: Double) {
        let due = lock.withLock { () -> Bool in
            guard p - last >= 0.02 || p >= 1 else { return false }
            last = p
            return true
        }
        if due { Task { @MainActor in deliver(p) } }
    }
}

extension SoundBrowser {
    /// The sidebar's choice without the search: what the map is of.
    func scopedSounds(from model: AppModel) async -> [SoundRecord] {
        let scope = self.scope ?? .all, scores = similar?.scores
        let sounds = model.sounds, haystacks = model.soundIndex.haystacks, hidden = model.soundIndex.twins.hidden
        return await Task.detached(priority: .userInitiated) {
            Self.filtered(sounds, haystacks: haystacks, hidden: hidden, scope: scope, terms: [], scores: scores, order: [])
        }.value
    }
}

// MARK: colours and legend

/// The reference palette's eight categorical colours (dataviz skill), seven of them, light
/// and dark steps; the eighth colour is grey for every other category. Chosen by the owner
/// over three (2026-10-26) although some pairs are close: pointing at a dot names it, and
/// the legend lights up one category.
enum MapPalette {
    static let light: [UInt32] = [0x2A78D6, 0xEB6834, 0x1BAF7A, 0xEDA100, 0xE87BA4, 0x008300, 0x6250D6]
    static let dark: [UInt32] = [0x3987E5, 0xD95926, 0x199E70, 0xC98500, 0xD55181, 0x008300, 0x9085E9]
    static let named = light.count
    /// Other categories (filled) and no category (hollow).
    static let other = named, none = named + 1

    static func color(_ index: Int, dark isDark: Bool) -> NSColor {
        if index >= named { return isDark ? NSColor(white: 0.55, alpha: 1) : NSColor(white: 0.62, alpha: 1) }
        let hex = (isDark ? dark : light)[index]
        return NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                       blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// What each dot looks like for the current map, search and highlight.
struct MapStyle {
    struct Entry: Identifiable {
        var key: String?
        var title: String
        var count: Int
        var colorIndex: Int
        var id: String { key ?? "∅\(colorIndex)" }
    }

    var colors: [UInt8]
    var dimmed: [Bool]
    var legend: [Entry]
    /// The categories folded into "Other", by size.
    var others: [Entry]

    /// Inside one category the colours are its subcategories; elsewhere categories.
    @MainActor init(layout: SoundMapState.Layout, model: AppModel, highlight: String?) {
        let bySub: Bool
        switch model.soundBrowser.scope ?? .all {
        case .category, .catID: bySub = true
        default: bySub = false
        }
        let keys: [String?] = layout.ids.map { id in
            guard let s = model.sound(id: id), let category = s.category else { return nil }
            return bySub ? (s.subcategory ?? category) : category
        }
        var counts: [String: Int] = [:]
        for case let k? in keys { counts[k, default: 0] += 1 }
        let ranked = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        var slot: [String: Int] = [:]
        for (i, entry) in ranked.prefix(MapPalette.named).enumerated() { slot[entry.key] = i }
        colors = keys.map { k in UInt8(k.map { slot[$0] ?? MapPalette.other } ?? MapPalette.none) }
        let visible = Set(model.soundBrowser.visible.compactMap(\.id))
        dimmed = zip(layout.ids, keys).map { id, k in !visible.contains(id) || (highlight != nil && k != highlight) }
        legend = ranked.prefix(MapPalette.named).enumerated().map { i, e in
            Entry(key: e.key, title: e.key.capitalized, count: e.value, colorIndex: i)
        }
        others = ranked.dropFirst(MapPalette.named).map { Entry(key: $0.key, title: $0.key.capitalized, count: $0.value, colorIndex: MapPalette.other) }
        if !others.isEmpty {
            legend.append(Entry(key: nil, title: "\(others.count) other \(bySub ? "subcategories" : "categories")",
                                count: others.reduce(0) { $0 + $1.count }, colorIndex: MapPalette.other))
        }
        let none = keys.filter { $0 == nil }.count
        if none > 0 { legend.append(Entry(key: nil, title: "No category", count: none, colorIndex: MapPalette.none)) }
    }
}

// MARK: views

/// The map in the sound list's place, with its legend and progress.
struct SoundMapPane: View {
    @Environment(AppModel.self) private var model
    @State private var hoverPlay: Task<Void, Never>?

    var body: some View {
        // Built only while it's shown: in list mode, or with Music on screen, it costs nothing.
        if model.section == .sounds && model.soundMap.showing { map }
    }

    private var map: some View {
        let state = model.soundMap, browser = model.soundBrowser
        return ZStack {
            if let layout = state.layout {
                let style = MapStyle(layout: layout, model: model, highlight: state.highlight)
                SoundMapRepresentable(
                    points: layout.points, colors: style.colors, dimmed: style.dimmed,
                    selected: Set(browser.selection.compactMap { $0.flatMap { layout.row[$0] } }),
                    playing: model.playingSound?.id.flatMap { layout.row[$0] }, fitRequest: state.fitRequest,
                    name: { [model] i in Self.label(model, layout.ids[i]) },
                    onSelect: { indices, extend in
                        let ids = Set(indices.map { Optional(layout.ids[$0]) })
                        browser.selection = extend ? browser.selection.symmetricDifference(ids) : ids
                    },
                    onOpen: { i in if let s = model.sound(id: layout.ids[i]) { model.player.toggle(s.url) } },
                    onHover: { i in hovered(i.map { layout.ids[$0] }) },
                    onPrimary: {
                        if let id = browser.selection.first ?? nil, let s = model.sound(id: id) { model.player.toggle(s.url) }
                    },
                    onSkip: { model.skip(forward: $0, more: $1) })
                    .overlay(alignment: .topLeading) {
                        MapLegend(style: style, highlight: Binding(get: { state.highlight }, set: { state.highlight = $0 }))
                            .padding(12)
                    }
            }
            if let p = state.progress {
                VStack(spacing: 8) {
                    ProgressView(value: p).frame(width: 220)
                    Text("Drawing the map of \(state.inScope.formatted()) sounds…").foregroundStyle(.secondary)
                }
            } else if state.layout == nil || state.layout?.ids.isEmpty == true {
                ContentUnavailableView("Nothing to Map Yet", systemImage: "circle.grid.cross",
                                       description: Text(state.inScope == 0 ? "There are no sounds here."
                                                         : "These sounds haven't been analysed yet. The map shows sounds once they have their embeddings."))
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .shown(!model.sectionFaded)
        .task(id: MapKey(scope: browser.scope, version: model.version)) {
            state.update(scoped: await browser.scopedSounds(from: model), database: model.database)
        }
    }

    private struct MapKey: Hashable { var scope: SoundScope?; var version: Int }

    /// Hovering plays the dot under the pointer (Play on Hover), after a moment, so sweeping
    /// across dots doesn't start each one.
    private func hovered(_ id: Int64?) {
        hoverPlay?.cancel()
        guard model.soundMap.playOnHover, let id, let s = model.sound(id: id) else { return }
        hoverPlay = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, model.player.url != s.url || !model.player.isPlaying else { return }
            model.player.play(s.url)
        }
    }

    static func label(_ model: AppModel, _ id: Int64) -> String {
        guard let s = model.sound(id: id) else { return "" }
        return s.categoryText.isEmpty ? s.displayName : "\(s.displayName)\n\(s.categoryText)"
    }
}

/// The colours and what they mean; click one to light it up (the rest dimmed), again to clear.
private struct MapLegend: View {
    let style: MapStyle
    @Binding var highlight: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(style.legend) { entry in
                if entry.key == nil, entry.colorIndex == MapPalette.other {
                    // The folded categories: a menu, to light one of them up.
                    Menu {
                        ForEach(style.others) { e in
                            Button("\(e.title) (\(e.count.formatted()))") { highlight = highlight == e.key ? nil : e.key }
                        }
                    } label: { row(entry, lit: style.others.contains { $0.key == highlight }) }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                } else {
                    Button { if let key = entry.key { highlight = highlight == key ? nil : key } } label: {
                        row(entry, lit: entry.key != nil && entry.key == highlight)
                    }
                    .buttonStyle(.plain)
                    .disabled(entry.key == nil)
                }
            }
            if highlight != nil {
                Button("Show All") { highlight = nil }.buttonStyle(.link).font(.caption)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .font(.callout)
    }

    private func row(_ entry: MapStyle.Entry, lit: Bool) -> some View {
        HStack(spacing: 6) {
            Swatch(index: entry.colorIndex)
            Text(entry.title).foregroundStyle(.primary).fontWeight(lit ? .semibold : .regular)
            Text(entry.count.formatted()).foregroundStyle(.secondary).monospacedDigit()
        }
        .contentShape(Rectangle())
    }

    private struct Swatch: View {
        let index: Int
        @Environment(\.colorScheme) private var scheme

        var body: some View {
            let color = Color(nsColor: MapPalette.color(index, dark: scheme == .dark))
            if index == MapPalette.none {
                Circle().strokeBorder(color, lineWidth: 1.5).frame(width: 9, height: 9)
            } else {
                Circle().fill(color).frame(width: 9, height: 9)
            }
        }
    }
}

/// List | Map, above the sound list, with the map's controls.
struct SoundViewBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var state = model.soundMap
        HStack(spacing: 12) {
            Picker("View", selection: $state.showing) {
                Text("List").tag(false)
                Text("Map").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Show the sounds as a list or as a map, sounds that sound alike close together (⇧⌘M)")
            if state.showing {
                Toggle("Play on hover", isOn: $state.playOnHover).toggleStyle(.checkbox)
                Button("Fit") { state.fit() }
                    .help("Show the whole map")
                Spacer()
                if state.missing > 0 {
                    Text("\(state.missing.formatted()) not on the map yet (not analysed)").foregroundStyle(.secondary).font(.callout)
                }
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: drawing

struct SoundMapRepresentable: NSViewRepresentable {
    var points: [SIMD2<Float>]
    var colors: [UInt8]
    var dimmed: [Bool]
    var selected: Set<Int>
    var playing: Int?
    var fitRequest: Int
    var name: (Int) -> String
    var onSelect: (_ indices: [Int], _ extend: Bool) -> Void
    var onOpen: (Int) -> Void
    var onHover: (Int?) -> Void
    var onPrimary: () -> Void
    var onSkip: (_ forward: Bool, _ more: Bool) -> Bool

    func makeNSView(context: Context) -> SoundMapCanvas {
        let view = SoundMapCanvas()
        update(view)
        DispatchQueue.main.async { view.takeKeyboardIfFree() }
        return view
    }

    func updateNSView(_ view: SoundMapCanvas, context: Context) { update(view) }

    private func update(_ v: SoundMapCanvas) {
        v.callbacks = .init(name: name, onSelect: onSelect, onOpen: onOpen, onHover: onHover, onPrimary: onPrimary, onSkip: onSkip)
        v.set(points: points, colors: colors, dimmed: dimmed)
        if v.selected != selected { v.selected = selected }
        if v.playing != playing { v.playing = playing }
        if v.fitRequest != fitRequest { v.fitRequest = fitRequest }
    }
}

/// Draws every dot (Core Graphics, grouped by colour), finds the one under the pointer through
/// a grid, and handles zoom (pinch, scroll wheel, ⌘-scroll), pan (two fingers, ⌥-drag),
/// click, ⌘-click, drag to select a region, Space and the arrow keys.
final class SoundMapCanvas: NSView {
    struct Callbacks {
        var name: (Int) -> String = { _ in "" }
        var onSelect: (_ indices: [Int], _ extend: Bool) -> Void = { _, _ in }
        var onOpen: (Int) -> Void = { _ in }
        var onHover: (Int?) -> Void = { _ in }
        var onPrimary: () -> Void = {}
        var onSkip: (_ forward: Bool, _ more: Bool) -> Bool = { _, _ in false }
    }
    var callbacks = Callbacks()

    private(set) var points: [SIMD2<Float>] = []
    private var colors: [UInt8] = []
    private var dimmed: [Bool] = []
    /// Indices by colour (dimmed ones in their own groups, drawn first).
    private var groups: [[Int]] = []
    var selected: Set<Int> = [] { didSet { needsDisplay = true } }
    var playing: Int? { didSet { needsDisplay = true } }
    var fitRequest = -1 { didSet { scale = 1; center = CGPoint(x: 0.5, y: 0.5); needsDisplay = true } }

    private var scale: CGFloat = 1
    private var center = CGPoint(x: 0.5, y: 0.5)
    private var hovered: Int?
    private var marquee: (start: CGPoint, end: CGPoint, extend: Bool)?
    private var panning: CGPoint?
    private static let gridSize = 96
    private var grid: [[Int]] = []

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    /// A click on a dot selects it even while the window is in the background, as in the list.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func set(points: [SIMD2<Float>], colors: [UInt8], dimmed: [Bool]) {
        let newPoints = points != self.points
        guard newPoints || colors != self.colors || dimmed != self.dimmed else { return }
        self.points = points
        self.colors = colors
        self.dimmed = dimmed
        groups = Array(repeating: [], count: (MapPalette.none + 1) * 2)
        for i in points.indices where i < colors.count && i < dimmed.count {
            groups[Int(colors[i]) + (dimmed[i] ? 0 : MapPalette.none + 1)].append(i)
        }
        if newPoints {
            grid = Array(repeating: [], count: Self.gridSize * Self.gridSize)
            for (i, p) in points.enumerated() { grid[cell(p)].append(i) }
            hovered = nil
        }
        if let h = hovered, dimmed[h] { hovered = nil }
        needsDisplay = true
    }

    /// The keyboard comes here when the map appears, unless a field or the sidebar has it.
    func takeKeyboardIfFree() {
        guard let window, !isHiddenOrHasHiddenAncestor else { return }
        let current = window.firstResponder
        if current == nil || current === window || current is NSTableView && !(current is NSOutlineView) {
            window.makeFirstResponder(self)
        }
    }

    // MARK: geometry

    private var unit: CGFloat { (min(bounds.width, bounds.height) - 48) * scale }

    private func view(_ p: SIMD2<Float>) -> CGPoint {
        CGPoint(x: bounds.midX + (CGFloat(p.x) - center.x) * unit, y: bounds.midY + (CGFloat(p.y) - center.y) * unit)
    }

    private func normalised(_ v: CGPoint) -> CGPoint {
        CGPoint(x: center.x + (v.x - bounds.midX) / unit, y: center.y + (v.y - bounds.midY) / unit)
    }

    private func cell(_ p: SIMD2<Float>) -> Int {
        let g = Self.gridSize
        let x = min(g - 1, max(0, Int(p.x * Float(g)))), y = min(g - 1, max(0, Int(p.y * Float(g))))
        return y * g + x
    }

    private var radius: CGFloat { min(7, 3 + 0.9 * log2(max(1, scale))) }

    /// The dot nearest `v` within a few points. Dimmed dots are background: they can't be picked.
    private func dot(at v: CGPoint) -> Int? {
        let p = normalised(v), reach = (radius + 4) / unit, g = CGFloat(Self.gridSize)
        let x0 = max(0, Int((p.x - reach) * g)), x1 = min(Self.gridSize - 1, Int((p.x + reach) * g))
        let y0 = max(0, Int((p.y - reach) * g)), y1 = min(Self.gridSize - 1, Int((p.y + reach) * g))
        guard x0 <= x1, y0 <= y1 else { return nil }
        var best: (Int, CGFloat)?
        for y in y0 ... y1 {
            for x in x0 ... x1 {
                for i in grid[y * Self.gridSize + x] where !dimmed[i] {
                    let q = view(points[i])
                    let d = hypot(q.x - v.x, q.y - v.y)
                    if d <= radius + 4, best.map({ d < $0.1 }) ?? true { best = (i, d) }
                }
            }
        }
        return best?.0
    }

    private func zoom(by factor: CGFloat, around v: CGPoint) {
        let p = normalised(v)
        scale = min(64, max(1, scale * factor))
        center = CGPoint(x: p.x - (v.x - bounds.midX) / unit, y: p.y - (v.y - bounds.midY) / unit)
        needsDisplay = true
    }

    // MARK: drawing

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()
        guard let ctx = NSGraphicsContext.current?.cgContext, !points.isEmpty else { return }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let r = radius, visible = dirtyRect.insetBy(dx: -r - 3, dy: -r - 3)
        for (g, members) in groups.enumerated() where !members.isEmpty {
            let isDimmed = g <= MapPalette.none, colour = g % (MapPalette.none + 1)
            let path = CGMutablePath()
            for i in members {
                let v = view(points[i])
                if visible.contains(v) { path.addEllipse(in: CGRect(x: v.x - r, y: v.y - r, width: 2 * r, height: 2 * r)) }
            }
            let c = MapPalette.color(colour, dark: dark).withAlphaComponent(isDimmed ? 0.15 : 1).cgColor
            ctx.addPath(path)
            if colour == MapPalette.none {
                ctx.setStrokeColor(c)
                ctx.setLineWidth(1.25)
                ctx.strokePath()
            } else {
                ctx.setFillColor(c)
                ctx.fillPath()
            }
        }
        func ring(_ i: Int, _ color: NSColor, _ width: CGFloat, _ extra: CGFloat) {
            let v = view(points[i])
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(width)
            ctx.strokeEllipse(in: CGRect(x: v.x - r - extra, y: v.y - r - extra, width: 2 * (r + extra), height: 2 * (r + extra)))
        }
        for i in selected where i < points.count { ring(i, .labelColor, 1.5, 2.5) }
        if let p = playing, p < points.count { ring(p, .earmarkBlue, 2.5, 4.5) }
        if let m = marquee {
            let rect = CGRect(x: min(m.start.x, m.end.x), y: min(m.start.y, m.end.y),
                              width: abs(m.end.x - m.start.x), height: abs(m.end.y - m.start.y))
            ctx.setFillColor(NSColor.earmarkSelectionBlue.withAlphaComponent(0.12).cgColor)
            ctx.fill(rect)
            ctx.setStrokeColor(NSColor.earmarkBlue.cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(rect)
        }
        if let h = hovered, h < points.count {
            ring(h, .secondaryLabelColor, 1.5, 2.5)
            drawLabel(callbacks.name(h), near: view(points[h]))
        }
    }

    /// The hovered sound's name (and category) in a small box beside it.
    private func drawLabel(_ text: String, near v: CGPoint) {
        let lines = text.split(separator: "\n", maxSplits: 1).map(String.init)
        guard let first = lines.first else { return }
        let s = NSMutableAttributedString(string: first, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                                                                        .foregroundColor: NSColor.labelColor])
        if lines.count > 1 {
            s.append(NSAttributedString(string: "\n" + lines[1], attributes: [.font: NSFont.systemFont(ofSize: 11),
                                                                                .foregroundColor: NSColor.secondaryLabelColor]))
        }
        let size = s.boundingRect(with: CGSize(width: 320, height: 100), options: [.usesLineFragmentOrigin]).size
        var box = CGRect(x: v.x + 12, y: v.y - size.height / 2 - 6, width: ceil(size.width) + 16, height: ceil(size.height) + 12)
        if box.maxX > bounds.maxX - 4 { box.origin.x = v.x - 12 - box.width }
        box.origin.y = min(max(box.minY, bounds.minY + 4), bounds.maxY - box.height - 4)
        let shape = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
        NSColor.windowBackgroundColor.withAlphaComponent(0.95).setFill()
        shape.fill()
        NSColor.separatorColor.setStroke()
        shape.stroke()
        s.draw(with: box.insetBy(dx: 8, dy: 6), options: [.usesLineFragmentOrigin])
    }

    // MARK: events

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) { hover(dot(at: convert(event.locationInWindow, from: nil))) }
    override func mouseExited(with event: NSEvent) { hover(nil) }

    private func hover(_ i: Int?) {
        guard i != hovered else { return }
        hovered = i
        needsDisplay = true
        callbacks.onHover(i)
    }

    override func scrollWheel(with event: NSEvent) {
        let v = convert(event.locationInWindow, from: nil)
        if event.hasPreciseScrollingDeltas, !event.modifierFlags.contains(.command) {
            // Two fingers on a trackpad: pan.
            center.x -= event.scrollingDeltaX / unit
            center.y -= event.scrollingDeltaY / unit
            needsDisplay = true
        } else {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.1
            zoom(by: exp(delta), around: v)
        }
        hover(dot(at: v))
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, around: convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        let v = convert(event.locationInWindow, from: nil)
        guard bounds.contains(v) else { return }   // synthetic events can arrive from outside the map
        window?.makeFirstResponder(self)
        let extend = !event.modifierFlags.intersection([.command, .shift]).isEmpty
        if event.modifierFlags.contains(.option) {
            panning = v
        } else if let i = dot(at: v) {
            if event.clickCount == 2 { callbacks.onOpen(i) } else { callbacks.onSelect([i], extend) }
        } else {
            marquee = (v, v, extend)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let v = convert(event.locationInWindow, from: nil)
        if let p = panning {
            center.x -= (v.x - p.x) / unit
            center.y -= (v.y - p.y) / unit
            panning = v
            needsDisplay = true
        } else if marquee != nil {
            marquee?.end = v
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { panning = nil; marquee = nil; needsDisplay = true }
        guard let m = marquee else { return }
        let a = normalised(m.start), b = normalised(m.end)
        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        if rect.width * unit < 3, rect.height * unit < 3 {
            if !m.extend { callbacks.onSelect([], false) }   // a click on empty space: clear
            return
        }
        let inside = points.indices.filter { !dimmed[$0] && rect.contains(CGPoint(x: CGFloat(points[$0].x), y: CGFloat(points[$0].y))) }
        callbacks.onSelect(inside, m.extend)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        if let key = event.specialKey, key == .leftArrow || key == .rightArrow, modifiers.isEmpty || modifiers == .shift {
            _ = callbacks.onSkip(key == .rightArrow, modifiers == .shift)   // nothing playing: nothing to do (no beep)
            return
        }
        if modifiers.isEmpty, [" ", "\r"].contains(event.charactersIgnoringModifiers ?? "") {
            callbacks.onPrimary()
        } else if modifiers.isEmpty, event.keyCode == 53 {   // Escape
            callbacks.onSelect([], false)
        } else {
            super.keyDown(with: event)
        }
    }
}
