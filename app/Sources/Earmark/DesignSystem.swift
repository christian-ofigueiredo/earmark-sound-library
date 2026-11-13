import AppKit
import SwiftUI

// The owner's design system (~/Documents/Design System/design-system: tokens.css, README), the
// parts Earmark uses. Neutrals do the work; red is one signal per screen: what's playing and the
// key that plays it. The system's type is Babcock (titles and numbers, 24 pt and up) and N27
// (everything else). Their licences don't allow putting them in an app, so Earmark uses them only
// where they're installed, and the system's condensed font elsewhere.

// MARK: colour

extension NSColor {
    /// A token with its light and dark values (tokens.css).
    private static func token(_ name: String, light: UInt32, dark: UInt32, darkAlpha: CGFloat = 1) -> NSColor {
        NSColor(name: NSColor.Name(name)) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                           blue: CGFloat(hex & 0xff) / 255, alpha: isDark ? darkAlpha : 1)
        }
    }

    /// The window's ground: Seashell; in dark mode Shark (the owner, 2026-11-13: Ebony's near
    /// black made no sense for a window, as in Offload).
    static let dsBackground = token("dsBackground", light: 0xF1F1F1, dark: 0x181A20)
    /// Panels on the ground: the sidebar, the inspector. In dark mode Shark too, the panels
    /// parted by the split view's lines.
    static let dsSurface = token("dsSurface", light: 0xFFFFFF, dark: 0x181A20)
    /// Sunken tracks and wells.
    static let dsSunken = token("dsSunken", light: 0xDEDEDE, dark: 0x0C0D11)
    /// Decoration only: rules and outlines.
    static let dsLine = token("dsLine", light: 0xDEDEDE, dark: 0x2A2D35)
    static let dsInk = token("dsInk", light: 0x020306, dark: 0xF1F1F1)
    static let dsInkMuted = token("dsInkMuted", light: 0x5D6068, dark: 0x9A9DA6)
    /// Text on an `dsInk` fill.
    static let dsOnInk = token("dsOnInk", light: 0xF1F1F1, dark: 0x020306)
    /// The one red: Ruby Red on light grounds, Milano Red on dark.
    static let dsAccent = token("dsAccent", light: 0xA00A00, dark: 0xD41101)
    /// What's selected in a list: ink, faint. (Red stays for what's playing.)
    static let dsSelection = NSColor(name: "dsSelection") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0xF1 / 255, green: 0xF1 / 255, blue: 0xF1 / 255, alpha: 0.13)
            : NSColor(srgbRed: 0x02 / 255, green: 0x03 / 255, blue: 0x06 / 255, alpha: 0.09)
    }
}

extension Color {
    static let dsBackground = Color(nsColor: .dsBackground)
    static let dsSurface = Color(nsColor: .dsSurface)
    static let dsSunken = Color(nsColor: .dsSunken)
    static let dsLine = Color(nsColor: .dsLine)
    static let dsInk = Color(nsColor: .dsInk)
    static let dsInkMuted = Color(nsColor: .dsInkMuted)
    static let dsOnInk = Color(nsColor: .dsOnInk)
    static let dsAccent = Color(nsColor: .dsAccent)
    static let dsSelection = Color(nsColor: .dsSelection)
}

extension ShapeStyle where Self == Color {
    static var dsInk: Color { .dsInk }
    static var dsInkMuted: Color { .dsInkMuted }
    static var dsAccent: Color { .dsAccent }
}

// MARK: type

enum DSFont {
    /// The installed variable families, if any.
    private static let families: [String: String] = {
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        var found: [String: String] = [:]
        for (key, names) in [("display", ["BABCOCK Variable", "Babcock Variable", "Babcock"]),
                             ("text", ["N27 Variable", "N27"])] {
            if let name = names.first(where: installed.contains) { found[key] = name }
        }
        return found
    }()

    /// Guarded by `lock`.
    nonisolated(unsafe) private static var cache: [String: NSFont] = [:]
    private static let lock = NSLock()

    /// `weight` on the fonts' own 100–700 scale.
    static func ns(_ key: String, _ size: CGFloat, _ weight: CGFloat) -> NSFont {
        let id = "\(key) \(size) \(weight)"
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[id] { return hit }
        let font = make(key, size, weight)
        cache[id] = font
        return font
    }

    private static func make(_ key: String, _ size: CGFloat, _ weight: CGFloat) -> NSFont {
        if let family = families[key] {
            let wght = NSNumber(value: 0x7767_6874)   // the 'wght' variation axis
            let descriptor = NSFontDescriptor(fontAttributes: [
                .family: family,
                .variation: [wght: NSNumber(value: Double(weight))],
            ])
            if let font = NSFont(descriptor: descriptor, size: size) { return font }
        }
        // Without the brand fonts: the system's condensed width, close to their proportions.
        let system: NSFont.Weight = switch weight {
        case ..<250: .light
        case ..<450: .regular
        case ..<550: .medium
        case ..<650: .semibold
        default: .bold
        }
        return NSFont.systemFont(ofSize: size, weight: system, width: .condensed)
    }

    /// N27: everything you read or press.
    static func text(_ size: CGFloat, _ weight: CGFloat = 400) -> NSFont { ns("text", size, weight) }
    /// Babcock: titles and numbers, 24 pt and up, at 600–700.
    static func display(_ size: CGFloat, _ weight: CGFloat = 700) -> NSFont { ns("display", size, weight) }
}

extension Font {
    /// `title-2`: the welcome's title.
    static let dsTitle2 = Font(DSFont.display(32, 700))
    /// `title-3`: sheet titles, a sound's or song's name, tempo and key.
    static let dsTitle3 = Font(DSFont.display(24, 600))
    /// `body`.
    static let dsBody = Font(DSFont.text(15, 400))
    /// `body-sm`: most of the window.
    static let dsBodySm = Font(DSFont.text(14, 400))
    /// `label`: buttons, chips and the names of things.
    static let dsLabel = Font(DSFont.text(14, 500))
    /// A heading inside a panel: the label, a step stronger.
    static let dsHeading = Font(DSFont.text(15, 600))
    /// `caption`: metadata.
    static let dsCaption = Font(DSFont.text(12, 400))
    /// `overline`: eyebrows, uppercase with wide tracking (`overlineStyle`).
    static let dsOverline = Font(DSFont.text(12, 600))
}

extension View {
    /// The window's ground, the toolbar's strip too: the AppKit window's own colour.
    func dsWindowBackground() -> some View {
        background(WindowGround())
    }

    /// An eyebrow: uppercase, the system's wide tracking (0.12 em), muted.
    func overlineStyle() -> some View {
        font(.dsOverline).tracking(1.44).textCase(.uppercase).foregroundStyle(.dsInkMuted)
    }
}

// MARK: controls

/// The system's pill buttons. One `primary` per screen (red); `secondary` is ink; `ghost` an outline.
struct DSButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost }
    var kind: Kind
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.dsLabel)
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, kind == .ghost ? 14 : 18)
            .frame(minHeight: 30)
            .background {
                switch kind {
                case .primary: Capsule().fill(Color.dsAccent).shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                case .secondary: Capsule().fill(Color.dsInk)
                case .ghost: Capsule().strokeBorder(Color.dsInk.opacity(0.45), lineWidth: 1)
                }
            }
            .contentShape(Capsule())
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.2), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch kind {
        case .primary: .white
        case .secondary: .dsOnInk
        case .ghost: .dsInk
        }
    }
}

extension ButtonStyle where Self == DSButtonStyle {
    static var dsPrimary: DSButtonStyle { DSButtonStyle(kind: .primary) }
    static var dsSecondary: DSButtonStyle { DSButtonStyle(kind: .secondary) }
    static var dsGhost: DSButtonStyle { DSButtonStyle(kind: .ghost) }
}

/// A text action inside a panel: ink, underlined (no link blue; the system has no other hue).
struct DSLinkStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.dsInk)
            .underline(true, color: Color.dsInk.opacity(0.4))
            .opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == DSLinkStyle {
    static var dsLink: DSLinkStyle { DSLinkStyle() }
}

/// A chip: a pill that filters or picks; the chosen one fills with ink, the others are outlines.
struct DSChip: View {
    let title: String
    let chosen: Bool
    var height: CGFloat = 28
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.dsLabel)
                .foregroundStyle(chosen ? Color.dsOnInk : Color.dsInk)
                .padding(.horizontal, 14)
                .frame(height: height)
                .background {
                    if chosen {
                        Capsule().fill(Color.dsInk)
                    } else {
                        Capsule().strokeBorder(Color.dsLine, lineWidth: 1)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// Sets its window's background to the design system's ground.
private struct WindowGround: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { GroundView() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class GroundView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.backgroundColor = .dsBackground
        }
    }
}

/// A list row's selection: faint ink, rounded, the text staying ink (no white-on-colour).
final class DSRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("dsRow")

    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        NSColor.dsSelection.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 8, yRadius: 8).fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}
