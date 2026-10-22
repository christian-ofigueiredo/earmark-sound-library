import Foundation

public enum AudioFiles {
    public static let extensions: Set<String> = [
        "wav", "wave", "bwf", "rf64", "w64", "aif", "aiff", "aifc", "flac", "ogg", "oga", "opus",
        "mp3", "m4a", "aac", "alac", "caf", "mp4",
    ]

    /// All audio files under `root`, skipping hidden files/folders and macOS
    /// AppleDouble ("._name") files. Sorted by path.
    public static func list(in root: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return []
        }
        var out: [URL] = []
        for case let url as URL in walker {
            let name = url.lastPathComponent
            guard !name.hasPrefix("."), extensions.contains(url.pathExtension.lowercased()) else { continue }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { out.append(url) }
        }
        return out.sorted { $0.path < $1.path }
    }
}

/// Identity of a file's content, so renamed or moved files keep their data:
/// size plus a hash of the first and last 64 KB (FNV-1a, 64-bit).
public enum Fingerprint {
    public static func of(url: URL) -> String? {
        guard let file = try? ReadOnlyFile(url: url) else { return nil }
        defer { file.close() }
        let chunk = 65_536
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ d: Data) { for b in d { hash = (hash ^ UInt64(b)) &* 0x100_0000_01b3 } }
        mix(file.read(at: 0, count: chunk))
        if file.size > UInt64(chunk) { mix(file.read(at: max(UInt64(chunk), file.size - UInt64(chunk)), count: chunk)) }
        return String(format: "%llx-%016llx", file.size, hash)
    }
}

/// A sound effect file as found on disk (never modified).
public struct ScannedSound: Sendable, Codable, Equatable {
    public var path: String
    public var fileSize: Int64
    public var modified: Date
    public var fingerprint: String?
    public var technical: AudioTechnical
    public var metadata: NormalizedMetadata
    public var warnings: [String]
}

public struct LibraryScanner: Sendable {
    public let catalog: UCSCatalog
    public let parallelism: Int

    public init(catalog: UCSCatalog = .shared, parallelism: Int = 8) {
        self.catalog = catalog
        self.parallelism = max(1, parallelism)
    }

    public static func inspect(url: URL, catalog: UCSCatalog = .shared) -> ScannedSound {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let raw = MetadataReader.read(url: url)
        return ScannedSound(path: url.path, fileSize: Int64(values?.fileSize ?? 0),
                            modified: values?.contentModificationDate ?? .distantPast,
                            fingerprint: Fingerprint.of(url: url), technical: raw.technical,
                            metadata: MetadataNormalizer.normalize(raw, url: url, catalog: catalog),
                            warnings: raw.warnings)
    }

    /// Reads every file's header in parallel. `progress(done, total)` is called
    /// as files complete. Only reads; nothing is written next to the files.
    public func scan(root: URL, progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async -> [ScannedSound] {
        let files = AudioFiles.list(in: root)
        let catalog = self.catalog
        var results: [ScannedSound] = []
        results.reserveCapacity(files.count)
        await withTaskGroup(of: ScannedSound.self) { group in
            var next = 0
            for _ in 0 ..< min(parallelism, files.count) {
                let url = files[next]; next += 1
                group.addTask { LibraryScanner.inspect(url: url, catalog: catalog) }
            }
            for await sound in group {
                results.append(sound)
                progress(results.count, files.count)
                if next < files.count {
                    let url = files[next]; next += 1
                    group.addTask { LibraryScanner.inspect(url: url, catalog: catalog) }
                }
            }
        }
        return results.sorted { $0.path < $1.path }
    }
}
