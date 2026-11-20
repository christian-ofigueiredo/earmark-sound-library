import EarmarkCore
import EarmarkEngine
import Foundation
import Testing

/// The Rust engine's scan gives what Swift's LibraryScanner gives, through the app's types.
/// (On a real library: `earmark-parity enginescan <folder>`.)
struct EngineScannerTests {
    /// A short 16-bit mono WAV with a BEXT description, as many libraries ship.
    func wav(seconds: Double, description: String) -> Data {
        func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        let rate: UInt32 = 48_000
        let samples = Data(count: Int(Double(rate) * seconds) * 2)
        var bext = Data(description.utf8.prefix(256))
        bext.append(Data(count: 602 - bext.count))
        var body = Data("WAVE".utf8)
        body += Data("fmt ".utf8) + le(UInt32(16)) + le(UInt16(1)) + le(UInt16(1)) + le(rate) + le(rate * 2) + le(UInt16(2)) + le(UInt16(16))
        body += Data("bext".utf8) + le(UInt32(bext.count)) + bext
        body += Data("data".utf8) + le(UInt32(samples.count)) + samples
        return Data("RIFF".utf8) + le(UInt32(body.count)) + body
    }

    @Test func sameAsSwift() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("earmark-engine-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("Doors Café") // decomposed by the file system on HFS+
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try wav(seconds: 0.5, description: "Door slam, heavy wood").write(to: folder.appendingPathComponent("DOORWood_Slam Heavy_ME_LIB.wav"))
        try wav(seconds: 1.25, description: "Creak").write(to: root.appendingPathComponent("creak.WAV"))
        try Data("not audio".utf8).write(to: root.appendingPathComponent("notes.txt"))
        try Data("hidden".utf8).write(to: root.appendingPathComponent("._creak.WAV"))

        let swift = await LibraryScanner().scan(root: root)
        let engine = await EngineScanner().scan(root: root)
        #expect(swift.count == 2)
        #expect(engine == swift)
        #expect(engine.map(\.technical.duration) == [0.5, 1.25])
    }

    /// Links as Foundation treats them: resolved in the folders above the library (the temporary
    /// folder is under /var, a link to /private/var), not followed inside it, and a library that
    /// is itself a link lists nothing.
    @Test func links() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("earmark-engine-\(UUID().uuidString)")
        let real = root.appendingPathComponent("real"), sub = real.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try wav(seconds: 0.5, description: "A").write(to: real.appendingPathComponent("a.wav"))
        try wav(seconds: 0.5, description: "B").write(to: sub.appendingPathComponent("b.wav"))
        try FileManager.default.createSymbolicLink(atPath: sub.appendingPathComponent("c.wav").path, withDestinationPath: "../a.wav")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: real)
        for folder in [real, root.appendingPathComponent("link"), root.appendingPathComponent("link/sub"),
                       URL(fileURLWithPath: root.path.lowercased()).appendingPathComponent("real")] {
            let swift = await LibraryScanner().scan(root: folder)
            #expect(await EngineScanner().scan(root: folder) == swift, "\(folder.path)")
        }
        #expect(await LibraryScanner().scan(root: real).count == 2)
    }

    @Test func emptyFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("earmark-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(await EngineScanner().scan(root: root).isEmpty)
    }
}
