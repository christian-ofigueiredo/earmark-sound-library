import Foundation
import MCP

/// The MCP server: Earmark's tools over a transport (stdio for clients that start
/// `earmark-mcp`; in memory for tests).
public enum EarmarkServer {
    public static let version = "1.0"

    /// A server answering with these tools, not yet started.
    public static func make(_ tools: EarmarkTools) async -> Server {
        let server = Server(name: "Earmark", version: version, title: "Earmark sound library",
                            instructions: EarmarkTools.instructions,
                            capabilities: .init(tools: .init(listChanged: false)))
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: EarmarkTools.definitions) }
        await server.withMethodHandler(CallTool.self) { params in await tools.call(params.name, params.arguments ?? [:]) }
        return server
    }

    /// Serves on standard input and output until the client goes.
    public static func runStdio(databasePath: String) async throws {
        let server = await make(EarmarkTools(databasePath: databasePath))
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }

    /// Earmark's database: `EARMARK_DATABASE` if set, else the app's own.
    public static var defaultDatabasePath: String {
        if let path = ProcessInfo.processInfo.environment["EARMARK_DATABASE"], !path.isEmpty { return path }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Earmark/library.sqlite").path
    }
}
