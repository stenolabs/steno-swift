import Foundation
import StenoDomain

/// Keeps one notes editing session per meeting for a whole app process.
///
/// Multiple windows and platform surfaces therefore join the same load and
/// autosave state instead of letting separate editors overwrite one another.
@MainActor
public final class MeetingNotesSessionPool {
    private let store: any MeetingNotesPersistence
    private let autosaveDelay: Duration
    private var sessions: [MeetingID: MeetingNotesEditingSession] = [:]

    public init(
        store: any MeetingNotesPersistence,
        autosaveDelay: Duration = .seconds(1)
    ) {
        self.store = store
        self.autosaveDelay = autosaveDelay
    }

    public func session(for meetingID: MeetingID) async -> MeetingNotesEditingSession {
        if let session = sessions[meetingID] {
            await session.load()
            return session
        }

        let session = MeetingNotesEditingSession(
            meetingID: meetingID,
            store: store,
            autosaveDelay: autosaveDelay
        )
        sessions[meetingID] = session
        await session.load()
        return session
    }
}
