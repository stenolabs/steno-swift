import StenoDomain
import Testing
@testable import StenoLibrary

@Suite("Meeting notes session pool")
struct MeetingNotesSessionPoolTests {
    @Test("concurrent access shares one completely loaded session")
    @MainActor
    func concurrentAccessSharesOneLoadedSession() async {
        let meetingID = MeetingID()
        let persistence = BlockingNotesPersistence(notes: "Vorhandene Notiz")
        let pool = MeetingNotesSessionPool(store: persistence)

        let first = Task { @MainActor in
            await pool.session(for: meetingID)
        }
        await persistence.waitUntilReadStarted()
        let second = Task { @MainActor in
            await pool.session(for: meetingID)
        }

        await persistence.releaseRead()
        let firstSession = await first.value
        let secondSession = await second.value

        #expect(firstSession === secondSession)
        #expect(firstSession.text == "Vorhandene Notiz")
        #expect(await persistence.readCount() == 1)
    }
}

private actor BlockingNotesPersistence: MeetingNotesPersistence {
    private let storedNotes: String
    private var reads = 0
    private var readStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var blockedRead: CheckedContinuation<Void, Never>?

    init(notes: String) {
        storedNotes = notes
    }

    func notes(_ meetingID: MeetingID) async throws -> String? {
        reads += 1
        readStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            blockedRead = continuation
        }
        return storedNotes
    }

    func setNotes(_ meetingID: MeetingID, to notes: String?) async throws {}

    func waitUntilReadStarted() async {
        guard !readStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseRead() {
        blockedRead?.resume()
        blockedRead = nil
    }

    func readCount() -> Int {
        reads
    }
}
