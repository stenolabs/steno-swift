import Foundation
import StenoDomain
import StenoLibrary
import SwiftUI
import Testing
@testable import steno_macos

@Suite("Notes section presentation")
struct NotesSectionPresentationTests {
    @Test("notes stay loading until the canonical session resolves")
    @MainActor
    func loadingWaitsForCanonicalSession() async {
        let session = MeetingNotesEditingSession(
            meetingID: MeetingID(),
            store: ImmediateMacNotesPersistence()
        )
        let load = BlockingMacNotesSessionLoad(session: session)
        let loader = MacNotesSessionLoader { await load.load() }
        var presentation = MacNotesSessionPresentation()

        let result = Task { @MainActor in await loader.state() }
        await load.waitUntilEntered()

        #expect(presentation.state.isLoading)
        #expect(presentation.state.session == nil)

        await load.release()
        presentation.present(await result.value)

        #expect(presentation.state.session === session)
        #expect(!presentation.state.isLoading)
    }

    @Test("a completed nil load is unavailable")
    @MainActor
    func nilLoadIsUnavailable() async {
        let state = await MacNotesSessionLoader { nil }.state()

        #expect(state.isUnavailable)
        #expect(state.session == nil)
    }

    @Test("retry returns to loading with a distinct task identity")
    @MainActor
    func retryStartsDistinctLoad() {
        let meetingID = MeetingID()
        var presentation = MacNotesSessionPresentation()
        presentation.present(.unavailable)
        let failedID = presentation.loadID(for: meetingID)

        presentation.retry()

        #expect(presentation.state.isLoading)
        #expect(presentation.loadID(for: meetingID) != failedID)
    }

    @Test("loader returns the supplied canonical session")
    @MainActor
    func loaderPreservesCanonicalSessionIdentity() async {
        let canonical = MeetingNotesEditingSession(
            meetingID: MeetingID(),
            store: ImmediateMacNotesPersistence()
        )

        let loaded = await MacNotesSessionLoader { canonical }.session()

        #expect(loaded === canonical)
    }

    @Test("disappearing flushes the canonical session")
    @MainActor
    func disappearFlushesCanonicalSession() async {
        let persistence = SavingMacNotesPersistence()
        let session = MeetingNotesEditingSession(
            meetingID: MeetingID(),
            store: persistence,
            autosaveDelay: .seconds(60)
        )
        await session.load()
        session.update("Beschluss festhalten")

        await NotesSection.flush(session)

        #expect(await persistence.savedNotes() == "Beschluss festhalten")
    }

    @Test("meeting transition flushes the old session without delaying the new load")
    @MainActor
    func meetingTransitionFlushesOldSession() async {
        let oldID = MeetingID()
        let persistence = BlockingMacNotesWritePersistence()
        let oldSession = MeetingNotesEditingSession(
            meetingID: oldID,
            store: persistence,
            autosaveDelay: .seconds(60)
        )
        await oldSession.load()
        oldSession.update("Noch nicht gespeicherte Notiz")

        let transitions = MacNotesSessionTransitionCoordinator()
        transitions.leave(oldSession, for: oldID)
        await persistence.waitUntilWriteStarts()
        #expect(transitions.hasPendingFlush(for: oldID))

        let canonicalNewSession = MeetingNotesEditingSession(
            meetingID: MeetingID(),
            store: ImmediateMacNotesPersistence()
        )
        let loadedNewSession = await MacNotesSessionLoader { canonicalNewSession }.session()

        #expect(loadedNewSession === canonicalNewSession)
        #expect(await persistence.savedNotes() == nil)

        await persistence.releaseWrite()
        await transitions.waitForPendingFlushes()

        #expect(await persistence.savedNotes() == "Noch nicht gespeicherte Notiz")
    }

    @Test("opening and saving failures use separate localized copy")
    @MainActor
    func distinctLocalizedFailureMessages() async throws {
        let openingSession = MeetingNotesEditingSession(
            meetingID: MeetingID(),
            store: FailingMacNotesPersistence(failsWhileReading: true)
        )
        await openingSession.load()

        let savingSession = MeetingNotesEditingSession(
            meetingID: MeetingID(),
            store: FailingMacNotesPersistence(failsWhileReading: false)
        )
        await savingSession.load()
        savingSession.update("Nicht gespeichert")
        await savingSession.flush()

        let openingResource = try #require(
            MacNotesSessionPresentation.errorMessage(for: openingSession)
        )
        let savingResource = try #require(
            MacNotesSessionPresentation.errorMessage(for: savingSession)
        )

        var englishOpening = openingResource
        englishOpening.locale = Locale(identifier: "en")
        var englishSaving = savingResource
        englishSaving.locale = Locale(identifier: "en")
        #expect(String(localized: englishOpening) == "Notes could not be opened: Disk full")
        #expect(String(localized: englishSaving) == "Notes could not be saved: Disk full")
    }

    @Test("all new static notes copy is localizable")
    @MainActor
    func visibleCopyUsesLocalizedResources() {
        let resources: [LocalizedStringResource] = [
            MacNotesSessionPresentation.title,
            MacNotesSessionPresentation.loadingLabel,
            MacNotesSessionPresentation.unavailableTitle,
            MacNotesSessionPresentation.unavailableDescription,
            MacNotesSessionPresentation.retryLabel,
            MacNotesSessionPresentation.savingLabel,
            MacNotesSessionPresentation.editorLabel,
            MacNotesSessionPresentation.placeholder,
        ]

        #expect(resources.count == 8)
    }
}

private actor ImmediateMacNotesPersistence: MeetingNotesPersistence {
    func notes(_ meetingID: MeetingID) async throws -> String? { nil }
    func setNotes(_ meetingID: MeetingID, to notes: String?) async throws {}
}

private actor SavingMacNotesPersistence: MeetingNotesPersistence {
    private var saved: String?

    func notes(_ meetingID: MeetingID) async throws -> String? { saved }
    func setNotes(_ meetingID: MeetingID, to notes: String?) async throws { saved = notes }
    func savedNotes() -> String? { saved }
}

private actor BlockingMacNotesWritePersistence: MeetingNotesPersistence {
    private var stored: String?
    private var writeStarted = false
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func notes(_ meetingID: MeetingID) async throws -> String? { stored }

    func setNotes(_ meetingID: MeetingID, to notes: String?) async throws {
        writeStarted = true
        let waiters = writeWaiters
        writeWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
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

private actor BlockingMacNotesSessionLoad {
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
        for waiter in waiters { waiter.resume() }
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

private actor FailingMacNotesPersistence: MeetingNotesPersistence {
    let failsWhileReading: Bool

    init(failsWhileReading: Bool) {
        self.failsWhileReading = failsWhileReading
    }

    func notes(_ meetingID: MeetingID) async throws -> String? {
        if failsWhileReading { throw MacNotesTestError.diskFull }
        return nil
    }

    func setNotes(_ meetingID: MeetingID, to notes: String?) async throws {
        throw MacNotesTestError.diskFull
    }
}

private enum MacNotesTestError: LocalizedError {
    case diskFull

    var errorDescription: String? { "Disk full" }
}
