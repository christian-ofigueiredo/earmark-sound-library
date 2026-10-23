import Foundation

/// Phase 0's audio preparation, shared by the embedding models so the app's
/// vectors match the ones Phase 0 measured: mono 48 kHz (at most the first 10
/// minutes) → trim silence (-60 dB) → peak-normalise to 0.9 → up to six evenly
/// spread 10 s windows, each embedded on its own.
public enum Phase0Audio {
    public static let sampleRate = 48_000
    public static let windowSamples = 480_000
    public static let maxWindows = 6
    /// Phase 0 decodes at most the first 10 minutes of a file.
    public static let maxSeconds = 600.0

    /// Trimmed and peak-normalised audio, or nil if silent or shorter than 20 ms.
    public static func prepare(_ x: [Float]) -> [Float]? {
        let trimmed = trimSilence(x)
        guard trimmed.count >= Int(0.02 * Double(sampleRate)),
              let peak = trimmed.lazy.map(abs).max(), peak >= 1e-6 else { return nil }
        return peakNormalize(trimmed)
    }

    /// Cuts leading and trailing parts quieter than -60 dB relative to the peak (5 ms frames, 10 ms padding).
    static func trimSilence(_ x: [Float], thresholdDB: Double = -60, padSeconds: Double = 0.01) -> [Float] {
        guard let peak = x.lazy.map(abs).max(), peak > 0 else { return x }
        let hop = max(1, Int(Double(sampleRate) * 0.005))
        let n = x.count / hop
        guard n >= 2 else { return x }
        let threshold = peak * Float(pow(10, thresholdDB / 20))
        var first: Int?, last = 0
        for f in 0 ..< n {
            var m: Float = 0
            for i in f * hop ..< (f + 1) * hop { m = max(m, abs(x[i])) }
            if m >= threshold { if first == nil { first = f }; last = f }
        }
        guard let first else { return x }
        let pad = Int(padSeconds * Double(sampleRate))
        return Array(x[max(0, first * hop - pad) ..< min(x.count, (last + 1) * hop + pad)])
    }

    static func peakNormalize(_ x: [Float], target: Float = 0.9) -> [Float] {
        guard let peak = x.lazy.map(abs).max(), peak > 1e-9 else { return x }
        let gain = target / peak
        return x.map { $0 * gain }
    }

    /// Up to six evenly spread 10 s windows, skipping near-silent ones; short audio comes back whole.
    public static func windows(_ x: [Float]) -> [[Float]] {
        let win = windowSamples
        guard x.count > win else { return [x] }
        let count = min(maxWindows, Int((Double(x.count) / Double(win)).rounded(.up)))
        let span = Double(x.count - win)
        // numpy.linspace: start + i * step, with the last point exactly at the end.
        let starts = (0 ..< count).map { i in i == count - 1 ? x.count - win : Int(Double(i) * (span / Double(count - 1))) }
        let windows = starts.map { Array(x[$0 ..< $0 + win]) }
        let rms = windows.map { w in (w.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(w.count)).squareRoot() }
        let loudest = rms.max() ?? 0
        let kept = zip(windows, rms).filter { $0.1 >= 0.05 * loudest }.map(\.0)
        return kept.isEmpty ? windows : kept
    }
}

/// PE-AV's input: the window itself, reflect-padded at the end to a multiple of
/// 1920 samples (PeAudioFeatureExtractor), as numpy's "reflect" pads.
public enum PeavAudio {
    public static let hop = 1920

    public static func input(_ window: [Float]) -> [Float] {
        let n = window.count
        guard n > 1, n % hop != 0 else { return window }
        let pad = hop - n % hop
        // numpy "reflect" keeps mirroring for long pads: a periodic mirror of period 2(n-1).
        let period = 2 * (n - 1)
        var out = window
        out.reserveCapacity(n + pad)
        for j in 0 ..< pad {
            var m = (n - 1 + j + 1) % period
            if m >= n { m = period - m }
            out.append(window[m])
        }
        return out
    }
}

/// CLAP's log-mel features (see models/parity_clap.py), on Phase 0's windows.
public enum ClapAudio {
    public static let frames = 1001, mels = 64
    static let nFFT = 1024, hop = 480
    static let sampleRate = Phase0Audio.sampleRate
    static let windowSamples = Phase0Audio.windowSamples

    // MARK: CLAP's feature extractor ("repeatpad", Slaney mel, dB)

    /// Log-mel features of one ≤10 s window: `frames` × `mels` values, row-major, as the model's input.
    public static func features(_ window: [Float]) -> [Float] {
        var x = window
        if x.count < windowSamples, !x.isEmpty {
            let repeats = windowSamples / x.count
            x = Array([[Float]](repeating: x, count: repeats).joined())
            x += [Float](repeating: 0, count: windowSamples - x.count)
        } else if x.count > windowSamples {
            x = Array(x.prefix(windowSamples))
        }
        // Centre the frames: reflect-pad nFFT/2 on both sides (numpy "reflect" excludes the edge sample).
        let pad = nFFT / 2
        var padded = [Double](repeating: 0, count: x.count + 2 * pad)
        for i in 0 ..< x.count { padded[pad + i] = Double(x[i]) }
        for i in 0 ..< pad {
            padded[pad - 1 - i] = Double(x[i + 1])
            padded[pad + x.count + i] = Double(x[x.count - 2 - i])
        }
        let fft = Self.fft
        let filters = Self.melFilters
        var out = [Float](repeating: 0, count: frames * mels)
        var re = [Double](repeating: 0, count: nFFT), im = [Double](repeating: 0, count: nFFT)
        var power = [Double](repeating: 0, count: nFFT / 2 + 1)
        for f in 0 ..< frames {
            let start = f * hop
            for i in 0 ..< nFFT { re[i] = padded[start + i] * hann[i]; im[i] = 0 }
            fft.transform(&re, &im)
            for k in 0 ... nFFT / 2 {
                // Stored as complex64 in transformers before taking the magnitude.
                let r = Double(Float(re[k])), j = Double(Float(im[k]))
                power[k] = r * r + j * j
            }
            for m in 0 ..< mels {
                let band = filters[m]
                var sum = 0.0
                for (k, w) in zip(band.range, band.weights) { sum += w * power[k] }
                out[f * mels + m] = Float(10 * log10(max(1e-10, sum)))
            }
        }
        return out
    }

    /// Periodic Hann window.
    static let hann: [Double] = (0 ..< nFFT).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(nFFT)) }

    struct Band { var range: Range<Int>; var weights: [Double] }

    /// transformers.mel_filter_bank(norm="slaney", mel_scale="slaney"), stored per band as its nonzero range.
    static let melFilters: [Band] = {
        func toMel(_ hz: Double) -> Double {
            hz >= 1000 ? 15 + log(hz / 1000) * (27 / log(6.4)) : 3 * hz / 200
        }
        func toHz(_ mel: Double) -> Double {
            mel >= 15 ? 1000 * exp(log(6.4) / 27 * (mel - 15)) : 200 * mel / 3
        }
        let bins = nFFT / 2 + 1
        let lo = toMel(50), hi = toMel(14000)
        let melPoints = (0 ..< mels + 2).map { i in i == mels + 1 ? hi : lo + Double(i) * ((hi - lo) / Double(mels + 1)) }
        let edges = melPoints.map(toHz)
        let nyquist = Double(sampleRate / 2)
        let fftFreqs = (0 ..< bins).map { i in i == bins - 1 ? nyquist : Double(i) * (nyquist / Double(bins - 1)) }
        return (0 ..< mels).map { m in
            let enorm = 2 / (edges[m + 2] - edges[m])
            let weights = fftFreqs.map { f -> Double in
                let down = (f - edges[m]) / (edges[m + 1] - edges[m])
                let up = (edges[m + 2] - f) / (edges[m + 2] - edges[m + 1])
                return max(0, min(down, up)) * enorm
            }
            let first = weights.firstIndex { $0 > 0 } ?? 0
            let last = weights.lastIndex { $0 > 0 } ?? 0
            return Band(range: first ..< last + 1, weights: Array(weights[first ... last]))
        }
    }()

    static let fft = RadixTwoFFT(size: nFFT)
}

/// In-place iterative radix-2 complex FFT (forward, no scaling), in double precision.
struct RadixTwoFFT: Sendable {
    let size: Int
    private let cosTable: [Double], sinTable: [Double]
    private let reversed: [Int]

    init(size: Int) {
        precondition(size > 1 && size & (size - 1) == 0, "size must be a power of two")
        self.size = size
        cosTable = (0 ..< size / 2).map { cos(-2 * Double.pi * Double($0) / Double(size)) }
        sinTable = (0 ..< size / 2).map { sin(-2 * Double.pi * Double($0) / Double(size)) }
        let bits = size.trailingZeroBitCount
        reversed = (0 ..< size).map { i in
            var r = 0, v = i
            for _ in 0 ..< bits { r = (r << 1) | (v & 1); v >>= 1 }
            return r
        }
    }

    func transform(_ re: inout [Double], _ im: inout [Double]) {
        for i in 0 ..< size where i < reversed[i] {
            re.swapAt(i, reversed[i]); im.swapAt(i, reversed[i])
        }
        var len = 2
        while len <= size {
            let half = len / 2, step = size / len
            var start = 0
            while start < size {
                for k in 0 ..< half {
                    let c = cosTable[k * step], s = sinTable[k * step]
                    let a = start + k, b = a + half
                    let tr = re[b] * c - im[b] * s, ti = re[b] * s + im[b] * c
                    re[b] = re[a] - tr; im[b] = im[a] - ti
                    re[a] += tr; im[a] += ti
                }
                start += len
            }
            len <<= 1
        }
    }
}
