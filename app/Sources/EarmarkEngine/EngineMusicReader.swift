import EarmarkCore
import Foundation

/// Reads a song's tags and length (the app's is `MusicFiles.songFile`, on AVFoundation).
/// Only `title`, `artist`, `album` and `duration` of its answer are used.
public typealias SongReader = @Sendable (URL) async -> SongFile

/// Reads a music folder with the Rust engine, giving what `MusicFiles.read` gives: the engine
/// lists the files with their size and date, and the app's reader gives their tags.
public struct EngineMusicReader: Sendable {
    public let parallelism: Int
    public let tags: SongReader

    public init(parallelism: Int = 8, tags: @escaping SongReader) {
        self.parallelism = max(1, parallelism)
        self.tags = tags
    }

    /// Only reads; nothing is written next to the files. Runs off the calling thread.
    public func read(root: URL, progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async -> [SongFile] {
        let listener = MusicListener(progress: progress, tags: tags)
        let parallelism = UInt32(parallelism)
        let songs = await Task.detached(priority: .utility) {
            readSongs(root: root.path, parallelism: parallelism, listener: listener)
        }.value
        return songs.map {
            SongFile(path: $0.path, fileSize: $0.fileSize,
                     modified: EngineDate.make($0.modifiedSeconds, $0.modifiedNanos.map(Int64.init)),
                     title: $0.tags.title, artist: $0.tags.artist, album: $0.tags.album, duration: $0.tags.duration)
        }
    }
}

/// A file's date as Foundation makes it from the file system's seconds and nanoseconds (CFURL:
/// seconds - kCFAbsoluteTimeIntervalSince1970 + 1e-9 × nanoseconds), so it's identical to the
/// date Swift reads, to the bit. Unknown is the distant past, as in the Swift readers.
enum EngineDate {
    static func make(_ seconds: Int64?, _ nanos: Int64?) -> Date {
        guard let seconds, let nanos else { return .distantPast }
        return Date(timeIntervalSinceReferenceDate: Double(seconds) - 978_307_200.0 + 1.0e-9 * Double(nanos))
    }
}

private final class MusicListener: SongListener {
    let report: @Sendable (Int, Int) -> Void
    let reader: SongReader

    init(progress: @escaping @Sendable (Int, Int) -> Void, tags: @escaping SongReader) {
        report = progress
        reader = tags
    }

    func progress(done: UInt64, total: UInt64) { report(Int(done), Int(total)) }

    /// Called on one of the engine's own threads (not Swift's), which may wait for the reader.
    func tags(path: String) -> SongTags {
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let reader = self.reader
        Task.detached {
            box.file = await reader(URL(fileURLWithPath: path))
            done.signal()
        }
        done.wait()
        let file = box.file
        return SongTags(title: file?.title, artist: file?.artist, album: file?.album, duration: file?.duration)
    }

    private final class Box: @unchecked Sendable { var file: SongFile? }
}
