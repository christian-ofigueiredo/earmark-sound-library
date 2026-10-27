import Foundation
import Testing
@testable import EarmarkCore

/// Similarity groups in the database: what gets regrouped, and the owner's changes.
@Suite struct SoundGroupStoreTests {
    static func name(_ s: String) -> SoundGroups.Name { .init(name: s, aiWords: ["a", "b"], shapeWords: [], keywords: ["k"]) }

    static func sounds(_ ids: ClosedRange<Int64>) -> [(id: Int64, fingerprint: String?)] { ids.map { ($0, "f\($0)") } }

    @Test func newSubcategoriesAreGroupedAndUnchangedOnesLeftAlone() throws {
        let db = try LibraryDatabase(path: nil)
        var work = SoundGroupPlan.work(sounds: ["DSGNWhsh": Self.sounds(1 ... 40)], stored: try db.soundGroupSnapshot())
        #expect(work == [.regroup(catID: "DSGNWhsh", sounds: Array(1 ... 40))])
        try db.replaceGroups(catID: "DSGNWhsh", groups: [Array(Self.sounds(1 ... 25)), Array(Self.sounds(26 ... 40))],
                             names: [Self.name("Long · Airy"), Self.name("Short · Metallic")])
        let snap = try db.soundGroupSnapshot()
        #expect(snap.groups["DSGNWhsh"]?.map(\.name) == ["Long · Airy", "Short · Metallic"])
        #expect(snap.groups["DSGNWhsh"]?.first?.keywordList == ["k"])
        #expect(snap.membership.count == 40)
        work = SoundGroupPlan.work(sounds: ["DSGNWhsh": Self.sounds(1 ... 40)], stored: snap)
        #expect(work.isEmpty)
    }

    @Test func fewNewSoundsJoinManyRegroup() throws {
        let db = try LibraryDatabase(path: nil)
        try db.replaceGroups(catID: "DSGNWhsh", groups: [Array(Self.sounds(1 ... 25)), Array(Self.sounds(26 ... 40))],
                             names: [Self.name("A"), Self.name("B")])
        // 5 more, and one file changed: joined, not regrouped.
        var current = Self.sounds(1 ... 45)
        current[0].fingerprint = "changed"
        var work = SoundGroupPlan.work(sounds: ["DSGNWhsh": current], stored: try db.soundGroupSnapshot())
        #expect(work == [.update(catID: "DSGNWhsh", add: [1, 41, 42, 43, 44, 45], remove: [1])])
        let groups = try db.soundGroupSnapshot().groups["DSGNWhsh"]!.compactMap(\.id)
        try db.updateGroups(catID: "DSGNWhsh", add: [(1, "changed", groups[0])] + (41 ... 45).map { ($0, "f\($0)", groups[1]) },
                            remove: [1])
        let snap = try db.soundGroupSnapshot()
        #expect(snap.membership[1] == groups[0] && snap.memberFingerprints[1] == "changed")
        #expect(snap.membership[45] == groups[1])
        #expect(snap.sets["DSGNWhsh"]?.changed == 7)
        // Another 4 makes 11 of 40 changed: regrouped.
        work = SoundGroupPlan.work(sounds: ["DSGNWhsh": current + Self.sounds(46 ... 49)], stored: snap)
        #expect(work == [.regroup(catID: "DSGNWhsh", sounds: Array(1 ... 49))])
    }

    @Test func soundsMovingCategoryAndEmptySubcategories() throws {
        let db = try LibraryDatabase(path: nil)
        try db.replaceGroups(catID: "A", groups: [Array(Self.sounds(1 ... 30))], names: [Self.name("A1")])
        try db.replaceGroups(catID: "B", groups: [Array(Self.sounds(31 ... 60))], names: [Self.name("B1")])
        // Sound 1 is now B's; A has nothing left of its own but the rest; C is gone entirely.
        try db.replaceGroups(catID: "C", groups: [Array(Self.sounds(61 ... 62))], names: [Self.name("C1")])
        let work = SoundGroupPlan.work(sounds: ["A": Self.sounds(2 ... 30), "B": Self.sounds(31 ... 60) + [(1, "f1")]],
                                       stored: try db.soundGroupSnapshot())
        #expect(work.contains(.update(catID: "A", add: [], remove: [1])))
        #expect(work.contains(.update(catID: "B", add: [1], remove: [])))
        #expect(work.contains(.drop(catID: "C")))
        // B's join happens first; A's leave mustn't undo it.
        let b = try db.soundGroupSnapshot().groups["B"]!.first!.id!
        try db.updateGroups(catID: "B", add: [(1, "f1", b)], remove: [])
        try db.updateGroups(catID: "A", add: [], remove: [1])
        try db.dropGroups(catID: "C")
        let snap = try db.soundGroupSnapshot()
        #expect(snap.membership[1] == b)
        #expect(snap.groups["C"] == nil && snap.sets["C"] == nil && snap.membership[61] == nil)
    }

    @Test func theOwnersChangesStick() throws {
        let db = try LibraryDatabase(path: nil)
        try db.replaceGroups(catID: "A", groups: [Array(Self.sounds(1 ... 20)), Array(Self.sounds(21 ... 30)), Array(Self.sounds(31 ... 40))],
                             names: [Self.name("One"), Self.name("Two"), Self.name("Three")])
        let ids = try db.soundGroupSnapshot().groups["A"]!.compactMap(\.id)
        try db.renameGroup(ids[0], to: "  Big swells ")
        var snap = try db.soundGroupSnapshot()
        #expect(snap.byId[ids[0]]?.title == "Big swells" && snap.byId[ids[0]]?.name == "One")
        #expect(snap.sets["A"]?.edited == true)
        try db.renameGroup(ids[0], to: "")
        #expect(try db.soundGroupSnapshot().byId[ids[0]]?.userName == nil)

        // Move all of Two's sounds out: Two goes.
        try db.moveSounds(Array(Self.sounds(21 ... 30)), toGroup: ids[2])
        snap = try db.soundGroupSnapshot()
        #expect(snap.groups["A"]?.count == 2 && snap.membership[25] == ids[2])
        let made = try db.newGroup(catID: "A", name: "Mine", sounds: Array(Self.sounds(1 ... 3)))
        try db.mergeGroups([ids[2]], into: ids[0])
        snap = try db.soundGroupSnapshot()
        #expect(snap.groups["A"]?.map(\.title) == ["One", "Mine"])
        #expect(snap.membership[1] == made && snap.membership[35] == ids[0])

        // Edited: lots of new sounds only join.
        let work = SoundGroupPlan.work(sounds: ["A": Self.sounds(1 ... 80)], stored: snap)
        #expect(work == [.update(catID: "A", add: Array(41 ... 80), remove: [])])
        // Regroup forgets the changes.
        try db.regroup(catID: "A")
        #expect(SoundGroupPlan.work(sounds: ["A": Self.sounds(1 ... 80)], stored: try db.soundGroupSnapshot())
                == [.regroup(catID: "A", sounds: Array(1 ... 80))])
    }

    @Test func newSoundsJoinTheNearestGroup() {
        // Two groups along x and y; a sound near y joins the second.
        let x: [Float] = [1, 0, 0.9, 0.1, 0, 1, 0.1, 0.9]
        let g = x.withUnsafeBufferPointer { SoundGroupPlan.nearest([0.2, 0.98], x: $0, d: 2, members: [7: [0, 1], 9: [2, 3]]) }
        #expect(g == 9)
    }
}
