import Foundation
import StenoDomain
import Testing
@testable import StenoLibrary

@Suite("FolderStore")
struct FolderStoreTests {
    @Test("folders persist with a schema version and keep their order")
    func persistsFolders() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let store = try FolderStore.open(layout: library.layout)

            let work = try await store.createFolder(name: "  Work   Projects ")
            let personal = try await store.createFolder(name: "Personal")

            #expect(work.name == "Work Projects")
            #expect(work.sortIndex == 0)
            #expect(personal.sortIndex == 1)

            let reopened = try FolderStore.open(layout: library.layout)
            #expect(try await reopened.listFolders().map(\.name) == [
                "Work Projects", "Personal",
            ])
            let document = try JSONSerialization.jsonObject(
                with: Data(contentsOf: library.layout.folders)
            ) as? [String: Any]
            #expect(document?["schemaVersion"] as? Int == 2)
        }
    }

    @Test("schema 1 migrates to schema 2 without quarantine")
    func migratesLegacyFolders() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let legacy = """
            {
              "adoptedLegacyFolders" : true,
              "folders" : [
                {
                  "createdAt" : 0,
                  "id" : "00000000-0000-7000-8000-000000000001",
                  "name" : "Arbeit",
                  "sortIndex" : 0
                }
              ],
              "schemaVersion" : 1
            }
            """
            try Data(legacy.utf8).write(to: library.layout.folders)

            let store = try FolderStore.open(layout: library.layout)
            let folders = try await store.listFolders()

            #expect(folders.count == 1)
            #expect(folders[0].parentFolderID == nil)
            let object = try #require(JSONSerialization.jsonObject(
                with: Data(contentsOf: library.layout.folders)
            ) as? [String: Any])
            #expect(object["schemaVersion"] as? Int == 2)
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path)
                .allSatisfy { !$0.contains("corrupt-") })
        }
    }

    @Test("ordinary reads do not rewrite schema 2")
    func readsWithoutWriting() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let store = try FolderStore.open(layout: library.layout)
            _ = try await store.createFolder(name: "Arbeit")
            let before = try Data(contentsOf: library.layout.folders)

            _ = try await store.listFolders()
            _ = try await store.listFolders()

            #expect(try Data(contentsOf: library.layout.folders) == before)
        }
    }

    @Test("schema 2 folders without a parent decode as top-level folders")
    func decodesMissingParentAsTopLevel() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let document = """
            {
              "adoptedLegacyFolders" : false,
              "folders" : [
                {
                  "createdAt" : 0,
                  "id" : "00000000-0000-7000-8000-000000000001",
                  "name" : "Arbeit",
                  "sortIndex" : 0
                }
              ],
              "schemaVersion" : 2
            }
            """
            try Data(document.utf8).write(to: library.layout.folders)

            let folder = try #require(try await FolderStore.open(
                layout: library.layout
            ).listFolders().first)

            #expect(folder.name == "Arbeit")
            #expect(folder.parentFolderID == nil)
        }
    }

    @Test("unknown folder schemas remain untouched")
    func rejectsUnknownSchemaWithoutQuarantine() throws {
        try withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let document = """
            {
              "adoptedLegacyFolders" : false,
              "folders" : [],
              "schemaVersion" : 3
            }
            """
            let original = Data(document.utf8)
            try original.write(to: library.layout.folders)

            do {
                _ = try FolderStore.open(layout: library.layout)
                Issue.record("Expected unsupportedSchemaVersion")
            } catch let error as LibraryError {
                guard case .unsupportedSchemaVersion(
                    let url,
                    let found,
                    let supported
                ) = error else {
                    Issue.record("Expected unsupportedSchemaVersion, got \(error)")
                    return
                }
                #expect(url == library.layout.folders)
                #expect(found == 3)
                #expect(supported == 2)
            }

            #expect(try Data(contentsOf: library.layout.folders) == original)
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path)
                .allSatisfy { !$0.contains("corrupt-") })
        }
    }

    @Test("folder names are unique independent of case and whitespace")
    func rejectsDuplicateNames() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let store = try FolderStore.open(layout: library.layout)
            let work = try await store.createFolder(name: "Work")
            let personal = try await store.createFolder(name: "Personal")

            await #expect(throws: LibraryError.self) {
                _ = try await store.createFolder(name: "  work ")
            }
            await #expect(throws: LibraryError.self) {
                _ = try await store.renameFolder(personal.id, to: "WORK")
            }
            await #expect(throws: LibraryError.self) {
                _ = try await store.createFolder(name: "   ")
            }

            // Sich selbst gleich zu heissen ist kein Konflikt.
            let renamed = try await store.renameFolder(work.id, to: "work")
            #expect(renamed.name == "work")
        }
    }

    @Test("child folders use names scoped to their parent")
    func createsChildFoldersWithScopedNames() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let store = try FolderStore.open(layout: library.layout)
            let work = try await store.createFolder(name: "Arbeit")
            let privateFolder = try await store.createFolder(name: "Privat")

            let workMeetings = try await store.createFolder(
                name: "Meetings",
                parentFolderID: work.id
            )
            let privateMeetings = try await store.createFolder(
                name: "Meetings",
                parentFolderID: privateFolder.id
            )

            #expect(workMeetings.parentFolderID == work.id)
            #expect(privateMeetings.parentFolderID == privateFolder.id)
            await #expect(throws: LibraryError.self) {
                _ = try await store.createFolder(
                    name: " meetings ",
                    parentFolderID: work.id
                )
            }
        }
    }

    @Test("an unknown parent cannot receive a folder")
    func rejectsUnknownParent() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let store = try FolderStore.open(layout: library.layout)

            await #expect(throws: LibraryError.self) {
                _ = try await store.createFolder(
                    name: "Meetings",
                    parentFolderID: FolderID()
                )
            }
            #expect(try await store.listFolders().isEmpty)
        }
    }

    @Test("a child folder cannot receive another child")
    func rejectsThirdFolderLevel() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let store = try FolderStore.open(layout: library.layout)
            let work = try await store.createFolder(name: "Arbeit")
            let meetings = try await store.createFolder(
                name: "Meetings",
                parentFolderID: work.id
            )

            await #expect(throws: LibraryError.self) {
                _ = try await store.createFolder(
                    name: "Woche",
                    parentFolderID: meetings.id
                )
            }
            #expect(try await store.listFolders().count == 2)
        }
    }

    @Test("a folder cannot move into itself or below its child")
    func rejectsCycles() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let store = try FolderStore.open(layout: library.layout)
            let work = try await store.createFolder(name: "Arbeit")
            let meetings = try await store.createFolder(
                name: "Meetings",
                parentFolderID: work.id
            )

            await #expect(throws: LibraryError.self) {
                _ = try await store.moveFolder(
                    work.id,
                    toParentFolderID: work.id
                )
            }
            await #expect(throws: LibraryError.self) {
                _ = try await store.moveFolder(
                    work.id,
                    toParentFolderID: meetings.id
                )
            }
            #expect(try await store.listFolders().map(\.id) == [work.id, meetings.id])
        }
    }

    @Test("a root with children cannot become a child")
    func rejectsMovingParentBelowAnotherRoot() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let store = try FolderStore.open(layout: library.layout)
            let work = try await store.createFolder(name: "Arbeit")
            _ = try await store.createFolder(
                name: "Meetings",
                parentFolderID: work.id
            )
            let privateFolder = try await store.createFolder(name: "Privat")

            await #expect(throws: LibraryError.self) {
                _ = try await store.moveFolder(
                    work.id,
                    toParentFolderID: privateFolder.id
                )
            }
            #expect(try await store.folder(work.id)?.parentFolderID == nil)
        }
    }

    @Test("moving a folder compacts both sibling groups")
    func movesBetweenParentsAndCompactsSiblings() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let store = try FolderStore.open(layout: library.layout)
            let work = try await store.createFolder(name: "Arbeit")
            let privateFolder = try await store.createFolder(name: "Privat")
            let weekly = try await store.createFolder(
                name: "Woche",
                parentFolderID: work.id
            )
            let product = try await store.createFolder(
                name: "Produkt",
                parentFolderID: work.id
            )
            let family = try await store.createFolder(
                name: "Familie",
                parentFolderID: privateFolder.id
            )

            let moved = try await store.moveFolder(
                weekly.id,
                toParentFolderID: privateFolder.id
            )
            let folders = try await store.listFolders()

            #expect(moved.parentFolderID == privateFolder.id)
            #expect(folders.first { $0.id == product.id }?.sortIndex == 0)
            #expect(folders.first { $0.id == family.id }?.sortIndex == 0)
            #expect(folders.first { $0.id == weekly.id }?.sortIndex == 1)
        }
    }

    @Test("deleting a folder leaves its meetings alone")
    func deleteKeepsMeetings() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let store = try FolderStore.open(layout: library.layout)
            let folder = try await store.createFolder(name: "Work")
            let meeting = try await library.createMeeting(title: "Sync", status: .ready)
            _ = try await library.setMeetingFolder(meeting.id, folderID: folder.id)

            let deletion = try #require(try await store.deleteFolder(folder.id))
            #expect(deletion.deletedFolderID == folder.id)
            #expect(deletion.promotedFolderIDs.isEmpty)
            #expect(try await store.deleteFolder(folder.id) == nil)

            // Das Meeting existiert weiter, seine Kennung zeigt nur ins Leere -
            // und gilt damit ueberall als nicht einsortiert.
            let stored = try await library.loadMeeting(meeting.id)
            #expect(stored.folderID == folder.id)
            let tree = MeetingSidebarTree.build(
                for: [stored],
                folders: try await store.listFolders()
            )
            #expect(tree.folderNodes.isEmpty)
            #expect(tree.unfiledSections.count == 1)
            #expect(tree.unfiledSections[0].meetings.map(\.id) == [meeting.id])
        }
    }

    @Test("reordering rejects incomplete and foreign sibling lists")
    func reorderRequiresExactSiblings() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let store = try FolderStore.open(layout: library.layout)
            let a = try await store.createFolder(name: "A")
            let b = try await store.createFolder(name: "B")
            let c = try await store.createFolder(name: "C")

            let before = try await store.listFolders()
            await #expect(throws: LibraryError.self) {
                try await store.reorderFolders(
                    parentFolderID: nil,
                    order: [c.id, a.id]
                )
            }
            await #expect(throws: LibraryError.self) {
                try await store.reorderFolders(
                    parentFolderID: nil,
                    order: [c.id, a.id, FolderID()]
                )
            }

            #expect(try await store.listFolders() == before)

            try await store.reorderFolders(
                parentFolderID: nil,
                order: [c.id, a.id, b.id]
            )

            #expect(try await store.listFolders().map(\.name) == ["C", "A", "B"])
        }
    }

    @Test("reordering changes only one sibling group")
    func reorderIsScopedToParent() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let store = try FolderStore.open(layout: library.layout)
            let work = try await store.createFolder(name: "Arbeit")
            let privateFolder = try await store.createFolder(name: "Privat")
            let weekly = try await store.createFolder(
                name: "Woche",
                parentFolderID: work.id
            )
            let product = try await store.createFolder(
                name: "Produkt",
                parentFolderID: work.id
            )
            let family = try await store.createFolder(
                name: "Familie",
                parentFolderID: privateFolder.id
            )

            try await store.reorderFolders(
                parentFolderID: work.id,
                order: [product.id, weekly.id]
            )

            let folders = try await store.listFolders()
            #expect(folders.map(\.id) == [
                work.id, product.id, weekly.id, privateFolder.id, family.id,
            ])
            #expect(folders.first { $0.id == family.id }?.sortIndex == 0)
        }
    }

    @Test("deleting a root promotes its children at the same position")
    func deleteRootPromotesChildren() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let store = try FolderStore.open(layout: library.layout)
            let first = try await store.createFolder(name: "Erster")
            let work = try await store.createFolder(name: "Arbeit")
            let last = try await store.createFolder(name: "Letzter")
            let weekly = try await store.createFolder(
                name: "Woche",
                parentFolderID: work.id
            )
            let product = try await store.createFolder(
                name: "Produkt",
                parentFolderID: work.id
            )

            let deletion = try #require(try await store.deleteFolder(work.id))
            let folders = try await store.listFolders()

            #expect(deletion.deletedFolderID == work.id)
            #expect(deletion.promotedFolderIDs == [weekly.id, product.id])
            #expect(folders.map(\.id) == [first.id, weekly.id, product.id, last.id])
            #expect(folders.map(\.sortIndex) == [0, 1, 2, 3])
            #expect(folders.allSatisfy { $0.parentFolderID == nil })
        }
    }

    @Test("deleting a root rejects a promoted name conflict")
    func deleteRootRejectsPromotedNameConflict() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let store = try FolderStore.open(layout: library.layout)
            let existing = try await store.createFolder(name: "Meetings")
            let work = try await store.createFolder(name: "Arbeit")
            let child = try await store.createFolder(
                name: "Meetings",
                parentFolderID: work.id
            )
            let before = try await store.listFolders()

            await #expect(throws: LibraryError.self) {
                _ = try await store.deleteFolder(work.id)
            }

            #expect(try await store.listFolders() == before)
            #expect(try await store.folder(existing.id) != nil)
            #expect(try await store.folder(child.id)?.parentFolderID == work.id)
        }
    }

    @Test("deleting a child leaves other sibling groups unchanged")
    func deleteChildIsScopedToItsParent() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let store = try FolderStore.open(layout: library.layout)
            let work = try await store.createFolder(name: "Arbeit")
            let privateFolder = try await store.createFolder(name: "Privat")
            let weekly = try await store.createFolder(
                name: "Woche",
                parentFolderID: work.id
            )
            let product = try await store.createFolder(
                name: "Produkt",
                parentFolderID: work.id
            )
            let family = try await store.createFolder(
                name: "Familie",
                parentFolderID: privateFolder.id
            )

            let deletion = try #require(try await store.deleteFolder(weekly.id))
            let folders = try await store.listFolders()

            #expect(deletion.promotedFolderIDs.isEmpty)
            #expect(folders.map(\.id) == [
                work.id, product.id, privateFolder.id, family.id,
            ])
            #expect(folders.first { $0.id == product.id }?.sortIndex == 0)
            #expect(folders.first { $0.id == family.id }?.sortIndex == 0)
        }
    }

    @Test("legacy folder names are adopted once, first name wins")
    func adoptsLegacyFoldersOnce() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let store = try FolderStore.open(layout: library.layout)
            let imported = Meeting(
                title: "Imported",
                status: .ready,
                metadata: MeetingMetadata(legacyFolders: ["Kunden", "Archiv"])
            )
            let second = Meeting(
                title: "Also imported",
                status: .ready,
                metadata: MeetingMetadata(legacyFolders: ["kunden"])
            )
            let native = Meeting(title: "Native", status: .ready)

            let assignments = try await store.adoptLegacyFolders(
                from: [imported, second, native]
            )

            let folders = try await store.listFolders()
            // Gleicher Name in anderer Schreibweise ist derselbe Ordner, und
            // "Archiv" als zweiter Alt-Ordner wird nicht angelegt.
            #expect(folders.map(\.name) == ["Kunden"])
            #expect(assignments[imported.id] == folders[0].id)
            #expect(assignments[second.id] == folders[0].id)
            #expect(assignments[native.id] == nil)

            // Solange nicht abgehakt ist, wird erneut versucht: ein Absturz
            // zwischen Lesen und Schreiben darf die Uebernahme nicht fuer
            // immer verbrennen.
            #expect(try await FolderStore.open(layout: library.layout)
                .adoptLegacyFolders(from: [imported, second, native]).count == 2)

            try await store.markLegacyFoldersAdopted()

            // Danach nie wieder, auch nicht nach einem Neustart: sonst landet
            // ein bewusst herausgenommenes Meeting wieder im Ordner.
            let again = try await FolderStore.open(layout: library.layout)
                .adoptLegacyFolders(from: [imported, second, native])
            #expect(again.isEmpty)
            #expect(try await store.listFolders().count == 1)
        }
    }

    @Test("the adoption files imported meetings and never runs twice")
    func adoptionFilesMeetingsOnce() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let store = try FolderStore.open(layout: library.layout)
            let imported = try await library.createMeeting(
                title: "Imported",
                status: .ready,
                metadata: MeetingMetadata(legacyFolders: ["Kunden"])
            )
            _ = try await library.createMeeting(title: "Native", status: .ready)

            let filed = try await LegacyFolderAdoption.run(
                library: library,
                folders: store
            )
            #expect(filed == 1)
            let folder = try #require(try await store.listFolders().first)
            #expect(try await library.loadMeeting(imported.id).folderID == folder.id)

            // Der Benutzer nimmt es bewusst heraus.
            _ = try await library.setMeetingFolder(imported.id, folderID: nil)
            #expect(try await LegacyFolderAdoption.run(
                library: library,
                folders: try FolderStore.open(layout: library.layout)
            ) == 0)
            #expect(try await library.loadMeeting(imported.id).folderID == nil)
        }
    }

    @Test("a meeting written before folders still decodes")
    func decodesMeetingWithoutFolderField() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(title: "Old", status: .ready)
            let url = library.layout.meetingMetadata(meeting.id)
            var object = try JSONSerialization.jsonObject(
                with: Data(contentsOf: url)
            ) as! [String: Any]
            object.removeValue(forKey: "folderID")
            try JSONSerialization.data(withJSONObject: object).write(to: url)

            #expect(try await library.loadMeeting(meeting.id).folderID == nil)
        }
    }
}
