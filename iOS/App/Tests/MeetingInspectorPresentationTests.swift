import StenoDomain
import StenoLibrary
import Testing
@testable import Steno

@Suite("Meeting inspector presentation")
struct MeetingInspectorPresentationTests {
    @Test("drafts open the inspector while non-drafts do not force it")
    func draftOpensInspectorWhileNonDraftMeetingDoesNotForceIt() {
        #expect(MeetingInspectorPresentation.shouldOpenAutomatically(status: .draft))
        #expect(!MeetingInspectorPresentation.shouldOpenAutomatically(status: .ready))
    }

    @Test("a draft opens the inspector exactly once, not on every reload")
    func draftOpensInspectorOnlyOnce() {
        let meetingID = MeetingID()
        var presentation = MeetingInspectorPresentation()

        let first = presentation.shouldOpen(for: meetingID, status: .draft)
        let second = presentation.shouldOpen(for: meetingID, status: .draft)

        #expect(first)
        #expect(!second)
    }

    @Test("an inspector already open for the user is never forced open again")
    func alreadyPresentedInspectorIsNotReopened() {
        var presentation = MeetingInspectorPresentation()

        let shouldOpen = presentation.shouldOpen(
            for: MeetingID(),
            status: .draft,
            inspectorWasAlreadyPresented: true
        )

        #expect(!shouldOpen)
    }

    @Test("a different draft still opens its own inspector once")
    func eachDraftMeetingIsConsideredIndependently() {
        var presentation = MeetingInspectorPresentation()
        let first = MeetingID()
        let second = MeetingID()

        _ = presentation.shouldOpen(for: first, status: .draft)
        let secondShouldOpen = presentation.shouldOpen(for: second, status: .draft)

        #expect(secondShouldOpen)
    }

    @Test("the notes loader waits for the canonical session's initial load")
    @MainActor
    func notesLoaderWaitsForInitialLoad() async {
        let session = MeetingNotesEditingSession(
            meetingID: MeetingID(),
            store: ImmediateNotesPersistence()
        )
        let load = BlockingSessionLoad(session: session)
        let loader = MeetingNotesSection.SessionLoader {
            await load.load()
        }

        let didReturn = MainActorFlag()
        let result = Task { @MainActor in
            let session = await loader.session()
            didReturn.set()
            return session
        }
        await load.waitUntilEntered()
        #expect(!didReturn.value)

        await load.release()
        let loadedSession = await result.value

        #expect(loadedSession === session)
    }

    @Test("a completed nil notes load becomes unavailable")
    @MainActor
    func completedNilNotesLoadBecomesUnavailable() async {
        let loader = MeetingNotesSection.SessionLoader { nil }

        let state = await loader.state()

        #expect(state.isUnavailable)
        #expect(state.session == nil)
    }

    @Test("unavailable notes can start a distinct retry")
    @MainActor
    func unavailableNotesCanStartDistinctRetry() {
        let meetingID = MeetingID()
        var presentation = MeetingNotesSection.SessionPresentation()
        presentation.present(.unavailable)
        let failedLoadID = presentation.loadID(for: meetingID)

        presentation.retry()

        #expect(presentation.state.isLoading)
        #expect(presentation.loadID(for: meetingID) != failedLoadID)
    }

    @Test("leaving the notes section flushes the canonical session")
    @MainActor
    func notesSectionFlushesCanonicalSessionOnExit() async {
        let persistence = SavingNotesPersistence()
        let session = MeetingNotesEditingSession(
            meetingID: MeetingID(),
            store: persistence,
            autosaveDelay: .seconds(60)
        )
        await session.load()
        session.update("Beschluss festhalten")

        await MeetingNotesSection.flush(session)

        #expect(await persistence.savedNotes() == "Beschluss festhalten")
    }

    @Test("meeting change flushes the old session without delaying the new load")
    @MainActor
    func meetingChangeFlushesOldSessionWithoutBlockingNewLoad() async {
        let oldID = MeetingID()
        let oldPersistence = BlockingWritePersistence()
        let oldSession = MeetingNotesEditingSession(
            meetingID: oldID,
            store: oldPersistence,
            autosaveDelay: .seconds(60)
        )
        await oldSession.load()
        oldSession.update("Noch nicht gespeicherte Notiz")

        let transitions = MeetingNotesSection.SessionTransitionCoordinator()
        transitions.leave(oldSession, for: oldID)
        await oldPersistence.waitUntilWriteStarts()
        #expect(transitions.hasPendingFlush(for: oldID))

        let newSession = MeetingNotesEditingSession(
            meetingID: MeetingID(),
            store: ImmediateNotesPersistence()
        )
        let newLoader = MeetingNotesSection.SessionLoader { newSession }
        let loadedNewSession = await newLoader.session()

        #expect(loadedNewSession === newSession)
        #expect(await oldPersistence.savedNotes() == nil)

        await oldPersistence.releaseWrite()
        await transitions.waitForPendingFlushes()

        #expect(await oldPersistence.savedNotes() == "Noch nicht gespeicherte Notiz")
    }
}

@MainActor
private final class MainActorFlag {
    private(set) var value = false

    func set() {
        value = true
    }
}

private actor ImmediateNotesPersistence: MeetingNotesPersistence {
    func notes(_ meetingID: MeetingID) async throws -> String? { nil }
    func setNotes(_ meetingID: MeetingID, to notes: String?) async throws {}
}

private actor SavingNotesPersistence: MeetingNotesPersistence {
    private var saved: String?

    func notes(_ meetingID: MeetingID) async throws -> String? { saved }

    func setNotes(_ meetingID: MeetingID, to notes: String?) async throws {
        saved = notes
    }

    func savedNotes() -> String? { saved }
}

private actor BlockingWritePersistence: MeetingNotesPersistence {
    private var stored: String?
    private var writeStarted = false
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func notes(_ meetingID: MeetingID) async throws -> String? { stored }

    func setNotes(_ meetingID: MeetingID, to notes: String?) async throws {
        writeStarted = true
        let waiters = writeWaiters
        writeWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { releaseContinuation = $0 }
        stored = notes
    }

    func waitUntilWriteStarts() async {
        guard !writeStarted else { return }
        await withCheckedContinuation { writeWaiters.append($0) }
    }

    func releaseWrite() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func savedNotes() -> String? { stored }
}

private actor BlockingSessionLoad {
    private let storedSession: MeetingNotesEditingSession
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(session: MeetingNotesEditingSession) {
        storedSession = session
    }

    func load() async -> MeetingNotesEditingSession? {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { releaseContinuation = $0 }
        return storedSession
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
