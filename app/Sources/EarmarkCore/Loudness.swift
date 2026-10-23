import Foundation

/// Integrated loudness (ITU-R BS.1770-4 / EBU R128, LUFS) and sample peak (dBFS),
/// fed with decoded audio in chunks so long files are never held in memory.
public struct LoudnessMeter: Sendable {
    public struct Result: Sendable, Equatable, Codable {
        /// Integrated loudness in LUFS; nil for digital silence (everything below the -70 LUFS gate).
        public var integrated: Double?
        /// Highest sample in dBFS (not oversampled true peak); nil for digital silence.
        public var peak: Double?
    }

    /// K-weighting: a high shelf then a high pass, per channel (biquad, direct form I).
    struct Biquad: Sendable {
        var b0, b1, b2, a1, a2: Double
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

        mutating func run(_ x: Double) -> Double {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            return y
        }
    }

    /// Coefficients for any sample rate (the same derivation as libebur128).
    static func kWeighting(sampleRate fs: Double) -> (Biquad, Biquad) {
        var f0 = 1681.974450955533, q = 0.7071752369554196
        let gain = 3.999843853973347
        var k = tan(Double.pi * f0 / fs)
        let vh = pow(10, gain / 20), vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / q + k * k
        let shelf = Biquad(b0: (vh + vb * k / q + k * k) / a0, b1: 2 * (k * k - vh) / a0,
                           b2: (vh - vb * k / q + k * k) / a0, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        f0 = 38.13547087602444; q = 0.5003270373238773
        k = tan(Double.pi * f0 / fs)
        a0 = 1 + k / q + k * k
        let highPass = Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        return (shelf, highPass)
    }

    public let sampleRate: Double
    public let channels: Int
    private var filters: [(Biquad, Biquad)]
    private let weights: [Double]
    /// Frames per 100 ms step; blocks are 4 steps (400 ms) with 75% overlap.
    private let stepFrames: Int
    private var stepFill = 0
    private var stepEnergy: [Double]
    /// Channel-weighted mean square of each completed 100 ms step.
    private var steps: [Double] = []
    private var totalFrames = 0
    private var totalEnergy = 0.0
    private var peakSample: Float = 0

    public init(sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        let count = max(1, channels)
        self.channels = count
        filters = Array(repeating: Self.kWeighting(sampleRate: sampleRate), count: count)
        // 5.1 in WAV order (L R C LFE Ls Rs): LFE ignored, surrounds +1.5 dB.
        weights = (0 ..< count).map { c in
            guard count == 6 else { return 1 }
            return c == 3 ? 0 : c >= 4 ? 1.41 : 1
        }
        stepFrames = max(1, Int((sampleRate / 10).rounded()))
        stepEnergy = Array(repeating: 0, count: self.channels)
    }

    /// Feeds `frames` frames of deinterleaved float audio, one buffer per channel.
    public mutating func process(_ buffers: [UnsafeBufferPointer<Float>], frames: Int) {
        guard buffers.count >= channels else { return }
        var start = 0
        while start < frames {
            let n = min(frames - start, stepFrames - stepFill)
            for c in 0 ..< channels {
                let input = buffers[c]
                var (shelf, highPass) = filters[c]
                var sum = 0.0
                var peak = peakSample
                for i in start ..< start + n {
                    let x = input[i]
                    peak = max(peak, abs(x))
                    let y = highPass.run(shelf.run(Double(x)))
                    sum += y * y
                }
                filters[c] = (shelf, highPass)
                peakSample = peak
                stepEnergy[c] += sum
            }
            stepFill += n
            totalFrames += n
            start += n
            if stepFill == stepFrames { closeStep() }
        }
    }

    /// Convenience for tests and small buffers.
    public mutating func process(_ channelData: [[Float]]) {
        let frames = channelData.map(\.count).min() ?? 0
        var pointers: [UnsafeBufferPointer<Float>] = []
        func feed(_ i: Int) {
            if i == channelData.count { process(pointers, frames: frames); return }
            channelData[i].withUnsafeBufferPointer { p in pointers.append(p); feed(i + 1); pointers.removeLast() }
        }
        feed(0)
    }

    private mutating func closeStep() {
        var weighted = 0.0
        for c in 0 ..< channels { weighted += weights[c] * stepEnergy[c] }
        steps.append(weighted / Double(stepFrames))
        totalEnergy += weighted
        stepEnergy = Array(repeating: 0, count: channels)
        stepFill = 0
    }

    static func lufs(_ meanSquare: Double) -> Double { -0.691 + 10 * log10(meanSquare) }

    public var result: Result {
        let peak: Double? = peakSample > 0 ? 20 * log10(Double(peakSample)) : nil
        var blocks: [Double] = []
        if steps.count >= 4 {
            blocks = (0 ... steps.count - 4).map { i in (steps[i] + steps[i + 1] + steps[i + 2] + steps[i + 3]) / 4 }
        } else if totalFrames > 0 {
            // Shorter than one 400 ms block (short effects): measure the whole sound as one block.
            var weighted = totalEnergy
            for c in 0 ..< channels { weighted += weights[c] * stepEnergy[c] }
            blocks = [weighted / Double(totalFrames)]
        }
        let absoluteGate = blocks.filter { $0 > 0 && Self.lufs($0) > -70 }
        guard !absoluteGate.isEmpty else { return Result(integrated: nil, peak: peak) }
        let relativeThreshold = Self.lufs(absoluteGate.reduce(0, +) / Double(absoluteGate.count)) - 10
        let gated = absoluteGate.filter { Self.lufs($0) > relativeThreshold }
        return Result(integrated: Self.lufs(gated.reduce(0, +) / Double(gated.count)), peak: peak)
    }
}
