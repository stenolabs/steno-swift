import Foundation
import StenoDomain
import Testing
@testable import StenoLibrary

@Suite("MeetingNotesStore")
struct MeetingNotesStoreTests {
    @Test("notes survive reopening and are written atomically")
    func notesRoundTrip() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(title: "Kreistag", status: .draft)
            let store = MeetingNotesStore(layout: library.layout)

            #expect(try await store.notes(meeting.id) == nil)

            try await store.setNotes(meeting.id, to: "Thema: Haushalt 2027\nFrau Lovelace kommt später.")

            let reopened = MeetingNotesStore(layout: library.layout)
            #expect(
                try await reopened.notes(meeting.id)
                    == "Thema: Haushalt 2027\nFrau Lovelace kommt später."
            )
            // Kein Temp-Rest neben der Datei.
            let files = try FileManager.default.contentsOfDirectory(
                atPath: library.layout.notesDirectory(meeting.id).path
            )
            #expect(files == ["user-notes.md"])
        }
    }

    @Test("a blank note removes the file so that no note stays a real state")
    func blankNoteRemovesTheFile() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(title: "Kreistag", status: .draft)
            let store = MeetingNotesStore(layout: library.layout)
            try await store.setNotes(meeting.id, to: "Erst etwas")

            try await store.setNotes(meeting.id, to: "   \n  ")

            #expect(try await store.notes(meeting.id) == nil)
            #expect(
                !FileManager.default.fileExists(
                    atPath: library.layout.userNotes(meeting.id).path
                )
            )
            // Zweimal löschen darf nicht werfen.
            try await store.setNotes(meeting.id, to: nil)
        }
    }

    @Test("imported legacy notes stay readable and are never overwritten")
    func legacyNotesAreReadOnlySource() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(title: "Altes Meeting", status: .ready)
            let legacy = library.layout.legacyUserNotes(meeting.id)
            try Data("Notiz aus der alten App".utf8).write(to: legacy)
            let store = MeetingNotesStore(layout: library.layout)

            #expect(try await store.notes(meeting.id) == "Notiz aus der alten App")

            try await store.setNotes(meeting.id, to: "Eigene Fassung")

            #expect(try await store.notes(meeting.id) == "Eigene Fassung")
            #expect(
                try String(contentsOf: legacy, encoding: .utf8)
                    == "Notiz aus der alten App"
            )
        }
    }

    @Test("an unreadable current note aborts instead of falling back to legacy notes")
    func unreadableCurrentNoteDoesNotFallBackToLegacy() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(title: "Kreistag", status: .draft)
            let current = library.layout.userNotes(meeting.id)
            try FileManager.default.createDirectory(
                at: current,
                withIntermediateDirectories: true
            )
            try Data("Legacy darf nicht sichtbar werden".utf8).write(
                to: library.layout.legacyUserNotes(meeting.id)
            )

            await #expect(throws: Error.self) {
                _ = try await MeetingNotesStore(layout: library.layout).notes(meeting.id)
            }
        }
    }
}
