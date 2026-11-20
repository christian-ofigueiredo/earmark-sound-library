import EarmarkCore
import Foundation

/// The Rust engine behind the app's own types (docs/rust-engine-plan.md, step 8). The calls
/// into Rust are in `Generated/earmark_ffi.swift`, which scripts/build-engine.sh writes.
public enum Engine {
    /// Which code reads the libraries: the Rust engine unless the owner turns it off with
    /// `defaults write io.github.christian-ofigueiredo.Earmark swiftEngine -bool YES`.
    public static var isOn: Bool { !UserDefaults.standard.bool(forKey: "swiftEngine") }

    public static var version: String { engineVersion() }
}

/// Reads a library's sound files with the Rust engine, giving what `LibraryScanner` gives.
public struct EngineScanner: Sendable {
    public let parallelism: Int
    public let fallback: TechnicalReader?

    public init(parallelism: Int = 8, fallback: TechnicalReader? = nil) {
        self.parallelism = max(1, parallelism)
        self.fallback = fallback
    }

    /// Only reads; nothing is written next to the files. Runs off the calling thread.
    public func scan(root: URL, progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async -> [ScannedSound] {
        let listener = Listener(progress: progress, fallback: fallback)
        let parallelism = UInt32(parallelism)
        let json = await Task.detached(priority: .utility) {
            scanSounds(root: root.path, parallelism: parallelism, listener: listener)
        }.value
        return Self.decode(json)
    }

    /// The engine's JSON as Swift's `ScannedSound`: the same fields. Anything it can't read gives
    /// no files, which the app takes as a failed scan and keeps what it knows.
    static func decode(_ json: String) -> [ScannedSound] {
        struct Row: Decodable {
            var path: String; var fileSize: Int64; var modified: Double; var fingerprint: String?
            var modifiedSeconds: Int64?; var modifiedNanos: Int64?
            var technical: AudioTechnical; var metadata: NormalizedMetadata; var warnings: [String]
        }
        guard let rows = try? JSONDecoder().decode([Row].self, from: Data(json.utf8)) else { return [] }
        // As Foundation makes a file's date from the file system's seconds and nanoseconds
        // (CFURL: seconds - kCFAbsoluteTimeIntervalSince1970 + 1e-9 × nanoseconds), so dates are
        // identical to LibraryScanner's to the bit. An unknown date is the distant past, as there.
        func date(_ seconds: Int64?, _ nanos: Int64?) -> Date {
            guard let seconds, let nanos else { return .distantPast }
            return Date(timeIntervalSinceReferenceDate: Double(seconds) - 978_307_200.0 + 1.0e-9 * Double(nanos))
        }
        return rows.map {
            ScannedSound(path: $0.path, fileSize: $0.fileSize,
                         modified: date($0.modifiedSeconds, $0.modifiedNanos),
                         fingerprint: $0.fingerprint, technical: $0.technical, metadata: $0.metadata,
                         warnings: $0.warnings)
        }
    }
}

private final class Listener: ScanListener {
    let report: @Sendable (Int, Int) -> Void
    let fallback: TechnicalReader?

    init(progress: @escaping @Sendable (Int, Int) -> Void, fallback: TechnicalReader?) {
        report = progress
        self.fallback = fallback
    }

    func progress(done: UInt64, total: UInt64) { report(Int(done), Int(total)) }

    func technical(path: String) -> Technical? {
        guard let t = fallback?(URL(fileURLWithPath: path)) else { return nil }
        return Technical(sampleRate: t.sampleRate, channels: t.channels.map(Int64.init),
                         bitsPerSample: t.bitsPerSample.map(Int64.init), duration: t.duration)
    }
}
