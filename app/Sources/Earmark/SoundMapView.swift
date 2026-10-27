import Accelerate
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
        /// Each sound joined to its 3 nearest (`SoundMap.Map.links`), drawn as fine lines.
        var links: [SIMD2<Int32>]
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
            let map: SoundMap.Map? = await withTaskCancellationHandler {
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
                        SoundMap.map(flat: UnsafeBufferPointer(rebasing: f[0 ..< rows.count * d]), count: rows.count, dimensions: d,
                                     progress: { ticker.send($0) }, isCancelled: { flag.isSet })
                    }
                }.value
            } onCancel: {
                flag.set()
            }
            guard let map, !Task.isCancelled, currentKey == key else { return }
            let made = Layout(key: key, ids: have, points: map.points, links: map.links,
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
        let membership = model.groups.membership
        return await Task.detached(priority: .userInitiated) {
            Self.filtered(sounds, haystacks: haystacks, hidden: hidden, scope: scope, terms: [], scores: scores,
                          membership: membership, order: [])
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
        let c = rgb(index, dark: isDark)
        return NSColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
    }

    /// sRGB components, 0…1.
    static func rgb(_ index: Int, dark isDark: Bool) -> SIMD3<Float> {
        // Grey recedes, so the colours carry the map.
        if index >= named { return SIMD3(repeating: isDark ? 0.40 : 0.72) }
        let hex = (isDark ? dark : light)[index]
        return SIMD3(Float(hex >> 16 & 0xFF), Float(hex >> 8 & 0xFF), Float(hex & 0xFF)) / 255
    }

    /// Behind the map: near black in dark mode (the glow and the fine lines show on it), white
    /// in light mode.
    static let background = NSColor(name: "soundMapBackground") { appearance in
        background(dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    }

    static func background(dark: Bool) -> NSColor {
        dark ? NSColor(srgbRed: 0.043, green: 0.051, blue: 0.063, alpha: 1) : NSColor(white: 1, alpha: 1)
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

    /// What the colours stand for: categories; inside one category its subcategories; inside a
    /// subcategory with similarity groups, the groups.
    enum Keying { case category, subcategory, group }

    @MainActor init(layout: SoundMapState.Layout, model: AppModel, highlight: String?) {
        let keying: Keying = switch model.soundBrowser.scope ?? .all {
        case .catID(let c): model.groups(catID: c).isEmpty ? .subcategory : .group
        case .category, .group: .subcategory
        default: .category
        }
        let keys: [String?] = layout.ids.map { id in
            guard let s = model.sound(id: id), let category = s.category else { return nil }
            switch keying {
            case .category: return category
            case .subcategory: return s.subcategory ?? category
            case .group: return model.group(of: s)?.title
            }
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
            Entry(key: e.key, title: keying == .group ? e.key : e.key.capitalized, count: e.value, colorIndex: i)
        }
        others = ranked.dropFirst(MapPalette.named).map {
            Entry(key: $0.key, title: keying == .group ? $0.key : $0.key.capitalized, count: $0.value, colorIndex: MapPalette.other)
        }
        if !others.isEmpty {
            let kind = switch keying { case .category: "categories"; case .subcategory: "subcategories"; case .group: "groups" }
            legend.append(Entry(key: nil, title: "\(others.count) other \(kind)",
                                count: others.reduce(0) { $0 + $1.count }, colorIndex: MapPalette.other))
        }
        let none = keys.filter { $0 == nil }.count
        if none > 0 {
            legend.append(Entry(key: nil, title: keying == .group ? "Not grouped yet" : "No category", count: none,
                                colorIndex: MapPalette.none))
        }
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
                    points: layout.points, links: layout.links, colors: style.colors, dimmed: style.dimmed,
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
        .background(Color(nsColor: MapPalette.background))
        .shown(!model.sectionFaded)
        .task(id: MapKey(scope: browser.scope, version: model.version, groups: showsGroup ? model.groupsVersion : 0)) {
            state.update(scoped: await browser.scopedSounds(from: model), database: model.database)
        }
    }

    private var showsGroup: Bool { if case .group = model.soundBrowser.scope { true } else { false } }

    private struct MapKey: Hashable { var scope: SoundScope?; var version: Int; var groups: Int }

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
        guard !s.categoryText.isEmpty else { return s.displayName }
        let group = model.groups(catID: s.catID).isEmpty ? nil : model.group(of: s)?.title
        return "\(s.displayName)\n\(s.categoryText)" + (group.map { " · \($0)" } ?? "")
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

/// The categories' colours as a faint wash behind the dots: each lit dot spreads its colour
/// around it (a wide Gaussian, `spread` of the map), and where groups meet their colours
/// blend. One image for the whole map plus a margin (−`margin`…1 + `margin` both ways, in map
/// space, so the glow fades out past the outermost dots instead of being cut off), and each
/// lit dot's colour leaning towards the colours close around it (a narrower Gaussian,
/// `shading`), so the dots shade into each other too.
enum MapGlow {
    static let margin: Float = 0.1
    /// Sigmas, in map units. The glow is wide so it reads as a wash, not halos around groups
    /// (owner, 2026-10-27: "dim it down… as soft as possible").
    static let shading: Float = 0.012, spread: Float = 0.026

    struct Result {
        var image: CGImage?
        /// sRGB, per dot (dimmed ones keep their category's colour).
        var dotColors: [SIMD3<Float>]
    }

    static func make(points: [SIMD2<Float>], colors: [UInt8], dimmed: [Bool], dark: Bool, size: Int = 512) -> Result {
        let n = min(points.count, colors.count, dimmed.count), cells = size * size
        var r = [Float](repeating: 0, count: cells), g = r, b = r, w = r
        let palette = (0 ... MapPalette.none).map { MapPalette.rgb($0, dark: dark) }
        let last = Float(size - 1)
        func cell(_ p: SIMD2<Float>) -> SIMD2<Float> {
            ((p + margin) / (1 + 2 * margin) * last).clamped(lowerBound: SIMD2(repeating: 0), upperBound: SIMD2(repeating: last))
        }
        for i in 0 ..< n where !dimmed[i] {
            // Grey (other or no category) glows less: the colours are what the glow is for.
            let c = palette[Int(colors[i])], weight: Float = colors[i] >= MapPalette.named ? 0.35 : 1
            let xy = cell(points[i]), x = xy.x, y = xy.y
            let x0 = min(size - 2, Int(x)), y0 = min(size - 2, Int(y))
            let fx = x - Float(x0), fy = y - Float(y0)
            for (dx, dy, f) in [(0, 0, (1 - fx) * (1 - fy)), (1, 0, fx * (1 - fy)), (0, 1, (1 - fx) * fy), (1, 1, fx * fy)] {
                let k = (y0 + dy) * size + x0 + dx, wt = f * weight
                r[k] += c.x * wt; g[k] += c.y * wt; b[k] += c.z * wt; w[k] += wt
            }
        }
        // Map units to cells.
        let toCells = last / (1 + 2 * margin)
        func blurAll(_ sigma: Float) {
            blur(&r, size: size, sigma: sigma)
            blur(&g, size: size, sigma: sigma)
            blur(&b, size: size, sigma: sigma)
            blur(&w, size: size, sigma: sigma)
        }
        blurAll(shading * toCells)
        // Each lit dot: 30% of the colour around it (grey ones 50%, so they take on their
        // neighbourhood's).
        var dotColors = (0 ..< n).map { palette[Int(colors[$0])] }
        for i in 0 ..< n where !dimmed[i] {
            let xy = cell(points[i]), k = Int(xy.y.rounded()) * size + Int(xy.x.rounded())
            guard w[k] > 1e-6 else { continue }
            let around = SIMD3(r[k], g[k], b[k]) / w[k], share: Float = colors[i] >= MapPalette.named ? 0.5 : 0.3
            dotColors[i] = dotColors[i] * (1 - share) + around * share
        }
        // Wider for the glow (Gaussians add up: spread² = shading² + the rest²).
        blurAll((spread * spread - shading * shading).squareRoot() * toCells)
        // How thick the glow gets: the densest places (the 98th percentile of the field) are
        // full, and it eases out (smoothstep) so a few dots on their own get no halo.
        let sorted = w.filter { $0 > 1e-6 }.sorted()
        guard let top = sorted.isEmpty ? nil : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.98))], top > 0
        else { return Result(image: nil, dotColors: dotColors) }
        let strongest: Float = dark ? 0.2 : 0.11
        var pixels = [UInt8](repeating: 0, count: cells * 4)
        for k in 0 ..< cells where w[k] > 1e-6 {
            let t = min(1, w[k] / top), alpha = t * t * (3 - 2 * t) * strongest
            let c = SIMD3(r[k], g[k], b[k]) / w[k]
            // Premultiplied and dithered (interleaved gradient noise), or so faint a wash shows
            // steps in 8 bits. The same offset for all four keeps colour ≤ alpha.
            let x = Float(k % size), y = Float(k / size)
            let noise = (52.982919 * (0.06711056 * x + 0.00583715 * y).truncatingRemainder(dividingBy: 1)).truncatingRemainder(dividingBy: 1)
            func byte(_ v: Float) -> UInt8 { UInt8(min(255, v * 255 + noise)) }
            pixels[k * 4] = byte(c.x * alpha)
            pixels[k * 4 + 1] = byte(c.y * alpha)
            pixels[k * 4 + 2] = byte(c.z * alpha)
            pixels[k * 4 + 3] = byte(alpha)
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(pixels) as CFData) else { return Result(image: nil, dotColors: dotColors) }
        let image = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4, space: space,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        return Result(image: image, dotColors: dotColors)
    }

    /// A Gaussian (sigma in cells) along rows, then columns (vImage), zeros beyond the edges.
    private static func blur(_ plane: inout [Float], size: Int, sigma: Float) {
        let half = Int((3 * sigma).rounded(.up))
        var kernel = (-half ... half).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
        let total = kernel.reduce(0, +)
        kernel = kernel.map { $0 / total }
        var out = [Float](repeating: 0, count: plane.count)
        plane.withUnsafeMutableBytes { src in
            out.withUnsafeMutableBytes { dst in
                var s = vImage_Buffer(data: src.baseAddress, height: vImagePixelCount(size), width: vImagePixelCount(size), rowBytes: size * 4)
                var d = vImage_Buffer(data: dst.baseAddress, height: vImagePixelCount(size), width: vImagePixelCount(size), rowBytes: size * 4)
                _ = vImageSepConvolve_PlanarF(&s, &d, nil, 0, 0, kernel, UInt32(kernel.count), kernel, UInt32(kernel.count),
                                              0, 0, vImage_Flags(kvImageBackgroundColorFill))
            }
        }
        plane = out
    }
}

struct SoundMapRepresentable: NSViewRepresentable {
    var points: [SIMD2<Float>]
    var links: [SIMD2<Int32>]
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
        v.set(points: points, links: links, colors: colors, dimmed: dimmed)
        if v.selected != selected { v.selected = selected }
        if v.playing != playing { v.playing = playing }
        if v.fitRequest != fitRequest { v.fitRequest = fitRequest }
    }
}

/// Draws the map (Core Graphics): a fine grid fixed to the map, the categories' colours as a
/// soft glow blending into each other (`MapGlow`, made once per layout, search or highlight and
/// stretched with zoom), hairlines from each sound to its nearest, then small dots. Finds the
/// dot under the pointer through a grid, and handles zoom (pinch, scroll wheel, ⌘-scroll), pan
/// (two fingers, ⌥-drag), click, ⌘-click, drag to select a region, Space and the arrow keys.
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
    private var links: [SIMD2<Int32>] = []
    private var colors: [UInt8] = []
    private var dimmed: [Bool] = []
    /// Indices by colour (dimmed ones in their own groups, drawn first).
    private var groups: [[Int]] = []
    /// The links to draw (both ends lit, not across the map) by their two colours (`linkKey`).
    private var linkGroups: [[SIMD2<Int32>]] = []
    /// Made when first drawn after a change, for the appearance it was made in: the glow and
    /// the lit dots grouped by their shaded colour (`MapGlow`), grey ones first.
    private var glow: (image: CGImage?, dots: [(color: CGColor, hollow: Bool, members: [Int])], dark: Bool)?
    var selected: Set<Int> = [] { didSet { overlay.needsDisplay = true } }
    var playing: Int? { didSet { overlay.needsDisplay = true } }
    var fitRequest = -1 { didSet { scale = 1; center = CGPoint(x: 0.5, y: 0.5); redraw() } }

    private var scale: CGFloat = 1
    private var center = CGPoint(x: 0.5, y: 0.5)
    private var hovered: Int?
    private var marquee: (start: CGPoint, end: CGPoint, extend: Bool)? { didSet { overlay.needsDisplay = true } }
    /// Where the button went down on a dot: dragging from there still selects an area (dots
    /// are packed so close that most drags start on one).
    private var pressedOnDot: (point: CGPoint, extend: Bool)?
    private let overlay = SoundMapOverlay()
    private var panning: CGPoint?
    private static let gridSize = 96
    private var grid: [[Int]] = []
    /// Links longer than this (in map units, the map being 1 across) join sounds the layout put
    /// apart: drawn, they'd cross the map.
    private static let longestLink: Float = 0.035

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    /// A click on a dot selects it even while the window is in the background, as in the list.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Since macOS 14 views draw outside their bounds unless told not to: the glow, stretched
        // as you zoom, covered the sidebar and the detail pane.
        clipsToBounds = true
        overlay.clipsToBounds = true
        overlay.canvas = self
        addSubview(overlay)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        overlay.frame = bounds
    }

    /// The map and what's on top of it (after zooming, panning or new dots).
    private func redraw() {
        needsDisplay = true
        overlay.needsDisplay = true
    }

    func set(points: [SIMD2<Float>], links: [SIMD2<Int32>], colors: [UInt8], dimmed: [Bool]) {
        let newPoints = points != self.points
        guard newPoints || colors != self.colors || dimmed != self.dimmed else { return }
        self.points = points
        self.links = links
        self.colors = colors
        self.dimmed = dimmed
        let n = min(points.count, colors.count, dimmed.count)
        groups = Array(repeating: [], count: (MapPalette.none + 1) * 2)
        for i in 0 ..< n {
            groups[Int(colors[i]) + (dimmed[i] ? 0 : MapPalette.none + 1)].append(i)
        }
        linkGroups = Array(repeating: [], count: (MapPalette.none + 1) * (MapPalette.none + 1))
        for link in links {
            let i = Int(link.x), j = Int(link.y)
            guard i < n, j < n, !dimmed[i], !dimmed[j] else { continue }
            let d = points[i] - points[j]
            guard (d * d).sum() <= Self.longestLink * Self.longestLink else { continue }
            linkGroups[Self.linkKey(colors[i], colors[j])].append(link)
        }
        glow = nil
        if newPoints {
            grid = Array(repeating: [], count: Self.gridSize * Self.gridSize)
            for (i, p) in points.enumerated() { grid[cell(p)].append(i) }
            hovered = nil
        }
        if let h = hovered, dimmed[h] { hovered = nil }
        redraw()
    }

    private static func linkKey(_ a: UInt8, _ b: UInt8) -> Int {
        Int(min(a, b)) * (MapPalette.none + 1) + Int(max(a, b))
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

    /// Small dots, a little bigger as you zoom in.
    private var radius: CGFloat { min(4, 1.4 + 0.6 * log2(max(1, scale))) }
    /// How far from a dot the pointer still picks it: more than the dot, which is small.
    private var reach: CGFloat { max(radius + 3, 6) }

    /// The dot nearest `v` within `reach`. Dimmed dots are background: they can't be picked.
    private func dot(at v: CGPoint) -> Int? {
        let p = normalised(v), reach = reach, g = CGFloat(Self.gridSize), r = reach / unit
        let x0 = max(0, Int((p.x - r) * g)), x1 = min(Self.gridSize - 1, Int((p.x + r) * g))
        let y0 = max(0, Int((p.y - r) * g)), y1 = min(Self.gridSize - 1, Int((p.y + r) * g))
        guard x0 <= x1, y0 <= y1 else { return nil }
        var best: (Int, CGFloat)?
        for y in y0 ... y1 {
            for x in x0 ... x1 {
                for i in grid[y * Self.gridSize + x] where !dimmed[i] {
                    let q = view(points[i])
                    let d = hypot(q.x - v.x, q.y - v.y)
                    if d <= reach, best.map({ d < $0.1 }) ?? true { best = (i, d) }
                }
            }
        }
        return best?.0
    }

    private func zoom(by factor: CGFloat, around v: CGPoint) {
        let p = normalised(v)
        scale = min(64, max(1, scale * factor))
        center = CGPoint(x: p.x - (v.x - bounds.midX) / unit, y: p.y - (v.y - bounds.midY) / unit)
        redraw()
    }

    // MARK: drawing

    override func viewDidChangeEffectiveAppearance() { redraw() }

    override func draw(_ dirtyRect: NSRect) {
        MapPalette.background.setFill()
        dirtyRect.fill()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        drawGrid(ctx, in: dirtyRect, dark: dark)
        guard !points.isEmpty else { return }
        let r = radius, visible = dirtyRect.insetBy(dx: -r - 3, dy: -r - 3)

        // The glow: made once, stretched over the map; fainter as you zoom in and it blurs.
        if glow == nil || glow?.dark != dark {
            let made = MapGlow.make(points: points, colors: colors, dimmed: dimmed, dark: dark)
            glow = (made.image, Self.litGroups(made.dotColors, colors: colors, dimmed: dimmed), dark)
        }
        if let image = glow?.image {
            let a = view(SIMD2(repeating: -MapGlow.margin)), b = view(SIMD2(repeating: 1 + MapGlow.margin))
            ctx.saveGState()
            ctx.setAlpha(1 / (1 + 0.35 * log2(scale)))
            ctx.interpolationQuality = .high
            // The image's first row is the map's top; the view is flipped.
            ctx.translateBy(x: a.x, y: b.y)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: b.x - a.x, height: b.y - a.y))
            ctx.restoreGState()
        }

        // Hairlines to each sound's nearest, in the mix of their two colours.
        ctx.setLineWidth(0.5)
        ctx.setLineCap(.round)
        let colours = (0 ... MapPalette.none).map { MapPalette.rgb($0, dark: dark) }
        for (key, members) in linkGroups.enumerated() where !members.isEmpty {
            // A path per colour. Not strokeLineSegments: macOS 27's batched line drawing failed
            // an assertion (cg-draw-lines.cpp, "color_element_itr") with the colours of a
            // subcategory's groups, and the app crashed (2026-10-27).
            let path = CGMutablePath()
            for link in members {
                let a = view(points[Int(link.x)]), b = view(points[Int(link.y)])
                // Shorter than the dots: hidden under them anyway.
                guard abs(a.x - b.x) + abs(a.y - b.y) > 2 * r, visible.contains(a) || visible.contains(b) else { continue }
                path.move(to: a)
                path.addLine(to: b)
            }
            guard !path.isEmpty else { continue }
            let mix = (colours[key / (MapPalette.none + 1)] + colours[key % (MapPalette.none + 1)]) / 2
            ctx.setStrokeColor(CGColor(srgbRed: CGFloat(mix.x), green: CGFloat(mix.y), blue: CGFloat(mix.z),
                                       alpha: dark ? 0.32 : 0.38))
            ctx.addPath(path)
            ctx.strokePath()
        }

        // The dots: dimmed ones first, faint, in their category's colour; then the lit ones,
        // shaded. No category: hollow.
        func dots(_ members: [Int], _ color: CGColor, hollow: Bool) {
            let path = CGMutablePath()
            for i in members {
                let v = view(points[i])
                if visible.contains(v) { path.addEllipse(in: CGRect(x: v.x - r, y: v.y - r, width: 2 * r, height: 2 * r)) }
            }
            ctx.addPath(path)
            if hollow {
                ctx.setStrokeColor(color)
                ctx.setLineWidth(0.75)
                ctx.strokePath()
            } else {
                ctx.setFillColor(color)
                ctx.fillPath()
            }
        }
        for (colour, members) in groups.prefix(MapPalette.none + 1).enumerated() where !members.isEmpty {
            dots(members, MapPalette.color(colour, dark: dark).withAlphaComponent(0.16).cgColor, hollow: colour == MapPalette.none)
        }
        for group in glow?.dots ?? [] { dots(group.members, group.color, hollow: group.hollow) }
    }

    /// Lit dots by their colour rounded to 5 bits a channel (a few hundred groups: one fill each),
    /// grey categories first so the colours sit on top.
    private static func litGroups(_ shaded: [SIMD3<Float>], colors: [UInt8], dimmed: [Bool]) -> [(color: CGColor, hollow: Bool, members: [Int])] {
        var byKey: [Int: [Int]] = [:]
        for i in shaded.indices where i < dimmed.count && !dimmed[i] {
            let q = (shaded[i] * 31).rounded(.toNearestOrAwayFromZero)
            let grey = colors[i] >= MapPalette.named ? 0 : 1, hollow = colors[i] == MapPalette.none ? 1 : 0
            byKey[((grey * 2 + hollow) << 15) | (Int(q.x) << 10) | (Int(q.y) << 5) | Int(q.z), default: []].append(i)
        }
        return byKey.keys.sorted().map { key in
            let c = SIMD3(Float(key >> 10 & 31), Float(key >> 5 & 31), Float(key & 31)) / 31
            return (CGColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1), key >> 15 & 1 == 1, byKey[key]!)
        }
    }

    /// What changes as you point and select, drawn by `overlay` on top of the map, so those
    /// don't redraw the ~90,000 shapes below.
    fileprivate func drawOverlay(in ctx: CGContext, dirtyRect: CGRect) {
        guard !points.isEmpty else { return }
        let r = radius, visible = dirtyRect.insetBy(dx: -r - 3, dy: -r - 3)
        func ring(_ i: Int, _ color: NSColor, _ width: CGFloat, _ extra: CGFloat) {
            let v = view(points[i])
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(width)
            ctx.strokeEllipse(in: CGRect(x: v.x - r - extra, y: v.y - r - extra, width: 2 * (r + extra), height: 2 * (r + extra)))
        }
        // Selected: a pip in the text colour in the middle of each dot, which keeps its colour
        // round it (hundreds of selected dots read as a fine stipple, not a patch); a ring too
        // while there are few, so one selected sound stands out.
        let chosen = selected.filter { $0 < points.count }
        if !chosen.isEmpty {
            let path = CGMutablePath(), e = max(0.8, r * 0.55)
            for i in chosen {
                let v = view(points[i])
                if visible.contains(v) { path.addEllipse(in: CGRect(x: v.x - e, y: v.y - e, width: 2 * e, height: 2 * e)) }
            }
            ctx.addPath(path)
            ctx.setFillColor(NSColor.labelColor.cgColor)
            ctx.fillPath()
            if chosen.count <= 40 { for i in chosen { ring(i, .labelColor, 1, 2.5) } }
        }
        if let p = playing, p < points.count { ring(p, .earmarkBlue, 1.5, 3.5) }
        if let m = marquee {
            let rect = CGRect(x: min(m.start.x, m.end.x), y: min(m.start.y, m.end.y),
                              width: abs(m.end.x - m.start.x), height: abs(m.end.y - m.start.y))
            ctx.setFillColor(NSColor.earmarkSelectionBlue.withAlphaComponent(0.1).cgColor)
            ctx.fill(rect)
            ctx.setStrokeColor(NSColor.earmarkBlue.cgColor)
            ctx.setLineWidth(0.75)
            ctx.stroke(rect)
        }
        if let h = hovered, h < points.count {
            ring(h, .labelColor, 1, 2.5)
            drawLabel(callbacks.name(h), near: view(points[h]))
        }
    }

    /// A fine grid fixed to the map, its lines 1/16 of the map apart, halving as you zoom in
    /// (so 60–120 points apart on screen).
    private func drawGrid(_ ctx: CGContext, in rect: CGRect, dark: Bool) {
        let step = 1 / (16 * pow(2, floor(log2(scale))))
        let a = normalised(rect.origin), b = normalised(CGPoint(x: rect.maxX, y: rect.maxY))
        var segments: [CGPoint] = []
        var x = (a.x / step).rounded(.down) * step
        while x <= b.x {
            let v = view(SIMD2(Float(x), 0)).x
            segments += [CGPoint(x: v, y: rect.minY), CGPoint(x: v, y: rect.maxY)]
            x += step
        }
        var y = (a.y / step).rounded(.down) * step
        while y <= b.y {
            let v = view(SIMD2(0, Float(y))).y
            segments += [CGPoint(x: rect.minX, y: v), CGPoint(x: rect.maxX, y: v)]
            y += step
        }
        ctx.setStrokeColor((dark ? NSColor.white : NSColor.black).withAlphaComponent(dark ? 0.045 : 0.05).cgColor)
        ctx.setLineWidth(0.5)
        ctx.strokeLineSegments(between: segments)
    }

    /// The hovered sound's name (and category) in a small box beside it.
    private func drawLabel(_ text: String, near v: CGPoint) {
        let lines = text.split(separator: "\n", maxSplits: 1).map(String.init)
        guard let first = lines.first else { return }
        let s = NSMutableAttributedString(string: first, attributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
                                                                        .foregroundColor: NSColor.labelColor])
        if lines.count > 1 {
            s.append(NSAttributedString(string: "\n" + lines[1], attributes: [.font: NSFont.systemFont(ofSize: 10.5),
                                                                                .foregroundColor: NSColor.secondaryLabelColor]))
        }
        let size = s.boundingRect(with: CGSize(width: 320, height: 100), options: [.usesLineFragmentOrigin]).size
        var box = CGRect(x: v.x + 10, y: v.y - size.height / 2 - 5, width: ceil(size.width) + 14, height: ceil(size.height) + 10)
        if box.maxX > bounds.maxX - 4 { box.origin.x = v.x - 10 - box.width }
        box.origin.y = min(max(box.minY, bounds.minY + 4), bounds.maxY - box.height - 4)
        let shape = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5)
        NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
        shape.fill()
        NSColor.separatorColor.setStroke()
        shape.lineWidth = 0.5
        shape.stroke()
        s.draw(with: box.insetBy(dx: 7, dy: 5), options: [.usesLineFragmentOrigin])
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
        overlay.needsDisplay = true
        callbacks.onHover(i)
    }

    override func scrollWheel(with event: NSEvent) {
        let v = convert(event.locationInWindow, from: nil)
        if event.hasPreciseScrollingDeltas, !event.modifierFlags.contains(.command) {
            // Two fingers on a trackpad: pan.
            center.x -= event.scrollingDeltaX / unit
            center.y -= event.scrollingDeltaY / unit
            redraw()
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
            pressedOnDot = (v, extend)
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
            redraw()
        } else if marquee != nil {
            marquee?.end = v
        } else if let press = pressedOnDot, hypot(v.x - press.point.x, v.y - press.point.y) > 4 {
            marquee = (press.point, v, press.extend)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { panning = nil; marquee = nil; pressedOnDot = nil }
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

/// Draws the canvas's selection, what's playing, the pointer's ring and label and the
/// selection box, on top of the map; clicks go through to the map.
final class SoundMapOverlay: NSView {
    weak var canvas: SoundMapCanvas?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        canvas?.drawOverlay(in: ctx, dirtyRect: dirtyRect)
    }
}
