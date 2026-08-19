import Foundation
import StenoDomain
import Testing
@testable import StenoLibrary

@Suite("Meeting folder batches")
struct MeetingFolderBatchTests {
    private enum TestError: Error {
        case writeFailed
        case restoreFailed
    }

    @Test("a complete batch writes every meeting in stable id order")
    func writesCompleteBatch() throws {
        let originals = [meeting(3, "C"), meeting(1, "A"), meeting(2, "B")]
        let target = FolderID()
        var written: [Meeting] = []

        let updated = try Library.writeMeetingFolderBatch(
            originals: originals,
            folderID: target,
            write: { written.append($0) },
            restore: { _ in Issue.record("A successful batch must not restore") }
        )

        #expect(written.map(\.id) == originals.map(\.id).sorted())
        #expect(updated.map(\.id) == originals.map(\.id).sorted())
        #expect(updated.allSatisfy { $0.folderID == target })
    }

    @Test("a failed batch restores every already written meeting")
    func rollsBackWrittenMeetings() throws {
        let originals = [meeting(1, "A"), meeting(2, "B"), meeting(3, "C")]
        let expected = Dictionary(uniqueKeysWithValues: originals.map { ($0.id, $0) })
        var stored = expected
        var writes = 0

        #expect(throws: MeetingFolderBatchError.self) {
            try Library.writeMeetingFolderBatch(
                originals: originals,
                folderID: FolderID(),
                write: { meeting in
                    writes += 1
                    if writes == 3 { throw TestError.writeFailed }
                    stored[meeting.id] = meeting
                },
                restore: { stored[$0.id] = $0 }
            )
        }

        #expect(stored == expected)
    }

    @Test("a missing meeting aborts before the first write")
    func validatesEveryMeetingBeforeWriting() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let existing = try await library.createMeeting(
                title: "Vorhanden",
                status: .ready
            )
            let missing = MeetingID()

            await #expect(throws: LibraryError.self) {
                _ = try await library.setMeetingFolders(
                    Set([existing.id, missing]),
                    folderID: FolderID()
                )
            }

            #expect(try await library.loadMeeting(existing.id).folderID == nil)
        }
    }

    @Test("a restoration failure reports the affected meeting id")
    func reportsRestorationFailures() throws {
        let originals = [meeting(1, "A"), meeting(2, "B"), meeting(3, "C")]
        let expected = Dictionary(uniqueKeysWithValues: originals.map { ($0.id, $0) })
        var stored = expected
        var writes = 0

        do {
            _ = try Library.writeMeetingFolderBatch(
                originals: originals,
                folderID: FolderID(),
                write: { meeting in
                    writes += 1
                    if writes == 3 { throw TestError.writeFailed }
                    stored[meeting.id] = meeting
                },
                restore: { meeting in
                    if meeting.id == originals[1].id {
                        throw TestError.restoreFailed
                    }
                    stored[meeting.id] = meeting
                }
            )
            Issue.record("Expected MeetingFolderBatchError")
        } catch let error as MeetingFolderBatchError {
            #expect(error.restorationFailures == [originals[1].id])
            #expect(error.reason.contains("writeFailed"))
        }

        #expect(stored[originals[0].id] == expected[originals[0].id])
        #expect(stored[originals[1].id]?.folderID != nil)
        #expect(stored[originals[2].id] == expected[originals[2].id])
    }

    @Test("renaming a meeting preserves its folder assignment")
    func renamePreservesFolder() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(
                title: "Vorher",
                status: .ready
            )
            let folderID = FolderID()
            _ = try await library.setMeetingFolder(
                meeting.id,
                folderID: folderID
            )

            let renamed = try await library.renameMeeting(
                meeting.id,
                to: "Nachher"
            )

            #expect(renamed.folderID == folderID)
            #expect(try await library.loadMeeting(meeting.id).folderID == folderID)
        }
    }

    private func meeting(_ value: Int, _ title: String) -> Meeting {
        Meeting(
            id: MeetingID(rawValue: UUID(uuidString: String(
                format: "00000000-0000-7000-8000-%012d",
                value
            ))!),
            title: title,
            status: .ready
        )
    }
}
