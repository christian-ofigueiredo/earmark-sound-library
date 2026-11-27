import AppKit

/// Check runs only: `EARMARK_ORIGIN=x,y` (Cocoa points, the window's top-left corner, e.g. from
/// `mac-screen --cocoa`) opens the app's windows there, so a window opened for a check lands on
/// the Mac's built-in display rather than the screens the owner works on, and the app doesn't take
/// the keyboard. Windows stop saving their frame for that run, so the position the owner left them
/// in is kept. Without the variable nothing here does anything. (The unit tests have no app host,
/// so there is no `TEST_RUNNER_` form.)
@MainActor
enum CheckPlacement {
    static let origin: CGPoint? = {
        guard let parts = ProcessInfo.processInfo.environment["EARMARK_ORIGIN"]?.split(separator: ","),
              parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else { return nil }
        return CGPoint(x: x, y: y)
    }()

    private static var placed = Set<ObjectIdentifier>()

    /// Watches for windows from launch on and moves each one the first time it is seen, before
    /// the run loop draws it.
    static func start() {
        guard origin != nil else { return }
        for name in [NSApplication.didUpdateNotification, NSWindow.didUpdateNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
                MainActor.assumeIsolated { apply() }
            }
        }
    }

    static func apply() {
        guard let origin else { return }
        for window in NSApp.windows where !placed.contains(ObjectIdentifier(window)) {
            guard window.frame.width > 300 else { continue }   // not menus, panels or tooltips
            placed.insert(ObjectIdentifier(window))
            window.setFrameAutosaveName("")
            window.isRestorable = false
            window.setFrameTopLeftPoint(origin)
        }
    }

    static var active: Bool { origin != nil }
}
