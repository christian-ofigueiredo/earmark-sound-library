import Accelerate
import AppKit
import AVFoundation
import SwiftUI

struct WaveformData: Sendable {
    /// Peak level per column, scaled so the loudest is 1.
    let peaks: [Float]
    let duration: Double
}

enum Waveform {
    /// Reads the file (read-only) and returns its peaks; cancelled with the calling task.
    static func load(_ url: URL, columns: Int = 800) async -> WaveformData? {
        let task = Task.detached(priority: .userInitiated) { compute(url, columns: columns) }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func compute(_ url: URL, columns: Int) -> WaveformData? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let total = file.length
        guard total > 0, format.sampleRate > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_768) else { return nil }
        let cols = Int64(columns)
        var peaks = [Float](repeating: 0, count: columns)
        var position: Int64 = 0
        while position < total {
            if Task.isCancelled { return nil }
            do { try file.read(into: buffer) } catch { break }
            let n = Int(buffer.frameLength)
            guard n > 0, let data = buffer.floatChannelData else { break }
            var i = 0
            while i < n {
                // Frames of column b are those where floor(frame * cols / total) == b.
                let b = Int(min((position + Int64(i)) * cols / total, cols - 1))
                let columnEnd = (Int64(b + 1) * total + cols - 1) / cols
                let end = min(n, max(Int(columnEnd - position), i + 1))
                var peak = peaks[b]
                for c in 0 ..< Int(format.channelCount) {
                    var m: Float = 0
                    vDSP_maxmgv(data[c] + i, 1, &m, vDSP_Length(end - i))
                    peak = max(peak, m)
                }
                peaks[b] = peak
                i = end
            }
            position += Int64(n)
        }
        if let top = peaks.max(), top > 0 { peaks = peaks.map { $0 / top } }
        return WaveformData(peaks: peaks, duration: Double(total) / format.sampleRate)
    }
}

/// Waveform with a playhead, drawn and handled in AppKit so clicks work while it redraws
/// during playback and on the first click into an inactive window.
///   click: move the playhead there · drag the playhead: scrub · drag elsewhere: select a range
struct WaveformView: NSViewRepresentable {
    let peaks: [Float]?
    /// The window is active: in an inactive one the accent colours turn grey, as the system's do.
    var active = true
    /// 0…1, or nil when this file isn't loaded in the player.
    let playhead: Double?
    @Binding var selection: ClosedRange<Double>?
    /// Click at a point (0…1).
    let onClick: (Double) -> Void
    /// The playhead dragged to a point; `ended` on mouse up.
    let onScrub: (Double, _ ended: Bool) -> Void

    func makeNSView(context: Context) -> WaveformCanvas { WaveformCanvas() }

    func updateNSView(_ view: WaveformCanvas, context: Context) {
        view.passesClicks = !context.environment.sectionShown
        view.peaks = peaks
        view.active = active
        view.playhead = playhead
        view.selection = selection
        view.onClick = onClick
        view.onScrub = onScrub
        view.onSelect = { selection = $0 }
    }
}

final class WaveformCanvas: NSView {
    var peaks: [Float]? { didSet { if oldValue != peaks { needsDisplay = true } } }
    var active = true { didSet { if oldValue != active { needsDisplay = true } } }
    /// In the hidden section's detail pane (kept built under the shown one): clicks go through.
    var passesClicks = false

    override func hitTest(_ point: NSPoint) -> NSView? { passesClicks ? nil : super.hitTest(point) }
    var playhead: Double? { didSet { if oldValue != playhead { needsDisplay = true } } }
    var selection: ClosedRange<Double>? { didSet { if oldValue != selection { needsDisplay = true } } }
    var onClick: (Double) -> Void = { _ in }
    var onScrub: (Double, Bool) -> Void = { _, _ in }
    var onSelect: (ClosedRange<Double>?) -> Void = { _ in }

    private enum Drag { case pending(x: CGFloat), selecting(from: CGFloat), scrubbing }
    private var drag: Drag?
    /// Last position seen while dragging (a scrub ends there, whatever mouse-up reports).
    private var lastX: CGFloat = 0
    /// How close (points) to the playhead a press must be to grab it.
    private let grab: CGFloat = 6

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func fraction(_ x: CGFloat) -> Double { min(max(Double(x / max(bounds.width, 1)), 0), 1) }
    private func location(_ event: NSEvent) -> CGFloat { convert(event.locationInWindow, from: nil).x }

    override func mouseDown(with event: NSEvent) {
        let x = location(event)
        lastX = x
        if let playhead, abs(CGFloat(playhead) * bounds.width - x) <= grab {
            drag = .scrubbing
        } else {
            drag = .pending(x: x)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let x = location(event)
        lastX = x
        switch drag {
        case .scrubbing:
            onScrub(fraction(x), false)
        case .pending(let start) where abs(x - start) > 3, .selecting(let start):
            drag = .selecting(from: start)
            let a = fraction(start), b = fraction(x)
            onSelect(min(a, b) ... max(a, b))
        default:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        let x = location(event)
        switch drag {
        case .scrubbing: onScrub(fraction(lastX), true)
        case .pending: onClick(fraction(x))
        default: break
        }
        drag = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        // The app's blue (SwiftUI's .tint(.blue) doesn't reach AppKit drawing); grey when inactive.
        let accent = active ? NSColor.systemBlue : NSColor.secondaryLabelColor
        NSColor.labelColor.withAlphaComponent(0.05).setFill()
        NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
        if let sel = selection {
            accent.withAlphaComponent(0.22).setFill()
            NSRect(x: sel.lowerBound * r.width, y: 0, width: max((sel.upperBound - sel.lowerBound) * r.width, 1), height: r.height).fill()
        }
        if let peaks, !peaks.isEmpty {
            (active ? NSColor.systemBlue.withAlphaComponent(0.75) : NSColor.labelColor.withAlphaComponent(0.4)).setFill()
            let mid = r.height / 2, step = r.width / CGFloat(peaks.count)
            for (i, p) in peaks.enumerated() {
                let h = max(0.5, CGFloat(min(p, 1)) * (mid - 2))
                NSRect(x: CGFloat(i) * step, y: mid - h, width: max(step, 0.75), height: h * 2).fill()
            }
        }
        if let playhead, playhead.isFinite {
            let x = CGFloat(min(max(playhead, 0), 1)) * r.width
            // The playhead in the text colour, to stand out on the blue waveform.
            NSColor.labelColor.setFill()
            NSRect(x: x - 0.75, y: 0, width: 1.5, height: r.height).fill()
            // A small handle at the top shows the playhead can be dragged.
            let handle = NSBezierPath()
            handle.move(to: NSPoint(x: x - 5, y: 0))
            handle.line(to: NSPoint(x: x + 5, y: 0))
            handle.line(to: NSPoint(x: x, y: 6))
            handle.close()
            handle.fill()
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }
}
