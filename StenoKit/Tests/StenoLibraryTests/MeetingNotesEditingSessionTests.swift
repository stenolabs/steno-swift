import Foundation
import StenoDomain
import Testing
@testable import StenoLibrary

@Suite("Meeting notes editing session")
struct MeetingNotesEditingSessionTests {
    @Test("pending text and an immediate marker are saved together")
    @MainActor
    func pendingTextAndImmediateMarkerAreSavedTogether() async throws {
        try await withTemporaryMainActorDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(
                title: "Rat",
                status: .recording
            )
            let store = MeetingNotesStore(layout: library.layout)
            let session = MeetingNotesEditingSession(
                meetingID: meeting.id,
                store: store,
                autosaveDelay: .seconds(60)
            )

            await session.load()
            session.update("Budgetfreigabe")
            await session.appendMarker(elapsed: 65)

            #expect(session.text == "Budgetfreigabe\n[00:01:05] ")
            #expect(try await store.notes(meeting.id) == session.text)
        }
    }

    @Test("a stale autosave cannot overwrite a marker")
    @MainActor
    func staleAutosaveCannotOverwriteMarker() async throws {
        try await withTemporaryMainActorDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(
                title: "Rat",
                status: .recording
            )
            let store = MeetingNotesStore(layout: library.layout)
            let session = MeetingNotesEditingSession(
                meetingID: meeting.id,
                store: store,
                autosaveDelay: .milliseconds(20)
            )

            await session.load()
            session.update("Erster Stand")
            await session.appendMarker(elapsed: 3)
            try await Task.sleep(for: .milliseconds(60))

            #expect(try await store.notes(meeting.id) == "Erster Stand\n[00:00:03] ")
        }
    }

    @Test("a marker starts an empty note")
    @MainActor
    func markerStartsEmptyNote() async throws {
        let store = InMemoryNotesPersistence()
        let session = MeetingNotesEditingSession(
            meetingID: MeetingID(),
            store: store,
            autosaveDelay: .seconds(60)
        )

        await session.load()
        await session.appendMarker(elapsed: 9)

        #expect(session.text == "[00:00:09] ")
        #expect(await store.currentNotes() == "[00:00:09] ")
    }

    @Test("a marker copies imported notes into the editable note")
    @MainActor
    func markerCopiesLegacyTextIntoOwnNote() async throws {
        try await withTemporaryMainActorDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(
                title: "Altbestand",
                status: .ready
            )
            let legacy = library.layout.legacyUserNotes(meeting.id)
            try Data("Importierte Notiz".utf8).write(to: legacy)
            let store = MeetingNotesStore(layout: library.layout)
            let session = MeetingNotesEditingSession(
                meetingID: meeting.id,
                store: store,
                autosaveDelay: .seconds(60)
            )

            await session.load()
            await session.appendMarker(elapsed: 10)

            #expect(try await store.notes(meeting.id) == "Importierte Notiz\n[00:00:10] ")
            #expect(try String(contentsOf: legacy, encoding: .utf8) == "Importierte Notiz")
        }
    }

    @Test("a marker formats elapsed times beyond one hour")
    @MainActor
    func markerFormatsMoreThanOneHour() async {
        let store = InMemoryNotesPersistence()
        let session = MeetingNotesEditingSession(
            meetingID: MeetingID(),
            store: store,
            autosaveDelay: .seconds(60)
        )

        await session.load()
        await session.appendMarker(elapsed: 3_725)

        #expect(session.text == "[01:02:05] ")
    }

    @Test("a write failure keeps the text visible and retryable")
    @MainActor
    func writeFailureLeavesTextVisibleForRetry() async {
        let store = InMemoryNotesPersistence(failsWrites: true)
        let session = MeetingNotesEditingSession(
            meetingID: MeetingID(),
            store: store,
            autosaveDelay: .seconds(60)
        )

        await session.load()
        session.update("Nicht verlieren")
        await session.appendMarker(elapsed: 12)

        #expect(session.text == "Nicht verlieren\n[00:00:12] ")
        #expect(session.errorMessage != nil)
        #expect(await store.currentNotes() == nil)

        await store.allowWrites()
        await session.flush()

        #expect(session.errorMessage == nil)
        #expect(await store.currentNotes() == "Nicht verlieren\n[00:00:12] ")
    }

    @Test("concurrent callers share one complete load")
    @MainActor
    func concurrentLoadCallersWaitForTheSameResult() async {
        let store = SuspendedReadNotesPersistence(notes: "Vorhandene Notiz")
        let session = MeetingNotesEditingSession(
            meetingID: MeetingID(),
            store: store,
            autosaveDelay: .seconds(60)
        )

        let first = Task {
            await session.load()
            return session.text
        }
        await store.waitUntilReadStarted()
        let second = Task {
            await session.load()
            return session.text
        }
        await Task.yield()
        await store.releaseReads()

        #expect(await first.value == "Vorhandene Notiz")
        #expect(await second.value == "Vorhandene Notiz")
        #expect(await store.numberOfReads() == 1)
    }

    @Test("a failed load disables editing and never overwrites existing notes")
    @MainActor
    func failedLoadPreventsEveryWrite() async {
        let store = FailedReadNotesPersistence(notes: "Vorhandene Notiz")
        let session = MeetingNotesEditingSession(
            meetingID: MeetingID(),
            store: store,
            autosaveDelay: .milliseconds(1)
        )

        await session.load()
        session.update("Ersatz")
        await session.appendMarker(elapsed: 7)
        await session.flush()
        try? await Task.sleep(for: .milliseconds(10))

        #expect(session.loadFailed)
        #expect(!session.canEdit)
        #expect(session.text.isEmpty)
        #expect(await store.currentNotes() == "Vorhandene Notiz")
        #expect(await store.numberOfWrites() == 0)
    }

    @Test("preparing for removal saves pending text and rejects later edits")
    @MainActor
    func preparationSavesPendingTextAndRejectsLaterEdits() async throws {
        let store = InMemoryNotesPersistence()
        let session = MeetingNotesEditingSession(
            meetingID: MeetingID(),
            store: store,
            autosaveDelay: .seconds(60)
        )

        await session.load()
        session.update("Noch nicht gespeichert")
        try await session.prepareForMeetingRemoval()

        #expect(await store.currentNotes() == "Noch nicht gespeichert")
        #expect(!session.canEdit)

        session.update("Darf nicht gespeichert werden")
        await session.flush()
        session.completeMeetingRemoval()
        session.cancelMeetingRemoval()
        session.update("Auch nach Abschluss gesperrt")
        await session.flush()

        #expect(session.text == "Noch nicht gespeichert")
        #expect(!session.canEdit)
        #expect(await store.currentNotes() == "Noch nicht gespeichert")
    }

    @Test("a failed removal preparation restores editing and can be retried")
    @MainActor
    func failedPreparationRestoresEditingAndCanBeRetried() async throws {
        let store = InMemoryNotesPersistence(failsWrites: true)
        let session = MeetingNotesEditingSession(
            meetingID: MeetingID(),
            store: store,
            autosaveDelay: .seconds(60)
        )

        await session.load()
        session.update("Erster Entwurf")

        await #expect(throws: (any Error).self) {
            try await session.prepareForMeetingRemoval()
        }
        #expect(session.canEdit)

        session.update("Geretteter Entwurf")
        await store.allowWrites()
        try await session.prepareForMeetingRemoval()

        #expect(await store.currentNotes() == "Geretteter Entwurf")
        #expect(!session.canEdit)
    }
}

private enum NotesPersistenceFailure: Error {
    case refused
}

private actor InMemoryNotesPersistence: MeetingNotesPersistence {
    private var storedNotes: String?
    private var failsWrites: Bool

    init(notes: String? = nil, failsWrites: Bool = false) {
        storedNotes = notes
        self.failsWrites = failsWrites
    }

    func notes(_ meetingID: MeetingID) async throws -> String? {
        storedNotes
    }

    func setNotes(_ meetingID: MeetingID, to notes: String?) async throws {
        guard !failsWrites else { throw NotesPersistenceFailure.refused }
        storedNotes = notes
    }

    func currentNotes() -> String? {
        storedNotes
    }

    func allowWrites() {
        failsWrites = false
    }
}

private actor FailedReadNotesPersistence: MeetingNotesPersistence {
    private let storedNotes: String
    private var writeCount = 0

    init(notes: String) {
        storedNotes = notes
    }

    func notes(_ meetingID: MeetingID) async throws -> String? {
        throw NotesPersistenceFailure.refused
    }

    func setNotes(_ meetingID: MeetingID, to notes: String?) async throws {
        writeCount += 1
    }

    func currentNotes() -> String {
        storedNotes
    }

    func numberOfWrites() -> Int {
        writeCount
    }
}

private actor SuspendedReadNotesPersistence: MeetingNotesPersistence {
    private let storedNotes: String
    private var readCount = 0
    private var hasStarted = false
    private var readsReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var readWaiters: [CheckedContinuation<Void, Never>] = []

    init(notes: String) {
        storedNotes = notes
    }

    func notes(_ meetingID: MeetingID) async throws -> String? {
        readCount += 1
        hasStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if !readsReleased {
            await withCheckedContinuation { continuation in
                readWaiters.append(continuation)
            }
        }
        return storedNotes
    }

    func setNotes(_ meetingID: MeetingID, to notes: String?) async throws {}

    func waitUntilReadStarted() async {
        if hasStarted { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseReads() {
        readsReleased = true
        let waiters = readWaiters
        readWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func numberOfReads() -> Int {
        readCount
    }
}

@MainActor
private func withTemporaryMainActorDirectory<Result>(
    _ body: (URL) async throws -> Result
) async throws -> Result {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StenoNotesSessionTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await body(directory)
}
