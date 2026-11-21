import EarmarkCore
import Foundation

/// Adding sounds to the timeline open in DaVinci Resolve Studio through the Rust engine: the same
/// bridge script, requests and answers as `ResolveBridge.add`, and the same failures.
public enum EngineResolve {
    public static func add(_ items: [ResolveBridge.Item], preview: Bool = false,
                           movePlayhead: Bool = false) async throws -> ResolveBridge.Added {
        let request = items.map { i in
            ResolveItem(path: i.path, start: i.start, end: i.end,
                        at: i.at.map { switch $0 { case .timecode(let tc): .timecode(timecode: tc)
                                                   case .seconds(let s): .seconds(seconds: s) } },
                        track: { switch i.track { case .free: .free
                                                  case .earmark: .earmark
                                                  case .index(let n): .index(index: Int64(n)) } }(),
                        length: i.length, channels: i.channels.map(Int64.init))
        }
        do {
            // The engine waits for Resolve (up to a minute): off the caller's thread.
            let added = try await Task.detached(priority: .userInitiated) {
                try resolveAdd(items: request, preview: preview, movePlayhead: movePlayhead)
            }.value
            return ResolveBridge.Added(project: added.project, timeline: added.timeline, items: added.items.map {
                ResolveBridge.Placement(ok: $0.ok, error: $0.error, track: $0.track.map(Int.init), trackName: $0.trackName,
                                        start: $0.start, end: $0.end, newTrack: $0.newTrack)
            })
        } catch let e as ResolveError {
            switch e {
            case .NotInstalled: throw ResolveBridge.Failure.notInstalled
            case .NotConnected: throw ResolveBridge.Failure.notConnected
            case .NoProject: throw ResolveBridge.Failure.noProject
            case .NoTimeline: throw ResolveBridge.Failure.noTimeline
            case .Other(let detail): throw ResolveBridge.Failure.other(detail)
            }
        }
    }
}
