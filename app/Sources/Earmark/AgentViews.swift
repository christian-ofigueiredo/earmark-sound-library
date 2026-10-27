import AppKit
import EarmarkCore
import SwiftUI

// MARK: earmark:// links

extension AppModel {
    /// `earmark://sound/<id>` (the MCP server's show_in_earmark): Sound Effects, that sound
    /// selected in its list (or on the map), and Earmark in front.
    func open(_ url: URL) {
        // A link that launched Earmark arrives before the library is read: shown once it is.
        guard hasLoaded else { pendingLink = url; return }
        guard url.scheme == "earmark", url.host == "sound", let id = Int64(url.lastPathComponent), sound(id: id) != nil else { return }
        show(.sounds)
        soundBrowser.reveal(id)
        NSApp.activate()
    }
}

// MARK: Help ▸ Connect an AI Agent…

/// How to give an AI agent (Claude Code, the Claude desktop app, other MCP clients) Earmark's
/// tools: the server inside this app and the lines to set it up, ready to copy.
struct ConnectAgentView: View {
    static let windowID = "connect-agent"

    /// earmark-mcp beside the app's own executable.
    private var server: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/earmark-mcp").path
    }

    private var claudeCode: String { "claude mcp add earmark -- \"\(server)\"" }

    private var desktopConfig: String {
        """
        "earmark": {
          "command": "\(server)"
        }
        """
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect an AI Agent").font(.title2.weight(.semibold))
            Text("Earmark includes an MCP server, so an AI agent can search your sound libraries, look at a sound's details, "
                 + "find similar sounds, and put sounds on the timeline open in DaVinci Resolve. It only reads your libraries "
                 + "and Earmark's data, and works with Earmark closed. Your agent asks you before it places sounds.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !FileManager.default.isExecutableFile(atPath: server) {
                Label("This copy of Earmark doesn't have its MCP server (earmark-mcp). Build it with scripts/build-app.sh.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            block("Claude Code: run this in Terminal", claudeCode)
            block("Claude desktop app: add this under \"mcpServers\" in Settings ▸ Developer ▸ Edit Config", desktopConfig)
            VStack(alignment: .leading, spacing: 4) {
                Text("Tools").font(.headline)
                Text("library_overview · search_sounds · get_sound · find_similar · list_groups · show_in_earmark · "
                     + "resolve_status · add_to_resolve")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Sounds an agent places go on audio tracks named “Earmark”, so they're easy to find. "
                     + "If Earmark moves (e.g. to Applications), set it up again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func block(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            HStack(alignment: .top) {
                Text(text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                Button("Copy") { copyToPasteboard(text) }
            }
        }
    }
}
