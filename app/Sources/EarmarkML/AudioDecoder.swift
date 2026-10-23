import AVFoundation
import EarmarkCore

public enum AudioDecoderError: Error, LocalizedError {
    case unsupportedFormat
    case conversionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "unsupported audio format"
        case .conversionFailed(let why): "couldn't resample: \(why)"
        }
    }
}

/// Decodes a file (opened read-only) to mono float32, as Phase 0 did: channels
/// averaged, at most `maxSeconds` from the start, resampled with Apple's
/// highest-quality converter (Phase 0 used soxr "VHQ"). Streams, so a long
/// 96 kHz file never sits in memory at its original rate.
public enum AudioDecoder {
    public static func mono(url: URL, sampleRate target: Double, maxSeconds: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        let rate = inFormat.sampleRate
        let channels = Int(inFormat.channelCount)
        let total = min(file.length, AVAudioFramePosition(maxSeconds * rate))
        guard channels > 0, rate > 0,
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let readBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: 1 << 16)
        else { throw AudioDecoderError.unsupportedFormat }

        var position: AVAudioFramePosition = 0
        func nextMono() throws -> AVAudioPCMBuffer? {
            guard position < total else { return nil }
            let want = AVAudioFrameCount(min(AVAudioFramePosition(readBuffer.frameCapacity), total - position))
            try file.read(into: readBuffer, frameCount: want)
            let n = Int(readBuffer.frameLength)
            guard n > 0, let src = readBuffer.floatChannelData,
                  let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(n)),
                  let dst = mono.floatChannelData?[0] else { return nil }
            position += AVAudioFramePosition(n)
            mono.frameLength = AVAudioFrameCount(n)
            let scale = 1 / Float(channels)
            for i in 0 ..< n {
                var sum: Float = 0
                for c in 0 ..< channels { sum += src[c][i] }
                dst[i] = channels == 1 ? sum : sum * scale
            }
            return mono
        }

        var out: [Float] = []
        out.reserveCapacity(Int(Double(total) * target / rate) + 4096)
        if rate == target {
            while let b = try nextMono() {
                out.append(contentsOf: UnsafeBufferPointer(start: b.floatChannelData![0], count: Int(b.frameLength)))
            }
            return out
        }

        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: target, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: monoFormat, to: outFormat),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 1 << 16)
        else { throw AudioDecoderError.unsupportedFormat }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        var ended = false
        var readError: Error?
        while true {
            var error: NSError?
            let status = converter.convert(to: outBuffer, error: &error) { _, inputStatus in
                if !ended {
                    do {
                        if let b = try nextMono() {
                            inputStatus.pointee = .haveData
                            return b
                        }
                    } catch {
                        readError = error
                    }
                    ended = true
                }
                inputStatus.pointee = .endOfStream
                return nil
            }
            if let readError { throw readError }
            if status == .error { throw AudioDecoderError.conversionFailed(error?.localizedDescription ?? "unknown") }
            if outBuffer.frameLength > 0 {
                out.append(contentsOf: UnsafeBufferPointer(start: outBuffer.floatChannelData![0], count: Int(outBuffer.frameLength)))
            }
            if status == .endOfStream || (ended && outBuffer.frameLength == 0) { break }
        }
        return out
    }
}
