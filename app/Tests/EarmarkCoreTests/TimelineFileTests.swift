import Foundation
import Testing
@testable import EarmarkCore

@Suite struct TimelineFileTests {
    let rate25 = TimelineFile.Rate.named("25")!
    let df = TimelineFile.Rate.named("29.97 DF")!

    func clip(_ name: String, length: Double = 4, at: Double? = nil, start: Double? = nil, end: Double? = nil,
              timeReference: Int64 = 0) -> TimelineFile.Clip {
        .init(path: "/Volumes/Banana 01/SFX/\(name).wav", name: name, length: length, sampleRate: 48000, channels: 2,
              timeReference: timeReference, start: start, end: end, at: at)
    }

    @Test func rational() {
        #expect(Rational(3600, 1).description == "3600s")
        #expect(Rational(2002, 60000).description == "1001/30000s")
        #expect((Rational(1, 25) + Rational(1, 48000)).description == "1921/48000s")
        #expect(Rational(0, 25).description == "0s")
    }

    @Test func timecodes() {
        #expect(TimelineFile.frames("01:00:00:00", rate25) == 90000)
        #expect(TimelineFile.frames("01:00:00;00", df) == 107892)
        #expect(TimelineFile.frames("00:01:00;02", df) == 1800)
        #expect(TimelineFile.timecode(1800, df) == "00:01:00;02")
        #expect(TimelineFile.timecode(107892, df) == "01:00:00;00")
        #expect(TimelineFile.timecode(17982, df) == "00:10:00;00")
        #expect(TimelineFile.frames("1:00:00", rate25) == nil)
        #expect(TimelineFile.frames("00:00:00:25", rate25) == nil)
        for n: Int64 in [0, 1, 1799, 1800, 1801, 17981, 17982, 107892, 123456] {
            #expect(TimelineFile.frames(TimelineFile.timecode(n, df), df) == n)
        }
    }

    @Test func endToEndAndLanes() throws {
        let (xml, placed) = try TimelineFile.fcpxml(
            [clip("A"), clip("B", length: 2), clip("C", at: 1), clip("A", at: 10, start: 1.01, end: 2)], rate: rate25, name: "Test")
        #expect(placed == [
            .init(lane: 1, start: "01:00:00:00", end: "01:00:04:00"),
            .init(lane: 1, start: "01:00:04:00", end: "01:00:06:00"),
            .init(lane: 2, start: "01:00:01:00", end: "01:00:05:00"),
            .init(lane: 1, start: "01:00:10:00", end: "01:00:11:00"),
        ])
        // One asset per file; the range is rounded outwards to frames (1.01 s → frame 25).
        #expect(xml.components(separatedBy: "<asset ").count == 4)
        #expect(xml.contains(#"<asset-clip ref="r1" lane="-1" offset="3610s" name="A" start="1s" duration="1s""#))
        #expect(xml.contains(#"<asset-clip ref="r3" lane="-2" offset="3601s""#))
        #expect(xml.contains(#"tcStart="3600s" tcFormat="NDF""#))
        #expect(xml.contains(#"<gap name="Gap" offset="3600s" start="3600s" duration="11s">"#))
        #expect(xml.contains(#"src="file:///Volumes/Banana%2001/SFX/A.wav""#))
    }

    @Test func dropFrameAndTimeReference() throws {
        // A BWF file starting at 10:00:00 (48 kHz): the asset starts there and so does the cut.
        let (xml, placed) = try TimelineFile.fcpxml([clip("T", start: 0.5, end: 1, timeReference: 1_728_000_000)], rate: df,
                                                    startTimecode: "01:00:00;00", name: "DF")
        #expect(placed.first?.start == "01:00:00;00")
        #expect(placed.first?.end == "01:00:00;16")
        #expect(xml.contains(#"tcFormat="DF""#))
        #expect(xml.contains(#"tcStart="8999991/2500s""#))
        #expect(xml.contains(#"start="36000s" duration="4s""#))
        // Frame 14 at 29.97: 36000 + 14 × 1001/30000.
        #expect(xml.contains(#"start="540007007/15000s" duration="1001/1875s""#))
    }

    @Test func escapingAndFailures() throws {
        var c = clip("Rain & \"Thunder\" <loud>")
        c.path = "/tmp/Ação & co/x.wav"
        let (xml, _) = try TimelineFile.fcpxml([c], rate: rate25, name: "A & B")
        #expect(xml.contains(#"name="Rain &amp; &quot;Thunder&quot; &lt;loud&gt;""#))
        #expect(xml.contains(#"<project name="A &amp; B">"#))
        #expect(xml.contains("file:///tmp/A%C3%A7%C3%A3o%20&amp;%20co/x.wav"))
        #expect(throws: TimelineFile.Failure.tooShort("S")) {
            try TimelineFile.fcpxml([clip("S", start: 1, end: 1)], rate: rate25, name: "x")
        }
        #expect(throws: TimelineFile.Failure.badTimecode("x")) {
            try TimelineFile.fcpxml([clip("S")], rate: rate25, startTimecode: "x", name: "x")
        }
        #expect(throws: TimelineFile.Failure.nothing) { try TimelineFile.fcpxml([], rate: rate25, name: "x") }
    }
}
