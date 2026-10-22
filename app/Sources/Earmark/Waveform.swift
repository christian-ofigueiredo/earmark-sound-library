import Accelerate
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

/// Waveform with a playhead. Click to play from a point; drag to select a range.
struct WaveformView: View {
    let peaks: [Float]?
    let playhead: Double?
    @Binding var selection: ClosedRange<Double>?
    let onClick: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            Canvas { ctx, size in
                if let sel = selection {
                    let rect = CGRect(x: sel.lowerBound * size.width, y: 0,
                                      width: max((sel.upperBound - sel.lowerBound) * size.width, 1), height: size.height)
                    ctx.fill(Path(rect), with: .color(Color.accentColor.opacity(0.22)))
                }
                if let peaks, !peaks.isEmpty {
                    let mid = size.height / 2
                    let step = size.width / CGFloat(peaks.count)
                    var bars = Path()
                    for (i, p) in peaks.enumerated() {
                        let h = max(0.5, CGFloat(min(p, 1)) * (mid - 2))
                        bars.addRect(CGRect(x: CGFloat(i) * step, y: mid - h, width: max(step, 0.75), height: h * 2))
                    }
                    ctx.fill(bars, with: .color(Color.primary.opacity(0.6)))
                }
                if let playhead, playhead.isFinite {
                    let x = min(max(playhead, 0), 1) * size.width
                    ctx.fill(Path(CGRect(x: x - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(Color.accentColor))
                }
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard abs(value.translation.width) > 3 else { return }
                        let a = clamp(value.startLocation.x / width), b = clamp(value.location.x / width)
                        selection = min(a, b) ... max(a, b)
                    }
                    .onEnded { value in
                        if abs(value.translation.width) <= 3 {
                            selection = nil
                            onClick(clamp(value.location.x / width))
                        }
                    }
            )
        }
    }

    private func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
}
