import EarmarkCore
import Foundation

/// The FCPXML timeline file through the Rust engine: the same text and placements as
/// `TimelineFile.fcpxml`, and the same failures.
public enum EngineTimeline {
    public static func fcpxml(_ clips: [TimelineFile.Clip], rate: TimelineFile.Rate, startTimecode: String = "01:00:00:00",
                              name: String) throws -> (xml: String, placements: [TimelineFile.Placement]) {
        do {
            let made = try timelineFcpxml(
                clips: clips.map {
                    TimelineClip(path: $0.path, name: $0.name, length: $0.length, sampleRate: Int64($0.sampleRate),
                                 channels: Int64($0.channels), timeReference: $0.timeReference, start: $0.start, end: $0.end, at: $0.at)
                },
                rate: rate.name, startTimecode: startTimecode, name: name)
            return (made.xml, made.placements.map { TimelineFile.Placement(lane: Int($0.lane), start: $0.start, end: $0.end) })
        } catch TimelineError.BadTimecode(let timecode) {
            throw TimelineFile.Failure.badTimecode(timecode)
        } catch TimelineError.TooShort(let name) {
            throw TimelineFile.Failure.tooShort(name)
        } catch TimelineError.Nothing {
            throw TimelineFile.Failure.nothing
        } catch TimelineError.UnknownRate {
            // Every Rate the app offers is one the engine knows; Swift's own code still makes this one.
            return try TimelineFile.fcpxml(clips, rate: rate, startTimecode: startTimecode, name: name)
        }
    }
}
