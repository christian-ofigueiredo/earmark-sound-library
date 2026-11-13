import AppKit
import SwiftUI

// The owner's design system (~/Documents/Design System/workspace/ds/project: tokens.css, README;
// Offload is its reference in an app), the parts Earmark uses. Six colours exist, everything else
// is one of them at an opacity. The ground and the panels are the same colour: depth comes from
// light and shadow. Red is one signal per view: what's playing and the key that plays it. The
// type is Babcock (titles and numbers, 24 pt and up) and N27 (everything else). Their licences
// don't allow putting them in an app, so Earmark uses them only where they're installed, and the
// system's condensed font elsewhere.

// MARK: colour

extension NSColor {
    private static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }

    /// A token with its light and dark values (tokens.css).
    private static func token(_ name: String, light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: NSColor.Name(name)) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    static let dsEbony = rgb(0x040404)
    static let dsShark = rgb(0x131314)
    static let dsSeashell = rgb(0xF1F1F1)

    /// The window's ground and its panels, one colour: Seashell, Shark.
    static let dsBackground = token("dsBackground", light: dsSeashell, dark: dsShark)
    static let dsSurface = dsBackground
    /// Sunken wells and pressed keys.
    static let dsSunken = token("dsSunken", light: rgb(0x040404, 0.06), dark: rgb(0x040404, 0.42))
    /// Decoration only: rules.
    static let dsLine = token("dsLine", light: rgb(0x040404, 0.14), dark: rgb(0xF1F1F1, 0.12))
    /// Printed outlines.
    static let dsLinePrint = token("dsLinePrint", light: rgb(0x040404, 0.32), dark: rgb(0xF1F1F1, 0.3))
    static let dsInk = token("dsInk", light: dsEbony, dark: dsSeashell)
    /// Labels printed on the body.
    static let dsInkPrint = token("dsInkPrint", light: rgb(0x040404, 0.78), dark: rgb(0xF1F1F1, 0.78))
    static let dsInkMuted = token("dsInkMuted", light: rgb(0x040404, 0.62), dark: rgb(0xF1F1F1, 0.62))
    /// The one red: Ruby Red on light grounds, Milano Red on dark. What's on it is always light.
    static let dsAccent = token("dsAccent", light: rgb(0xA00A00), dark: rgb(0xD41101))
    /// What's selected in a list: ink, faint. (Red stays for what's playing.)
    static let dsSelection = token("dsSelection", light: rgb(0x040404, 0.09), dark: rgb(0xF1F1F1, 0.12))
}

extension Color {
    static let dsBackground = Color(nsColor: .dsBackground)
    static let dsSurface = Color(nsColor: .dsSurface)
    static let dsSunken = Color(nsColor: .dsSunken)
    static let dsLine = Color(nsColor: .dsLine)
    static let dsLinePrint = Color(nsColor: .dsLinePrint)
    static let dsInk = Color(nsColor: .dsInk)
    static let dsInkPrint = Color(nsColor: .dsInkPrint)
    static let dsInkMuted = Color(nsColor: .dsInkMuted)
    static let dsAccent = Color(nsColor: .dsAccent)
    static let dsSelection = Color(nsColor: .dsSelection)
    static let dsSeashell = Color(nsColor: .dsSeashell)
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
    static let dsOverline = Font(DSFont.text(12, 500))
}

extension View {
    /// A sheet on the window's ground, in the app's type.
    func dsSheet() -> some View {
        font(.dsBodySm).tint(.dsInk).presentationBackground(Color.dsBackground)
    }

    /// The window's ground, the toolbar's strip too: the AppKit window's own colour.
    func dsWindowBackground() -> some View {
        background(WindowGround())
    }

    /// A printed label: uppercase, tracked wide (0.16 em).
    func overlineStyle() -> some View {
        font(.dsOverline).tracking(1.9).textCase(.uppercase).foregroundStyle(Color.dsInkPrint)
    }

    /// Raised like a real key on a flat surface: a soft light from the top left, a shadow below.
    func keyShadow(_ scale: CGFloat = 1) -> some View {
        modifier(KeyShadow(scale: scale))
    }
}

// MARK: controls

private struct KeyShadow: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let scale: CGFloat

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        content
            .shadow(color: .white.opacity(dark ? 0.06 : 0.9), radius: 6 * scale, x: -2 * scale, y: -2 * scale)
            .shadow(color: .black.opacity(dark ? 0.55 : 0.14), radius: 8 * scale, x: 3 * scale, y: 4 * scale)
    }
}

/// Rim light: strongest on the top edge, faint all the way round.
struct RimLight: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let top: Double = scheme == .dark ? 0.2 : 0.9
        Capsule().strokeBorder(
            LinearGradient(colors: [.white.opacity(top), .white.opacity(0.055), .white.opacity(0.03)],
                           startPoint: .top, endPoint: .bottom), lineWidth: 1)
    }
}

/// The system's keys. One `primary` per view: a soft, almost flat red, what's on it always light.
/// `key` is strong but not red: the body's own material, raised. `ghost` (quiet) is a printed outline.
struct DSButtonStyle: ButtonStyle {
    enum Kind { case primary, key, ghost }
    var kind: Kind
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(.dsLabel)
            .lineLimit(1)
            .foregroundStyle(kind == .primary ? Color.dsSeashell : kind == .key ? Color.dsInk : Color.dsInkPrint)
            .padding(.horizontal, kind == .ghost ? 14 : 18)
            .frame(minHeight: 30)
            .background {
                switch kind {
                case .primary:
                    Capsule().fill(Color.dsAccent)
                        .overlay(Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .clear, .black.opacity(0.1)],
                                                                       startPoint: .top, endPoint: .bottom), lineWidth: 1))
                        .shadow(color: .black.opacity(0.3), radius: 8, x: 3, y: 4)
                case .key:
                    Capsule().fill(pressed ? Color.dsSunken : Color.dsBackground).keyShadow(pressed ? 0.2 : 0.7)
                        .overlay(RimLight())
                case .ghost:
                    Capsule().strokeBorder(Color.dsLinePrint, lineWidth: 1)
                }
            }
            .contentShape(Capsule())
            .opacity(enabled ? (pressed && kind != .key ? 0.7 : 1) : 0.4)
            .scaleEffect(pressed && kind == .primary ? 0.98 : 1)
            .animation(.easeOut(duration: 0.2), value: pressed)
    }
}

extension ButtonStyle where Self == DSButtonStyle {
    static var dsPrimary: DSButtonStyle { DSButtonStyle(kind: .primary) }
    static var dsKey: DSButtonStyle { DSButtonStyle(kind: .key) }
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

/// A chip: a small key for filters and one-of-many choices; the pressed one sinks in and lights
/// its LED.
struct DSChip: View {
    let title: String
    let chosen: Bool
    var height: CGFloat = 28
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Circle().fill(chosen ? Color.dsInk : Color.dsInk.opacity(0.16)).frame(width: 5, height: 5)
                    .shadow(color: chosen ? Color.dsInk.opacity(0.7) : .clear, radius: 3)
                Text(title).font(.dsLabel).foregroundStyle(chosen ? Color.dsInk : Color.dsInkMuted).lineLimit(1).fixedSize()
            }
            .padding(.horizontal, 13)
            .frame(height: height)
            .background {
                if chosen {
                    Capsule().fill(Color.dsSunken)
                        .overlay(Capsule().strokeBorder(.black.opacity(0.4), lineWidth: 1).blur(radius: 1.5).offset(y: 1).clipShape(Capsule()))
                } else {
                    Capsule().fill(Color.dsBackground).keyShadow(0.5)
                }
            }
            .overlay(RimLight().opacity(chosen ? 0.35 : 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// A SwiftUI table's column title in the main lists' look (a printed label: uppercase, tracked,
/// muted).
func dsColumnTitle(_ title: String) -> Text {
    Text(title.uppercased()).font(Font(DSFont.text(11, 600))).kerning(1.2).foregroundStyle(Color.dsInkMuted)
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
