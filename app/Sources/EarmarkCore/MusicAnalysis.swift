import Foundation

/// Beat This!'s input and chunking (beat_this 1.1.0, as Phase 0 ran it): mono 22.05 kHz →
/// |STFT| (1024-point periodic Hann, hop 441, centred with reflect padding, scaled by
/// 1/√1024) → 128 Slaney-scale mel bands from 30 Hz to 11 kHz (unnormalised triangles) →
/// log(1 + 1000·x). 50 frames a second, cut into 30 s chunks for the model.
public enum BeatThisAudio {
    public static let sampleRate = 22_050
    public static let fps = 50
    public static let mels = 128
    /// Frames the model takes at a time, and how many at each end of a chunk it isn't trusted on.
    public static let chunk = 1500, border = 6
    /// Phase 0 analysed at most the first 20 minutes of a song.
    public static let maxSeconds = 1200.0
    static let nFFT = 1024, hop = 441

    public static func frameCount(samples: Int) -> Int { samples / hop + 1 }

    /// The log-mel spectrogram: `frameCount(samples:)` × `mels` values, row-major. Needs more than 512 samples.
    public static func spectrogram(_ x: [Float]) -> [Float] {
        let frames = frameCount(samples: x.count)
        let pad = nFFT / 2
        precondition(x.count > pad, "too short to reflect-pad")
        // torch.stft(center=True, pad_mode="reflect"): the mirror excludes the edge sample.
        var padded = [Double](repeating: 0, count: x.count + 2 * pad)
        for i in 0 ..< x.count { padded[pad + i] = Double(x[i]) }
        for i in 0 ..< pad {
            padded[pad - 1 - i] = Double(x[i + 1])
            padded[pad + x.count + i] = Double(x[x.count - 2 - i])
        }
        let fft = Self.fft, filters = Self.melFilters, window = Self.window
        let scale = 1 / Double(nFFT).squareRoot()   // normalized="frame_length"
        var out = [Float](repeating: 0, count: frames * mels)
        var re = [Double](repeating: 0, count: nFFT), im = [Double](repeating: 0, count: nFFT)
        var magnitude = [Double](repeating: 0, count: nFFT / 2 + 1)
        for f in 0 ..< frames {
            let start = f * hop
            for i in 0 ..< nFFT { re[i] = padded[start + i] * window[i]; im[i] = 0 }
            fft.transform(&re, &im)
            for k in 0 ... nFFT / 2 { magnitude[k] = (re[k] * re[k] + im[k] * im[k]).squareRoot() * scale }
            for m in 0 ..< mels {
                let band = filters[m]
                var sum = 0.0
                for (k, w) in zip(band.range, band.weights) { sum += w * magnitude[k] }
                out[f * mels + m] = Float(log1p(1000 * sum))
            }
        }
        return out
    }

    // MARK: chunks (beat_this.inference.split_piece / aggregate_prediction, "keep_first")

    /// Where each chunk starts, in frames: the first at -`border`, overlapping by 2·`border`,
    /// the last moved back to end with the song (`avoid_short_end`).
    public static func chunkStarts(frames n: Int) -> [Int] {
        var starts = Array(stride(from: -border, to: n - border, by: chunk - 2 * border))
        if n > chunk - 2 * border, !starts.isEmpty { starts[starts.count - 1] = n - (chunk - border) }
        return starts
    }

    /// One chunk of `chunk` frames starting at `start`, zero beyond the song. (Beat This! gives
    /// a song shorter than 30 s a shorter chunk; the converted model takes 1500 frames only,
    /// so here it gets silence after the end.)
    public static func chunk(_ spect: [Float], frames n: Int, start: Int) -> [Float] {
        var out = [Float](repeating: 0, count: chunk * mels)
        let first = max(start, 0), last = min(start + chunk, n)
        guard last > first else { return out }
        spect.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                let offset = (first - start) * mels
                for i in 0 ..< (last - first) * mels { dst[offset + i] = src[first * mels + i] }
            }
        }
        return out
    }

    /// The whole song's frames from each chunk's model output, dropping `border` frames at
    /// both ends of a chunk; where chunks overlap the earlier one wins. Frames no chunk covers stay at -1000.
    public static func aggregate(_ outputs: [[Float]], starts: [Int], frames n: Int) -> [Float] {
        var piece = [Float](repeating: -1000, count: n)
        for (start, output) in zip(starts, outputs).reversed() {
            for i in border ..< min(output.count, chunk) - border {
                let t = start + i
                if t >= 0, t < n { piece[t] = output[i] }
            }
        }
        return piece
    }

    struct Band { var range: Range<Int>; var weights: [Double] }

    /// Periodic Hann window (torch.hann_window).
    static let window: [Double] = (0 ..< nFFT).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(nFFT)) }

    /// torchaudio.functional.melscale_fbanks(513, 30, 11000, 128, 22050, norm=None, mel_scale="slaney"),
    /// stored per band as its nonzero range.
    static let melFilters: [Band] = {
        let logStep = log(6.4) / 27
        func toMel(_ hz: Double) -> Double { hz >= 1000 ? 15 + log(hz / 1000) / logStep : 3 * hz / 200 }
        func toHz(_ mel: Double) -> Double { mel >= 15 ? 1000 * exp(logStep * (mel - 15)) : 200 * mel / 3 }
        let bins = nFFT / 2 + 1
        let lo = toMel(30), hi = toMel(11000)
        let edges = (0 ..< mels + 2).map { toHz(lo + Double($0) * (hi - lo) / Double(mels + 1)) }
        let nyquist = Double(sampleRate / 2)
        let freqs = (0 ..< bins).map { Double($0) * nyquist / Double(bins - 1) }
        return (0 ..< mels).map { m in
            let weights = freqs.map { f -> Double in
                let down = (f - edges[m]) / (edges[m + 1] - edges[m])
                let up = (edges[m + 2] - f) / (edges[m + 2] - edges[m + 1])
                return max(0, min(down, up))
            }
            let first = weights.firstIndex { $0 > 0 } ?? 0
            let last = weights.lastIndex { $0 > 0 } ?? 0
            return Band(range: first ..< last + 1, weights: Array(weights[first ... last]))
        }
    }()

    static let fft = RadixTwoFFT(size: nFFT)
}

/// Halves the sample rate (44.1 → 22.05 kHz) with a linear-phase low-pass shaped like the one
/// Phase 0 resampled with (soxr "VHQ"): flat to 10 kHz, −1 dB at 10.4 kHz, −42 dB at 10.8 kHz.
/// Apple's converter keeps 10.5–11 kHz about 12 dB louder; Beat This!'s top mel bands hear that,
/// and on songs whose tempo varies a beat here and there came out differently.
public enum HalfRate {
    /// Kaiser-windowed sinc, 601 taps, β 22, cut off at 10.54 kHz (fitted to soxr's response,
    /// within 0.8 dB down to −90 dB), normalised to unity gain; zero-padded to a multiple of 8.
    static let taps: [Float] = {
        let count = 601, beta = 22.0, cutoff = 10_540.0 / 22_050   // of the input's Nyquist
        func bessel0(_ x: Double) -> Double {
            var sum = 1.0, term = 1.0, k = 1.0
            while term > 1e-17 * sum { term *= (x / (2 * k)) * (x / (2 * k)); sum += term; k += 1 }
            return sum
        }
        let mid = Double(count - 1) / 2
        var h = (0 ..< count).map { i -> Double in
            let m = Double(i) - mid
            let sinc = m == 0 ? 1 : sin(Double.pi * cutoff * m) / (Double.pi * cutoff * m)
            let r = Double(i) / mid - 1
            return cutoff * sinc * bessel0(beta * (1 - r * r).squareRoot()) / bessel0(beta)
        }
        let sum = h.reduce(0, +)
        h = h.map { $0 / sum }
        return h.map(Float.init) + [Float](repeating: 0, count: (8 - count % 8) % 8)
    }()

    /// ⌈n/2⌉ samples: every other sample of the filtered audio, zero beyond the ends (as soxr's length).
    public static func decimate(_ x: [Float]) -> [Float] {
        let taps = Self.taps, half = 300   // the filter's centre (601 taps)
        let n = x.count, out = (n + 1) / 2
        var padded = [Float](repeating: 0, count: n + 2 * half + taps.count)
        padded.replaceSubrange(half ..< half + n, with: x)
        var y = [Float](repeating: 0, count: out)
        padded.withUnsafeBufferPointer { p in
            taps.withUnsafeBufferPointer { h in
                let src = UnsafeRawPointer(p.baseAddress!), filter = UnsafeRawPointer(h.baseAddress!)
                let blocks = taps.count / 8
                for m in 0 ..< out {
                    // The filter is symmetric, so it lines up with the input as it is.
                    var acc = SIMD8<Float>()
                    let base = src + 2 * m * MemoryLayout<Float>.stride
                    for b in 0 ..< blocks {
                        let offset = b * 8 * MemoryLayout<Float>.stride
                        acc.addProduct(base.loadUnaligned(fromByteOffset: offset, as: SIMD8<Float>.self),
                                       filter.loadUnaligned(fromByteOffset: offset, as: SIMD8<Float>.self))
                    }
                    y[m] = acc.sum()
                }
            }
        }
        return y
    }
}

/// Tempo from Beat This!'s per-frame logits, as Phase 0 worked it out (beat_this's
/// "minimal" postprocessor, then phase0/soundlab/music.py summarize_beats).
public enum BeatTracking {
    public struct Summary: Sendable, Equatable {
        /// Beat times, seconds (refined between frames).
        public var beats: [Double]
        /// Downbeat times, seconds (on the unrefined beat frames).
        public var downbeats: [Double]
        /// nil with fewer than 4 beats.
        public var bpm: Double?
        /// 10th–90th percentile of the tempo over 8-beat stretches.
        public var bpmRange: ClosedRange<Double>?
        /// "steady", "mostly steady", "variable" or "no steady beat".
        public var stability: String
        public var beatsPerBar: Int?
        /// Half how regular the beats are, half how sure the model was of them (0…1).
        public var confidence: Double
    }

    /// Beat and downbeat times (seconds) from the logits, Postprocessor(type="minimal"): peaks
    /// over ±3 frames above probability 0.5, adjacent peaks merged, each downbeat moved to the nearest beat.
    public static func peaks(beatLogits: [Float], downbeatLogits: [Float]) -> (beats: [Double], downbeats: [Double]) {
        let beats = frames(beatLogits).map { $0 / Double(BeatThisAudio.fps) }
        var downbeats = frames(downbeatLogits).map { $0 / Double(BeatThisAudio.fps) }
        if !beats.isEmpty {
            for (i, d) in downbeats.enumerated() {
                var best = 0
                for j in beats.indices where abs(beats[j] - d) < abs(beats[best] - d) { best = j }
                downbeats[i] = beats[best]
            }
        }
        return (beats, Array(Set(downbeats)).sorted())
    }

    /// Peak frames, adjacent ones merged into their mean.
    static func frames(_ logits: [Float]) -> [Double] {
        // Phase 0 averaged its models' probabilities and went back to logits with the
        // probability clamped to 1e-6…1−1e-6; comparing clamped probabilities picks the same peaks.
        let lo = Float(1e-6), hi = Float(1 - 1e-6)
        let p = logits.map { min(max(sigmoid($0), lo), hi) }
        var peaks: [Int] = []
        for t in p.indices where p[t] > 0.5 {
            var isMax = true
            for u in max(0, t - 3) ... min(p.count - 1, t + 3) where p[u] > p[t] { isMax = false; break }
            if isMax { peaks.append(t) }
        }
        // deduplicate_peaks(width=1): a running mean, compared against the next peak.
        var out: [Double] = []
        guard var mean = peaks.first.map(Double.init) else { return out }
        var count = 1.0
        for next in peaks.dropFirst() {
            if Double(next) - mean <= 1 {
                count += 1
                mean += (Double(next) - mean) / count
            } else {
                out.append(mean)
                mean = Double(next)
                count = 1
            }
        }
        out.append(mean)
        return out
    }

    public static func sigmoid(_ x: Float) -> Float { 1 / (1 + exp(-x)) }

    /// summarize_beats: tempo, its range and steadiness, beats per bar and a confidence.
    /// `beatProbability`: the beat sigmoid per frame.
    public static func summarize(beats rawBeats: [Double], downbeats: [Double], beatProbability prob: [Float]) -> Summary {
        let fps = Double(BeatThisAudio.fps)
        let beats = rawBeats.isEmpty ? rawBeats : refine(rawBeats, prob)
        var out = Summary(beats: beats, downbeats: downbeats, bpm: nil, bpmRange: nil, stability: "no steady beat",
                          beatsPerBar: nil, confidence: 0)
        guard beats.count >= 4 else { return out }
        let ibi = zip(beats.dropFirst(), beats).map { $0 - $1 }
        let med = median(ibi)
        let regular = Double(ibi.filter { abs($0 - med) <= 0.06 * med }.count) / Double(ibi.count)
        // Tempo over 8-beat stretches shows whether it drifts or changes.
        let win = 8
        var local: [Double] = []
        for s in stride(from: 0, to: beats.count - win, by: win / 2) {
            local.append(60 / fitPeriod(Array(beats[s ..< min(beats.count, s + win + 1)]), guess: med))
        }
        if local.isEmpty { local = [60 / med] }
        let p10 = percentile(local, 10), p90 = percentile(local, 90), localMedian = median(local)
        let spread = (p90 - p10) / localMedian
        let bpm: Double
        if spread < 0.02 {
            bpm = 60 / fitPeriod(beats, guess: med)   // the whole song: precise for a steady tempo
            out.stability = "steady"
        } else {
            bpm = localMedian
            out.stability = spread < 0.06 ? "mostly steady" : "variable"
        }
        let strength = beats.map { b -> Double in
            let f = min(max(Int((b * fps).rounded(.toNearestOrEven)), 0), prob.count - 1)
            return Double(prob[f])
        }.reduce(0, +) / Double(beats.count)
        if downbeats.count >= 3 {
            let counts = zip(downbeats, downbeats.dropFirst()).map { a, b in beats.filter { $0 >= a - 0.02 && $0 < b - 0.02 }.count }
            // The most common count; the smallest on a tie (numpy.unique sorts).
            var tally: [Int: Int] = [:]
            for c in counts { tally[c, default: 0] += 1 }
            out.beatsPerBar = tally.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
        }
        out.bpm = (bpm * 100).rounded() / 100
        out.bpmRange = (p10 * 10).rounded() / 10 ... (p90 * 10).rounded() / 10
        out.confidence = ((0.5 * regular + 0.5 * strength) * 1000).rounded() / 1000
        return out
    }

    /// refine_peaks: sub-frame times by a parabola through the probability around each peak
    /// (in single precision, as numpy computed it from the float32 probabilities).
    static func refine(_ times: [Double], _ prob: [Float]) -> [Double] {
        let fps = Double(BeatThisAudio.fps)
        guard prob.count >= 3 else { return times }
        return times.map { t in
            let f = min(max(Int((t * fps).rounded(.toNearestOrEven)), 1), prob.count - 2)
            let a = prob[f - 1], b = prob[f], c = prob[f + 1]
            let den = a - 2 * b + c
            let delta: Float = abs(den) > 1e-9 ? 0.5 * (a - c) / den : 0
            return (Double(f) + Double(min(max(delta, -0.5), 0.5))) / fps
        }
    }

    /// fit_period: a robust straight line through beat time against beat number, so a
    /// missed or extra beat doesn't skew it. The slope is the beat period.
    static func fitPeriod(_ beats: [Double], guess: Double) -> Double {
        var n = [Double](repeating: 0, count: beats.count)
        for i in 1 ..< max(1, beats.count) { n[i] = n[i - 1] + max(1, ((beats[i] - beats[i - 1]) / guess).rounded(.toNearestOrEven)) }
        var keep = [Bool](repeating: true, count: beats.count)
        var slope = 0.0
        for _ in 0 ..< 4 {
            let line = fitLine(x: n, y: beats, where: keep)
            slope = line.slope
            let newKeep = beats.indices.map { abs(beats[$0] - (line.slope * n[$0] + line.intercept)) <= 0.15 * line.slope }
            let kept = newKeep.filter { $0 }.count
            if Double(kept) < max(4, 0.5 * Double(beats.count)) || newKeep == keep { break }
            keep = newKeep
        }
        return slope
    }

    /// Least squares y = slope·x + intercept over the kept points (numpy.polyfit, degree 1).
    static func fitLine(x: [Double], y: [Double], where keep: [Bool]) -> (slope: Double, intercept: Double) {
        let idx = x.indices.filter { keep[$0] }
        let count = Double(idx.count)
        let mx = idx.reduce(0) { $0 + x[$1] } / count, my = idx.reduce(0) { $0 + y[$1] } / count
        var sxy = 0.0, sxx = 0.0
        for i in idx { sxy += (x[i] - mx) * (y[i] - my); sxx += (x[i] - mx) * (x[i] - mx) }
        let slope = sxx > 0 ? sxy / sxx : 0
        return (slope, my - slope * mx)
    }

    static func median(_ v: [Double]) -> Double { percentile(v, 50) }

    /// numpy.percentile with linear interpolation.
    static func percentile(_ v: [Double], _ q: Double) -> Double {
        let s = v.sorted()
        guard s.count > 1 else { return s.first ?? .nan }
        let pos = q / 100 * Double(s.count - 1)
        let i = Int(pos.rounded(.down)), frac = pos - Double(i)
        return i + 1 < s.count ? s[i] + (s[i + 1] - s[i]) * frac : s[i]
    }
}

/// S-KEY's 24 outputs, in its order (skey.key_detection.key_map).
public enum KeyDetection {
    public static let labels: [MusicKey] = {
        let names = ["A", "Bb", "B", "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#",
                     "B", "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "Bb"]
        return names.enumerated().map { i, name in MusicKey(parsing: name + (i >= 12 ? "m" : ""))! }
    }()

    public struct Estimate: Sendable, Equatable {
        public var key: MusicKey
        public var confidence: Double
        public var runnerUp: MusicKey
        public var runnerUpConfidence: Double
    }

    /// The most likely key with its probability, and the next most likely.
    public static func estimate(probabilities p: [Float]) -> Estimate? {
        guard p.count == labels.count else { return nil }
        // Stable on ties, like numpy.argsort(-p) (quicksort is unstable there, but exact ties don't happen).
        let order = p.indices.sorted { p[$0] != p[$1] ? p[$0] > p[$1] : $0 < $1 }
        return Estimate(key: labels[order[0]], confidence: Double(p[order[0]]),
                        runnerUp: labels[order[1]], runnerUpConfidence: Double(p[order[1]]))
    }
}
