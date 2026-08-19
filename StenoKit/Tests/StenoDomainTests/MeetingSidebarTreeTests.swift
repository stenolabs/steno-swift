import Foundation
import Testing
@testable import StenoDomain

@Suite("Meeting sidebar tree")
struct MeetingSidebarTreeTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private var now: Date {
        calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 16,
            hour: 14
        ))!
    }

    @Test("folders form a two-level tree and every meeting appears once")
    func buildsTreeAndPartitionsMeetings() {
        let work = folder(1, name: "Arbeit", sortIndex: 0)
        let product = folder(
            2,
            name: "Produktvorstellung",
            parentFolderID: work.id,
            sortIndex: 0
        )
        let personal = folder(3, name: "Privat", sortIndex: 1)
        let direct = meeting(1, title: "Team", folderID: work.id)
        let demo = meeting(2, title: "Demo", folderID: product.id)
        let loose = meeting(3, title: "Lose")
        let orphan = meeting(4, title: "Verwaist", folderID: folderID(99))

        let tree = MeetingSidebarTree.build(
            for: [direct, demo, loose, orphan],
            folders: [work, product, personal],
            now: now,
            calendar: calendar
        )

        #expect(tree.folderNodes.map(\.folder.id) == [work.id, personal.id])
        #expect(tree.folderNodes[0].meetings.map(\.id) == [direct.id])
        #expect(tree.folderNodes[0].children.map(\.folder.id) == [product.id])
        #expect(tree.folderNodes[0].children[0].meetings.map(\.id) == [demo.id])
        #expect(tree.folderNodes[1].meetings.isEmpty)
        #expect(tree.unfiledSections.map(\.title) == ["Today"])
        #expect(tree.unfiledSections.flatMap(\.meetings).map(\.id) == [
            loose.id, orphan.id,
        ])

        let allIDs = filedMeetings(in: tree).map(\.id)
            + tree.unfiledSections.flatMap(\.meetings).map(\.id)
        #expect(allIDs.count == 4)
        #expect(Set(allIDs) == Set([direct.id, demo.id, loose.id, orphan.id]))
    }

    @Test("duplicate folder ids produce one node")
    func deduplicatesFolderIDs() {
        let first = folder(1, name: "Erster", sortIndex: 0)
        let duplicate = Folder(
            id: first.id,
            name: "Duplikat",
            sortIndex: 1,
            createdAt: now
        )
        let filed = meeting(1, title: "Termin", folderID: first.id)

        let tree = MeetingSidebarTree.build(
            for: [filed],
            folders: [first, duplicate],
            now: now,
            calendar: calendar
        )

        #expect(tree.folderNodes.count == 1)
        #expect(tree.folderNodes[0].folder.name == "Erster")
        #expect(tree.folderNodes[0].meetings.map(\.id) == [filed.id])
    }

    @Test("invalid parents cycles and third levels remain visible at top level")
    func fallsBackInvalidHierarchyToRoot() {
        let root = folder(1, name: "Root", sortIndex: 0)
        let child = folder(
            2,
            name: "Child",
            parentFolderID: root.id,
            sortIndex: 0
        )
        let thirdLevel = folder(
            3,
            name: "Third",
            parentFolderID: child.id,
            sortIndex: 0
        )
        let unknown = folder(
            4,
            name: "Unknown",
            parentFolderID: folderID(99),
            sortIndex: 0
        )
        let cycleAID = folderID(5)
        let cycleBID = folderID(6)
        let cycleA = Folder(
            id: cycleAID,
            name: "Cycle A",
            parentFolderID: cycleBID,
            sortIndex: 0,
            createdAt: now
        )
        let cycleB = Folder(
            id: cycleBID,
            name: "Cycle B",
            parentFolderID: cycleAID,
            sortIndex: 0,
            createdAt: now
        )

        let tree = MeetingSidebarTree.build(
            for: [],
            folders: [root, child, thirdLevel, unknown, cycleA, cycleB],
            now: now,
            calendar: calendar
        )

        #expect(tree.folderNodes[tree.folderNodes.firstIndex {
            $0.id == root.id
        }!].children.map(\.id) == [child.id])
        #expect(Set(tree.folderNodes.map(\.id)) == Set([
            root.id, thirdLevel.id, unknown.id, cycleA.id, cycleB.id,
        ]))
        #expect(tree.folderNodes.flatMap(\.children).map(\.id) == [child.id])
    }

    @Test("search hiding keeps a matching child and its full parent path")
    func hidesOnlyEmptyBranches() {
        let work = folder(1, name: "Arbeit", sortIndex: 0)
        let product = folder(
            2,
            name: "Produkt",
            parentFolderID: work.id,
            sortIndex: 0
        )
        let emptyChild = folder(
            3,
            name: "Leer",
            parentFolderID: work.id,
            sortIndex: 1
        )
        let personal = folder(4, name: "Privat", sortIndex: 1)
        let hit = meeting(1, title: "Treffer", folderID: product.id)

        let normal = MeetingSidebarTree.build(
            for: [hit],
            folders: [work, product, emptyChild, personal],
            now: now,
            calendar: calendar
        )
        let searching = MeetingSidebarTree.build(
            for: [hit],
            folders: [work, product, emptyChild, personal],
            now: now,
            calendar: calendar,
            hidesEmptyFolders: true
        )

        #expect(normal.folderNodes.map(\.id) == [work.id, personal.id])
        #expect(normal.folderNodes[0].children.map(\.id) == [
            product.id, emptyChild.id,
        ])
        #expect(searching.folderNodes.map(\.id) == [work.id])
        #expect(searching.folderNodes[0].children.map(\.id) == [product.id])
        #expect(searching.folderNodes[0].children[0].meetings.map(\.id) == [hit.id])
    }

    @Test("equal sort indices use name and id as stable tie breakers")
    func sortsDeterministically() {
        let zulu = folder(3, name: "Zulu", sortIndex: 0)
        let sameHigh = folder(2, name: "Same", sortIndex: 0)
        let alpha = folder(4, name: "Alpha", sortIndex: 0)
        let sameLow = folder(1, name: "Same", sortIndex: 0)

        let tree = MeetingSidebarTree.build(
            for: [],
            folders: [zulu, sameHigh, alpha, sameLow],
            now: now,
            calendar: calendar
        )

        #expect(tree.folderNodes.map(\.id) == [
            alpha.id, sameLow.id, sameHigh.id, zulu.id,
        ])
    }

    private func folder(
        _ value: Int,
        name: String,
        parentFolderID: FolderID? = nil,
        sortIndex: Int
    ) -> Folder {
        Folder(
            id: folderID(value),
            name: name,
            parentFolderID: parentFolderID,
            sortIndex: sortIndex,
            createdAt: now
        )
    }

    private func meeting(
        _ value: Int,
        title: String,
        folderID: FolderID? = nil
    ) -> Meeting {
        Meeting(
            id: MeetingID(rawValue: uuid(value)),
            title: title,
            createdAt: now,
            status: .ready,
            folderID: folderID
        )
    }

    private func folderID(_ value: Int) -> FolderID {
        FolderID(rawValue: uuid(value))
    }

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(
            format: "00000000-0000-7000-8000-%012d",
            value
        ))!
    }

    private func filedMeetings(in tree: MeetingSidebarTree) -> [Meeting] {
        tree.folderNodes.flatMap { node in
            node.meetings + node.children.flatMap(\.meetings)
        }
    }
}
