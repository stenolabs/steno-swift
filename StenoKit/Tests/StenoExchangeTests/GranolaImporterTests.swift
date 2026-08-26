import Foundation
import StenoDomain
import StenoLibrary
import Testing
@testable import StenoExchange

/// Fixture for the Granola importer tests.
///
/// The JSON mirrors a Granola "export notes" document: a top-level array of
/// note objects (an object wrapping a `notes`/`meetings`/`documents` array is
/// accepted as well) where every note carries
/// - an `id` (aliases: `noteId`, `note_id`) - the stable identity that the
///   importer turns into the provenance key `granola:<id>`,
/// - `title`, an ISO-8601 or display-formatted date, participant names,
/// - a markdown AI `summary` (becomes the meeting note) and an optional
///   verbatim `transcript`.
///
/// Idempotence contract under test: re-importing the SAME fixture must skip
/// every note whose provenance key already exists in the library, so running
/// it twice leaves the library unchanged apart from nothing at all - no
/// duplicate meetings, no duplicate people, no rewritten notes.
private let granolaExportFixture = """
[
  {
    "id": "note-001",
    "title": "Kickoff mit Ada",
    "created_at": "2026-06-26T14:30:00Z",
    "known_participants": ["Ada Lovelace", {"name": "Grace Hopper"}],
    "summary": "# Kickoff\\n\\n- decided the launch date",
    "transcript": "Me: Hello everyone.\\nThem: Hi, thanks for joining!\\nMe: Let's start."
  },
  {
    "id": "note-002",
    "title": "Ohne Transcript",
    "date_displayed_unused_key": "ignored",
    "participants": [],
    "notes": "Only a summary, no transcript.",
    "transcript": null
  },
  {
    "title": "Keine ID"
  }
]
"""

@Suite("Granola importer")
struct GranolaImporterTests {
    /// 2026-06-26 14:30:00 UTC, built from components so the expectation
    /// never depends on the host timezone.
    private let fixtureDate: Date = {
        var components = DateComponents()
        components.timeZone = TimeZone(identifier: "UTC")
        components.year = 2026
        components.month = 6
        components.day = 26
        components.hour = 14
        components.minute = 30
        return Calendar(identifier: .gregorian).date(from: components)!
    }()

    @Test("parses the export fixture tolerantly")
    func parsesFixture() throws {
        let result = try GranolaDocument.read(Data(granolaExportFixture.utf8))

        // The third entry carries no usable ID and is skipped with a count.
        #expect(result.skippedCount == 1)
        #expect(result.notes.count == 2)

        let first = try #require(result.notes.first { $0.noteID == "note-001" })
        #expect(first.title == "Kickoff mit Ada")
        #expect(first.date == fixtureDate)
        #expect(first.participants == ["Ada Lovelace", "Grace Hopper"])
        #expect(first.summary.contains("decided the launch date"))
        #expect(first.transcript.contains("Hello everyone."))
        let second = try #require(result.notes.first { $0.noteID == "note-002" })
        #expect(second.summary == "Only a summary, no transcript.")
        #expect(second.transcript.isEmpty)
        #expect(second.participants.isEmpty)
    }

    @Test("imports fresh meetings with provenance, notes and participants")
    func importsFreshMeetings() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let exportURL = root.appending(path: "granola.json")
        try Data(granolaExportFixture.utf8).write(to: exportURL)
        let library = try Library.open(at: root.appending(path: "Library"))

        let outcome = try await GranolaImporter(library: library)
            .performImport(from: exportURL)

        guard case .finished(let report) = outcome else {
            Issue.record("Import was cancelled: \(outcome)")
            return
        }
        #expect(report.meetingsCreated == 2)
        #expect(report.notesCreated == 2)
        #expect(report.peopleCreated == 2)
        #expect(report.duplicates.isEmpty)
        // The only expected warning is the deliberate count for the ID-less
        // third fixture entry.
        #expect(report.warnings == [
            "1 export entry/entries without a usable note ID were skipped."
        ])

        let meetings = try await library.listMeetings()
        #expect(meetings.count == 2)

        let kickoff = try #require(meetings.first { $0.title == "Kickoff mit Ada" })
        #expect(kickoff.status == .ready)
        #expect(kickoff.createdAt == fixtureDate)
        // Provenance key convention: granola:<noteId>.
        #expect(
            kickoff.metadata?.legacyProvenanceKey
                == GranolaImporter.provenanceKey(forNoteID: "note-001")
        )
        #expect(kickoff.metadata?.legacyProvenanceKey == "granola:note-001")

        // Participants have no speech evidence, so they land as silent
        // attendees backed by real person records.
        #expect(kickoff.additionalParticipantIDs.count == 2)
        let store = try IdentityStore(layout: library.layout)
        let identitySnapshot = try await store.snapshot()
        let personNames = Set(identitySnapshot.persons.map(\.displayName))
        #expect(personNames == ["Ada Lovelace", "Grace Hopper"])

        #expect(try String(
            contentsOf: library.layout.userNotes(kickoff.id),
            encoding: .utf8
        ).contains("decided the launch date"))

        // Imported transcripts never masquerade as ASR output; the legacy
        // import-origin marker is reused because StenoDomain knows no
        // dedicated Granola origin.
        let revision = try await library.loadCurrentRevision(meetingID: kickoff.id)
        #expect(revision.origin == .legacyImport)
        #expect(revision.turns.count == 3)
        #expect(revision.turns.first?.speaker == .channel("Me"))
        #expect(meetings.allSatisfy { $0.folderID == nil })

        let withoutTranscript = try #require(
            meetings.first { $0.title == "Ohne Transcript" }
        )
        #expect(withoutTranscript.metadata?.legacyProvenanceKey == "granola:note-002")
        let plainRevision = try await library.loadCurrentRevision(
            meetingID: withoutTranscript.id
        )
        #expect(plainRevision.turns.isEmpty)
    }

    @Test("re-importing the same fixture is idempotent")
    func idempotentReimport() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let exportURL = root.appending(path: "granola.json")
        try Data(granolaExportFixture.utf8).write(to: exportURL)
        let library = try Library.open(at: root.appending(path: "Library"))
        let importer = GranolaImporter(library: library)

        _ = try await importer.performImport(from: exportURL)
        let second = try await importer.performImport(from: exportURL)

        guard case .finished(let report) = second else {
            Issue.record("Second import was cancelled: \(second)")
            return
        }
        #expect(report.meetingsCreated == 0)
        #expect(report.notesCreated == 0)
        #expect(report.peopleCreated == 0)
        // Both provenance keys were recognized as duplicates.
        #expect(Set(report.duplicates) == ["Kickoff mit Ada", "Ohne Transcript"])

        let meetings = try await library.listMeetings()
        #expect(meetings.count == 2)
        let kickoff = try #require(meetings.first { $0.title == "Kickoff mit Ada" })
        #expect(try String(
            contentsOf: library.layout.userNotes(kickoff.id),
            encoding: .utf8
        ).contains("decided the launch date"))
        let store = try IdentityStore(layout: library.layout)
        let identitySnapshot = try await store.snapshot()
        #expect(identitySnapshot.persons.count == 2)
    }

    @Test("unparseable dates fall back deterministically with a warning")
    func unparseableDateFallsBack() async throws {
        let json = """
        [
          {
            "id": "note-bad-date",
            "title": "Broken Date",
            "created_at": "not a date at all",
            "summary": "",
            "transcript": ""
          }
        ]
        """
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let exportURL = root.appending(path: "granola.json")
        try Data(json.utf8).write(to: exportURL)
        let library = try Library.open(at: root.appending(path: "Library"))

        let outcome = try await GranolaImporter(library: library)
            .performImport(from: exportURL)

        guard case .finished(let report) = outcome else {
            Issue.record("Import was cancelled: \(outcome)")
            return
        }
        #expect(report.meetingsCreated == 1)
        #expect(report.warnings.contains { $0.contains("unreadable date") })
        let meeting = try #require(try await library.listMeetings().first)
        // Deterministic placeholder, never now(): a rerun stays idempotent.
        #expect(meeting.createdAt == Date(timeIntervalSince1970: 0))
    }

    @Test("malformed exports fail loudly instead of importing nothing")
    func malformedExportThrows() {
        #expect(throws: GranolaExchangeError.self) {
            _ = try GranolaDocument.read(Data("{\"unexpected\": true}".utf8))
        }
    }
}
