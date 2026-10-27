import EarmarkMCP
import Foundation

// Earmark's MCP server (docs/mcp-plan.md): MCP clients start it and talk over stdin/stdout.
//   claude mcp add earmark -- "/Applications/Earmark.app/Contents/MacOS/earmark-mcp"
// EARMARK_DATABASE points it at another database (tests, copies). Reads only.
if CommandLine.arguments.contains("--version") {
    print("earmark-mcp \(EarmarkServer.version)")
    exit(0)
}
do {
    try await EarmarkServer.runStdio(databasePath: EarmarkServer.defaultDatabasePath)
} catch {
    FileHandle.standardError.write(Data("earmark-mcp: \(error.localizedDescription)\n".utf8))
    exit(1)
}
