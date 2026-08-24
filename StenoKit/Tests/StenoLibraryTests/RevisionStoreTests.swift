import Foundation
import Testing
import StenoDomain
@testable import StenoLibrary

@Suite("Transcript revisions")
struct RevisionStoreTests {
    @Test("appends revisions and advances current over non-user revisions")
    func advancesCurrentRevision() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(title: "Meeting", status: .processing)
            let live = makeRevision(meetingID: meeting.id, origin: .liveProvisional)
            let final = makeRevision(meetingID: meeting.id, origin: .finalRun(RunID()))

            let livePointer = try await library.appendRevision(live)
            let finalPointer = try await library.appendRevision(final)

            #expect(livePointer.currentRevisionID == live.id)
            #expect(finalPointer.currentRevisionID == final.id)
            #expect(finalPointer.pendingCandidate == nil)
            #expect(try await library.loadRevision(final.id, meetingID: meeting.id) == final)
        }
    }

    @Test("a final run over a user edit becomes a pending candidate")
    func preservesUserEdit() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(title: "Meeting", status: .processing)
            let base = makeRevision(meetingID: meeting.id, origin: .finalRun(RunID()))
            let userEdit = makeRevision(meetingID: meeting.id, origin: .userEdit(base.id))
            let newFinal = makeRevision(meetingID: meeting.id, origin: .finalRun(RunID()))
            _ = try await library.appendRevision(base)
            _ = try await library.appendRevision(userEdit)

            let pointer = try await library.appendRevision(newFinal)

            #expect(pointer.currentRevisionID == userEdit.id)
            #expect(pointer.pendingCandidate == newFinal.id)
            #expect(try await library.loadCurrentRevision(meetingID: meeting.id) == userEdit)
            #expect(try await library.loadRevision(newFinal.id, meetingID: meeting.id) == newFinal)
        }
    }

    @Test("append-only storage refuses to overwrite an existing revision")
    func refusesOverwrite() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(title: "Meeting", status: .ready)
            let revision = makeRevision(meetingID: meeting.id, origin: .liveProvisional)
            _ = try await library.appendRevision(revision)

            do {
                _ = try await library.appendRevision(revision)
                Issue.record("Expected documentAlreadyExists")
            } catch let error as LibraryError {
                guard case .documentAlreadyExists(let url) = error else {
                    Issue.record("Unexpected error: \(error)")
                    return
                }
                #expect(url.lastPathComponent == "\(revision.id).json")
            }
        }
    }

    @Test("opening the library completes an append interrupted after the revision write")
    func recoversInterruptedUserEditAppend() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(title: "Meeting", status: .ready)
            let base = makeRevision(meetingID: meeting.id, origin: .finalRun(RunID()))
            let userEdit = makeRevision(meetingID: meeting.id, origin: .userEdit(base.id))
            _ = try await library.appendRevision(base)

            await #expect(throws: RevisionAppendInterruption.self) {
                _ = try await library.appendRevision(
                    userEdit,
                    interruptAfterRevisionWrite: true
                )
            }
            #expect(try await library.loadCurrentRevision(meetingID: meeting.id) == base)

            let reopened = try Library.open(at: root)

            #expect(try await reopened.loadCurrentRevision(meetingID: meeting.id) == userEdit)
            #expect(
                !FileManager.default.fileExists(
                    atPath: reopened.layout.revisionAppendIntent(meeting.id).path
                )
            )
        }
    }

    @Test("rejects an unsupported revision schema before writing")
    func rejectsUnsupportedRevisionSchema() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(title: "Meeting", status: .ready)
            let revision = TranscriptRevision(
                schemaVersion: 99,
                meetingID: meeting.id,
                origin: .liveProvisional,
                turns: []
            )

            await #expect(throws: LibraryError.self) {
                _ = try await library.appendRevision(revision)
            }
            #expect(
                !FileManager.default.fileExists(
                    atPath: library.layout.revision(meeting.id, revisionID: revision.id).path
                )
            )
        }
    }

    @Test("retrying an interrupted append returns its committed pointer")
    func retriesInterruptedAppendIdempotently() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(title: "Meeting", status: .ready)
            let revision = makeRevision(meetingID: meeting.id, origin: .liveProvisional)
            await #expect(throws: RevisionAppendInterruption.self) {
                _ = try await library.appendRevision(
                    revision,
                    interruptAfterRevisionWrite: true
                )
            }

            let pointer = try await library.appendRevision(revision)

            #expect(pointer.currentRevisionID == revision.id)
            #expect(try await library.loadCurrentRevision(meetingID: meeting.id) == revision)
        }
    }

    @Test("recovery discards a stale intent instead of replacing a newer pointer")
    func staleIntentDoesNotReplaceNewerPointer() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(title: "Meeting", status: .ready)
            let base = makeRevision(meetingID: meeting.id, origin: .finalRun(RunID()))
            let edit = makeRevision(meetingID: meeting.id, origin: .userEdit(base.id))
            let adopted = makeRevision(meetingID: meeting.id, origin: .finalRun(RunID()))
            let interrupted = makeRevision(
                meetingID: meeting.id,
                origin: .finalRun(RunID())
            )
            _ = try await library.appendRevision(base)
            _ = try await library.appendRevision(edit)
            _ = try await library.appendRevision(adopted)
            await #expect(throws: RevisionAppendInterruption.self) {
                _ = try await library.appendRevision(
                    interrupted,
                    interruptAfterRevisionWrite: true
                )
            }

            let newerPointer = CurrentRevisionPointer(
                currentRevisionID: adopted.id
            )
            try JSONDocumentStore.write(
                newerPointer,
                to: library.layout.currentRevision(meeting.id)
            )

            #expect(try RevisionAppendRecovery.recover(
                layout: library.layout,
                meetingID: meeting.id
            ) == nil)
            #expect(
                try await library.loadCurrentRevisionPointer(meetingID: meeting.id)
                    == newerPointer
            )
            #expect(!FileManager.default.fileExists(
                atPath: library.layout.revisionAppendIntent(meeting.id).path
            ))
            #expect(
                try await library.loadRevision(interrupted.id, meetingID: meeting.id)
                    == interrupted
            )
        }
    }

    @Test("adopting first recovers an interrupted append before comparing candidates")
    func adoptionRecoversBeforeComparingCandidate() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(title: "Meeting", status: .ready)
            let base = makeRevision(meetingID: meeting.id, origin: .finalRun(RunID()))
            let edit = makeRevision(meetingID: meeting.id, origin: .userEdit(base.id))
            let inspectedCandidate = makeRevision(
                meetingID: meeting.id,
                origin: .finalRun(RunID())
            )
            let interruptedCandidate = makeRevision(
                meetingID: meeting.id,
                origin: .finalRun(RunID())
            )
            _ = try await library.appendRevision(base)
            _ = try await library.appendRevision(edit)
            _ = try await library.appendRevision(inspectedCandidate)
            await #expect(throws: RevisionAppendInterruption.self) {
                _ = try await library.appendRevision(
                    interruptedCandidate,
                    interruptAfterRevisionWrite: true
                )
            }

            let adopted = try await library.adoptPendingRevision(
                meetingID: meeting.id,
                expectedCandidateID: inspectedCandidate.id
            )
            let pointer = try await library.loadCurrentRevisionPointer(
                meetingID: meeting.id
            )

            #expect(adopted == nil)
            #expect(pointer.currentRevisionID == edit.id)
            #expect(pointer.pendingCandidate == interruptedCandidate.id)
            #expect(!FileManager.default.fileExists(
                atPath: library.layout.revisionAppendIntent(meeting.id).path
            ))
        }
    }

    @Test("a user edit must descend from the current revision")
    func validatesUserEditParent() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(title: "Meeting", status: .ready)
            let base = makeRevision(meetingID: meeting.id, origin: .finalRun(RunID()))
            let current = makeRevision(meetingID: meeting.id, origin: .finalRun(RunID()))
            let staleEdit = makeRevision(meetingID: meeting.id, origin: .userEdit(base.id))
            _ = try await library.appendRevision(base)
            _ = try await library.appendRevision(current)

            await #expect(throws: LibraryError.self) {
                _ = try await library.appendRevision(staleEdit)
            }
            #expect(try await library.loadCurrentRevision(meetingID: meeting.id) == current)
        }
    }

    private func makeRevision(
        meetingID: MeetingID,
        origin: TranscriptOrigin
    ) -> TranscriptRevision {
        TranscriptRevision(
            meetingID: meetingID,
            origin: origin,
            turns: []
        )
    }
}
