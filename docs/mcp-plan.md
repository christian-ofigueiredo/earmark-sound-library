# Earmark MCP server: plan

Approved by the owner on 2026-10-27, with the recommended answers to the three decisions:
read-only for Earmark's data, works with Earmark closed, agent batches on new "Earmark" tracks.

## What it is

`earmark-mcp`, a small command-line program inside Earmark.app that MCP clients (Claude Code,
the Claude desktop app, other agents) start and talk to over standard input/output, the usual
way for local MCP servers. Built with the official MCP Swift SDK (`modelcontextprotocol/swift-sdk`,
0.12.x, pinned to the minor version since 0.x minors change its API; MCP spec 2025-11-25).

Built 2026-10-27: see docs/HANDOFF.md ("MCP server") for what was checked.

- It reads Earmark's database read-only, so it works with Earmark closed, and applies the same
  rules as the app: categories (the owner's, Earmark's guesses), format twins, groups, duplicates.
- It never writes sound files and, in this version, doesn't change Earmark's data.
- Resolve placement uses the same bridge as ⌘T, extended with a timecode and a track.

## Tools

| Tool | What it does | Changes anything? |
|---|---|---|
| `library_overview` | Libraries (online?), counts, categories and subcategories with counts, analysis progress | No |
| `search_sounds` | The app's search plus filters (category, subcategory, group, library, length, source); short rows | No |
| `get_sound` | What the detail pane shows: metadata, category and source, group and keywords, loudness, other formats, duplicates | No |
| `find_similar` | A sound's nearest sounds, as Find Similar Sounds | No |
| `list_groups` | A subcategory's similarity groups | No |
| `show_in_earmark` | Opens Earmark on that sound, selected | Only what the app shows |
| `resolve_status` | Resolve reachable? Project, timeline, frame rate, playhead, audio tracks | No |
| `add_to_resolve` | One or many sounds (or ranges) at a timecode or the playhead, on a given track, the first free one or a new "Earmark" track (the default for agents); `preview` says where without placing | Adds to the open timeline |

## Changes in Earmark

1. Shared code into the core: the search text, `ResolveBridge`, the category rules.
2. The database in WAL mode (GRDB `DatabasePool`), so the server reads while the app writes.
3. An `earmark://sound/<id>` link scheme for `show_in_earmark`.
4. A new `earmark-mcp` target in `Earmark.app/Contents/MacOS`; the SDK as a dependency;
   THIRD_PARTY_NOTICES updated.
5. Help ▸ Connect an AI Agent…: the setup line for Claude Code and the settings for the Claude
   desktop app, with copy buttons.

## Testing

Unit tests for each tool on an in-memory database; a protocol test (start, initialise, list
tools, call each); the owner's library through the server; three sounds placed at timecodes in a
temporary Resolve project (deleted afterwards); the server reading while the app analyses.

## Not in this version

Agents changing categories or groups; agents listening to sounds; video-to-sound matching; an
HTTP transport for other machines; packaging as a Claude desktop extension.
