import EarmarkCore
import Foundation

/// The sound map and similarity groups through the Rust engine, with the same signatures and
/// results as `SoundMap.map`, `SoundGroups.cluster` and `SoundGroups.names`.
///
/// The engine reads the rows where they are (their address): no copy of a library's 177 MB, and
/// the same page-aligned buffer the app made gives the same sums to the bit (vDSP's results
/// depend on where a matrix sits in memory). The rows must stay alive and unchanged meanwhile,
/// which these calls being synchronous ensures.
public enum EngineAnalysis {
    public static func map(flat x: UnsafeBufferPointer<Float>, count n: Int, dimensions d: Int,
                           progress: (Double) -> Void = { _ in }, isCancelled: () -> Bool = { false }) -> SoundMap.Map? {
        withListener(progress: progress, isCancelled: isCancelled) { listener in
            guard let made = soundMap(address: address(x), count: UInt32(n), dimensions: UInt32(d), listener: listener)
            else { return nil }
            let p = made.points, l = made.links
            return SoundMap.Map(points: stride(from: 0, to: p.count - 1, by: 2).map { SIMD2(p[$0], p[$0 + 1]) },
                                links: stride(from: 0, to: l.count - 1, by: 2).map { SIMD2(l[$0], l[$0 + 1]) })
        }
    }

    public static func cluster(_ x: UnsafeBufferPointer<Float>, count n: Int, dimensions d: Int,
                               isCancelled: () -> Bool = { false }) -> [Int]? {
        withListener(progress: { _ in }, isCancelled: isCancelled) { listener in
            clusterSounds(address: address(x), count: UInt32(n), dimensions: UInt32(d), listener: listener)?.map(Int.init)
        }
    }

    public static func names(groups: [[Int]], x: UnsafeBufferPointer<Float>, dimensions d: Int, members: [SoundGroups.Member],
                             libraryMean: [Float], exclude: Set<String>) -> [SoundGroups.Name] {
        let n = d > 0 ? x.count / d : 0
        return groupNames(groups: groups.map { $0.map(UInt32.init) }, address: address(x), count: UInt32(n),
                          dimensions: UInt32(d), members: members.map { GroupMember(duration: $0.duration, text: $0.text) },
                          libraryMean: libraryMean, exclude: Array(exclude))
            .map { SoundGroups.Name(name: $0.name, aiWords: $0.aiWords, shapeWords: $0.shapeWords, keywords: $0.keywords) }
    }

    private static func address(_ x: UnsafeBufferPointer<Float>) -> UInt64 {
        UInt64(UInt(bitPattern: x.baseAddress))
    }

    /// The caller's progress and cancel check for the length of one call; the engine calls them
    /// from its own threads while the call runs.
    private static func withListener<R>(progress: (Double) -> Void, isCancelled: () -> Bool,
                                        _ body: (WorkListener) -> R) -> R {
        withoutActuallyEscaping(progress) { progress in
            withoutActuallyEscaping(isCancelled) { isCancelled in
                body(Listener(progress: progress, isCancelled: isCancelled))
            }
        }
    }

    private final class Listener: WorkListener, @unchecked Sendable {
        let report: (Double) -> Void
        let cancelled: () -> Bool
        init(progress: @escaping (Double) -> Void, isCancelled: @escaping () -> Bool) {
            report = progress
            cancelled = isCancelled
        }
        func progress(fraction: Double) { report(fraction) }
        func isCancelled() -> Bool { cancelled() }
    }
}
