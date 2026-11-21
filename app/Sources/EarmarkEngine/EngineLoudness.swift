import EarmarkCore
import Foundation

/// Swift's `LoudnessMeter` through the Rust engine: the same chunks in, the same result out.
public final class EngineLoudnessMeter: @unchecked Sendable {
    private let measure: LoudnessMeasure

    public init(sampleRate: Double, channels: Int) {
        measure = LoudnessMeasure(sampleRate: sampleRate, channels: UInt32(channels))
    }

    /// `frames` frames of deinterleaved float audio, one buffer per channel (of at least `frames`
    /// floats). The engine reads them where they are, during the call.
    public func process(_ buffers: [UnsafeBufferPointer<Float>], frames: Int) {
        guard frames > 0, buffers.allSatisfy({ $0.count >= frames }) else { return }
        measure.process(channels: buffers.map { UInt64(UInt(bitPattern: $0.baseAddress)) }, frames: UInt32(frames))
    }

    public var result: LoudnessMeter.Result {
        let r = measure.result()
        return LoudnessMeter.Result(integrated: r.integrated, peak: r.peak)
    }
}
