import AVFoundation
import EarmarkCore

/// Lists songs in a folder with their tags (title, artist, album, length).
/// Files are opened read-only through AVFoundation.
enum MusicFiles {
    static func read(root: URL, parallelism: Int = 8,
                     progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async -> [SongFile] {
        let urls = AudioFiles.list(in: root)
        var out: [SongFile] = []
        out.reserveCapacity(urls.count)
        await withTaskGroup(of: SongFile.self) { group in
            var next = 0
            for _ in 0 ..< min(parallelism, urls.count) {
                let url = urls[next]
                next += 1
                group.addTask { await songFile(url) }
            }
            for await file in group {
                out.append(file)
                progress(out.count, urls.count)
                if next < urls.count {
                    let url = urls[next]
                    next += 1
                    group.addTask { await songFile(url) }
                }
            }
        }
        return out.sorted { $0.path < $1.path }
    }

    static func songFile(_ url: URL) async -> SongFile {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        var file = SongFile(path: url.path, fileSize: Int64(values?.fileSize ?? 0),
                            modified: values?.contentModificationDate ?? .distantPast)
        let asset = AVURLAsset(url: url)
        if let loaded = try? await asset.load(.duration, .commonMetadata) {
            let (duration, metadata) = loaded
            file.duration = duration.seconds.isFinite && duration.seconds > 0 ? duration.seconds : nil
            file.title = await text(metadata, .commonIdentifierTitle)
            file.artist = await text(metadata, .commonIdentifierArtist)
            file.album = await text(metadata, .commonIdentifierAlbumName)
        }
        return file
    }

    private static func text(_ items: [AVMetadataItem], _ id: AVMetadataIdentifier) async -> String? {
        guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id).first,
              let value = try? await item.load(.stringValue) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
