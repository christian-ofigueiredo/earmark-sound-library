import Foundation
import MCP
import Testing
@testable import EarmarkCore
@testable import EarmarkMCP

/// The MCP server, through the SDK's own client over an in-memory transport: what an agent sees.
@Suite struct EarmarkMCPTests {
    /// What the server sent out of the process.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _opened: [URL] = []
        private var _items: [ResolveBridge.Item] = []
        private var _preview = false
        var opened: [URL] { lock.withLock { _opened } }
        var items: [ResolveBridge.Item] { lock.withLock { _items } }
        var preview: Bool { lock.withLock { _preview } }
        func open(_ url: URL) { lock.withLock { _opened.append(url) } }
        func add(_ items: [ResolveBridge.Item], _ preview: Bool) { lock.withLock { _items = items; _preview = preview } }
    }

    /// A library of four sounds (files on disk, empty): two byte-identical copies, a long ambience,
    /// a short door slam, with categories, a group and loudness.
    static func library() throws -> (LibraryDatabase, [String: Int64], URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("earmark-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Pack/Doors"), withIntermediateDirectories: true)
        let db = try LibraryDatabase(path: nil)
        let lib = try db.addLibrary(kind: .sounds, path: root.path, bookmark: nil)
        func scanned(_ path: String, fingerprint: String, seconds: Double, description: String) -> ScannedSound {
            FileManager.default.createFile(atPath: root.appendingPathComponent(path).path, contents: Data())
            var m = NormalizedMetadata()
            m.fields[.description] = description
            return ScannedSound(path: root.appendingPathComponent(path).path, fileSize: 1, modified: Date(), fingerprint: fingerprint,
                                technical: AudioTechnical(sampleRate: 48000, channels: 2, bitsPerSample: 24, duration: seconds),
                                metadata: m, warnings: [])
        }
        try db.replaceSounds(libraryId: lib.id!, root: root, scanned: [
            scanned("Pack/Doors/Door Wood Slam 01.wav", fingerprint: "a", seconds: 1.2, description: "heavy wooden door slam"),
            scanned("Pack/Doors/Door Wood Slam 01 copy.wav", fingerprint: "a", seconds: 1.2, description: "heavy wooden door slam"),
            scanned("Pack/Forest Night.wav", fingerprint: "b", seconds: 60, description: "crickets and wind"),
            scanned("Pack/Doors/Door Creak.wav", fingerprint: "c", seconds: 3, description: "slow creak"),
        ])
        let sounds = try db.sounds()
        var ids: [String: Int64] = [:]
        for s in sounds { ids[s.fileName] = s.id! }
        try db.setSoundCategory(sounds.filter { $0.fileName.hasPrefix("Door") }.map { ($0.id!, $0.fingerprint) }, catID: "DOORWood")
        try db.setSoundCategory([(ids["Forest Night.wav"]!, "b")], catID: "AMBForst")
        let doors = sounds.filter { $0.fileName.hasPrefix("Door") }
        try db.replaceGroups(catID: "DOORWood", groups: [doors.map { ($0.id!, $0.fingerprint) }],
                             names: [SoundGroups.Name(name: "Short · Wooden", aiWords: [], shapeWords: [], keywords: ["slam"])])
        try db.save([SoundFacts(soundId: ids["Door Wood Slam 01.wav"]!, fingerprint: "a", loudness: .init(integrated: -18.04, peak: -1))])
        return (db, ids, root)
    }

    static func connect(_ db: LibraryDatabase, _ recorder: Recorder, placements: [ResolveBridge.Placement] = [],
                        timelineFolder: URL = FileManager.default.temporaryDirectory) async throws -> (Client, Server) {
        let outside = EarmarkTools.Outside(
            open: { recorder.open($0) },
            resolveStatus: { throw ResolveBridge.Failure.notConnected },
            resolveAdd: { items, preview in
                recorder.add(items, preview)
                let placed = placements.isEmpty ? items.map { _ in ResolveBridge.Placement(ok: true, track: 3, trackName: "Earmark",
                                                                                         start: "01:00:02:00", end: "01:00:03:06", newTrack: true) }
                                                : placements
                return ResolveBridge.Added(project: "Film", timeline: "Edit 1", items: placed)
            },
            timelineFolder: timelineFolder)
        let server = await EarmarkServer.make(EarmarkTools(database: db, outside: outside))
        let (clientSide, serverSide) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverSide)
        let client = Client(name: "test", version: "1")
        _ = try await client.connect(transport: clientSide)
        return (client, server)
    }

    /// A tool's answer, decoded from its JSON text.
    static func call(_ client: Client, _ name: String, _ arguments: [String: Value] = [:]) async throws -> (json: [String: Any], error: Bool, text: String) {
        let (content, isError) = try await client.callTool(name: name, arguments: arguments)
        guard case .text(let text, _, _)? = content.first else { return ([:], isError ?? false, "") }
        let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        return (json, isError ?? false, text)
    }

    @Test func theToolsAndWhatTheyMayChange() async throws {
        let (db, _, _) = try Self.library()
        let (client, server) = try await Self.connect(db, Recorder())
        let (tools, _) = try await client.listTools()
        #expect(tools.map(\.name) == ["library_overview", "search_sounds", "get_sound", "find_similar", "list_groups",
                                      "show_in_earmark", "resolve_status", "add_to_resolve", "save_timeline_file"])
        let readOnly = Set(tools.filter { $0.annotations.readOnlyHint == true }.map(\.name))
        #expect(readOnly == ["library_overview", "search_sounds", "get_sound", "find_similar", "list_groups", "resolve_status"])
        #expect(tools.allSatisfy { $0.annotations.destructiveHint != true })
        await server.stop()
    }

    @Test func searchingAndDetails() async throws {
        let (db, ids, _) = try Self.library()
        let (client, server) = try await Self.connect(db, Recorder())

        let overview = try await Self.call(client, "library_overview").json
        #expect(overview["sounds"] as? Int == 4 && overview["duplicates"] as? Int == 2)

        // Words in the name first; the category filter takes a CatID or a label.
        var found = try await Self.call(client, "search_sounds", ["query": "door", "limit": 2]).json
        #expect(found["total"] as? Int == 3)
        #expect((found["sounds"] as? [[String: Any]])?.count == 2)
        found = try await Self.call(client, "search_sounds", ["category": "Ambience / Forest"]).json
        #expect((found["sounds"] as? [[String: Any]])?.first?["id"] as? Int == Int(ids["Forest Night.wav"]!))
        found = try await Self.call(client, "search_sounds", ["query": "wooden", "max_length": "2"]).json
        #expect(found["total"] as? Int == 2)

        let slam = try await Self.call(client, "get_sound", ["sound_id": .int(Int(ids["Door Wood Slam 01.wav"]!))]).json
        let row = slam["sound"] as? [String: Any]
        #expect(row?["catID"] as? String == "DOORWood" && row?["group"] as? String == "Short · Wooden")
        #expect(row?["loudness"] as? Double == -18.0)
        #expect(slam["categorySource"] as? String == "the owner's choice for this sound")
        #expect((slam["copies"] as? [[String: Any]])?.first?["id"] as? Int == Int(ids["Door Wood Slam 01 copy.wav"]!))

        let groups = try await Self.call(client, "list_groups", ["subcategory": "DOORWood"]).json
        #expect((groups["groups"] as? [[String: Any]])?.first?["sounds"] as? Int == 3)

        let missing = try await Self.call(client, "get_sound", ["sound_id": 424242])
        #expect(missing.error && missing.text.contains("no sound 424242"))
        let unanalysed = try await Self.call(client, "find_similar", ["sound_id": .int(Int(ids["Door Creak.wav"]!))])
        #expect(unanalysed.error && unanalysed.text.contains("analysed"))
        await server.stop()
    }

    @Test func showingAndPlacing() async throws {
        let (db, ids, _) = try Self.library()
        let recorder = Recorder()
        let (client, server) = try await Self.connect(db, recorder)
        let creak = ids["Door Creak.wav"]!

        _ = try await Self.call(client, "show_in_earmark", ["sound_id": .int(Int(creak))])
        #expect(recorder.opened == [URL(string: "earmark://sound/\(creak)")!])

        // Defaults: the whole file at the playhead on an "Earmark" track.
        let placed = try await Self.call(client, "add_to_resolve", [
            "items": [["sound_id": .int(Int(creak))],
                      ["sound_id": .int(Int(creak)), "start": 0.5, "end": 1.5, "at": 12.25, "track": "free"],
                      ["sound_id": .int(Int(creak)), "at": "01:00:10:00", "track": 2]],
            "preview": true,
        ])
        #expect(!placed.error)
        let items = recorder.items
        #expect(recorder.preview)
        #expect(items.count == 3 && items[0].track == .earmark && items[0].at == nil && items[0].length == 3 && items[0].channels == 2)
        #expect(items[1].start == 0.5 && items[1].end == 1.5 && items[1].at == .seconds(12.25) && items[1].track == .free)
        #expect(items[2].at == .timecode("01:00:10:00") && items[2].track == .index(2))
        let answer = placed.json["items"] as? [[String: Any]]
        #expect(answer?.first?["placed"] as? Bool == true && answer?.first?["trackName"] as? String == "Earmark")
        #expect(placed.json["timeline"] as? String == "Edit 1")

        // An offline file isn't sent to Resolve.
        try FileManager.default.removeItem(atPath: try #require(try db.sounds().first { $0.id == creak }).path)
        let offline = try await Self.call(client, "add_to_resolve", ["items": [["sound_id": .int(Int(creak))]]])
        #expect(offline.error && offline.text.contains("offline"))

        let status = try await Self.call(client, "resolve_status")
        #expect(status.error && status.text.contains("External scripting"))
        await server.stop()
    }

    @Test func aPlacementResolveRefused() async throws {
        let (db, ids, _) = try Self.library()
        let (client, server) = try await Self.connect(db, Recorder(), placements: [ResolveBridge.Placement(error: "busy")])
        let r = try await Self.call(client, "add_to_resolve", ["items": [["sound_id": .int(Int(ids["Forest Night.wav"]!)), "track": 1]]])
        let item = (r.json["items"] as? [[String: Any]])?.first
        #expect(item?["placed"] as? Bool == false && item?["problem"] as? String == "That track has a clip there.")
        await server.stop()
    }

    @Test func savingATimelineFile() async throws {
        let (db, ids, root) = try Self.library()
        let folder = root.appendingPathComponent("Timelines")
        let (client, server) = try await Self.connect(db, Recorder(), timelineFolder: folder)
        let creak = Int(ids["Door Creak.wav"]!), slam = Int(ids["Door Wood Slam 01.wav"]!)
        let items: Value = [["sound_id": .int(creak)], ["sound_id": .int(slam), "start": 0.2, "end": 1, "at": 1]]

        let saved = try await Self.call(client, "save_timeline_file", ["items": items, "frame_rate": "29.97 DF", "name": "Doors: take 1"])
        #expect(!saved.error)
        let path = try #require(saved.json["path"] as? String)
        #expect(path == folder.appendingPathComponent("Doors- take 1.fcpxml").path)
        let xml = try String(contentsOfFile: path, encoding: .utf8)
        #expect(xml.contains(#"tcFormat="DF""#) && xml.contains(#"<project name="Doors- take 1">"#))
        let placed = saved.json["items"] as? [[String: Any]]
        #expect(placed?.map { $0["track"] as? Int } == [1, 2])
        #expect(placed?.first?["start"] as? String == "01:00:00;00" && placed?.last?["start"] as? String == "01:00:01;00")

        // Never overwrites; a frame rate it doesn't know is refused.
        let again = try await Self.call(client, "save_timeline_file", ["items": items, "frame_rate": 29.97, "name": "Doors: take 1"])
        #expect(again.json["path"] as? String == folder.appendingPathComponent("Doors- take 1 2.fcpxml").path)
        let bad = try await Self.call(client, "save_timeline_file", ["items": items, "frame_rate": "12"])
        #expect(bad.error && bad.text.contains("29.97 DF"))
        await server.stop()
    }
}
