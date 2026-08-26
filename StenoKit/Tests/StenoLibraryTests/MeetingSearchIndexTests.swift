import Foundation
import StenoDomain
import Testing
@testable import StenoLibrary

@Suite("MeetingSearchIndex")
struct MeetingSearchIndexTests {
    /// Builds a library with one meeting containing transcript, note, and
    /// report content.
    private static func makeSeededLibrary(
        in root: URL
    ) async throws -> (Library, Meeting) {
        let library = try Library.open(at: root)
        let meeting = try await library.createMeeting(title: "Quarterly Review", status: .ready)
        let revision = TranscriptRevision(
            meetingID: meeting.id,
            origin: .legacyImport,
            turns: [
                TranscriptTurn(
                    speaker: nil,
                    start: 0,
                    end: 10,
                    segments: [
                        TranscriptSegment(
                            text: "Müller presented the roadmap for Q3",
                            start: 0,
                            end: 5,
                            words: []
                        ),
                        TranscriptSegment(
                            text: "Budget review follows next week",
                            start: 5,
                            end: 10,
                            words: []
                        ),
                    ]
                )
            ]
        )
        _ = try await library.appendRevision(revision)

        let notes = MeetingNotesStore(layout: library.layout)
        try await notes.setNotes(meeting.id, to: "Follow up with Mueller about pricing")

        let report = TemplateResult(
            markdown: "# Minutes\n\nThe roadmap was approved.",
            template: Template.minutesFixture,
            engine: EngineDescriptor(name: "test-engine", version: "1"),
            revisionID: revision.id
        )
        let reportsDirectory = library.layout.reportsDirectory(meeting.id)
        try FileManager.default.createDirectory(
            at: reportsDirectory,
            withIntermediateDirectories: true
        )
        // Encode exactly like TemplateResultStore.persist: default JSONEncoder
        // settings, including the default date strategy. The index reads
        // reports with the same decoder as the store, so a fixture written
        // with a different date strategy would not be indexable - which is
        // not what this suite documents.
        let data = try JSONEncoder().encode(report)
        try data.write(to: reportsDirectory.appendingPathComponent("\(RunID()).json"))
        return (library, meeting)
    }

    @Test("round trip: indexed content is findable after close and reopen")
    func roundTripPersistsAcrossReopen() async throws {
        try await withTemporaryDirectory { root in
            let (library, meeting) = try await Self.makeSeededLibrary(in: root)
            let index = try MeetingSearchIndex(layout: library.layout)
            try await index.update(meetingID: meeting.id, library: library)

            var results = try await index.search("roadmap")
            #expect(results.map(\.meetingID) == [meeting.id])
            #expect(results.first?.hits.first?.source == .transcript)

            // Reopen from disk: persisted rows survive.
            let reopened = try MeetingSearchIndex(layout: library.layout)
            results = try await reopened.search("pricing")
            #expect(results.map(\.meetingID) == [meeting.id])
            #expect(results.first?.hits.contains { $0.source == .note } == true)

            results = try await reopened.search("approved")
            #expect(results.first?.hits.contains { $0.source == .report } == true)
        }
    }

    @Test("diacritic folding matches the shared normalization")
    func diacriticInsensitiveLikeTitleFilter() async throws {
        try await withTemporaryDirectory { root in
            let (library, meeting) = try await Self.makeSeededLibrary(in: root)
            // "muller" (no umlaut, lowercase) must find the transcript
            // segment that says "Müller" - same folding as the title filter,
            // which finds the title via its normalized form. The second
            // query is "Quarterly" spelled with pure accent variants; the
            // shared fold maps it back onto the title exactly like the
            // filter does.
            let index = try MeetingSearchIndex(layout: library.layout)
            try await index.rebuild(library: library)

            let fromIndex = try await index.search("muller")
            #expect(fromIndex.map(\.meetingID) == [meeting.id])

            let meetings = try await library.listMeetings()
            #expect(MeetingSearch.matching(meetings, query: "QUARTERLY").count == 1)
            #expect(MeetingSearch.matching(meetings, query: "quartèrlý").count == 1)
        }
    }

    @Test("incremental update is idempotent for unchanged meetings")
    func incrementalUpdateSkipsUnchangedMeetings() async throws {
        try await withTemporaryDirectory { root in
            let (library, meeting) = try await Self.makeSeededLibrary(in: root)
            let index = try MeetingSearchIndex(layout: library.layout)
            try await index.update(meetingID: meeting.id, library: library)
            try await index.update(meetingID: meeting.id, library: library)

            let results = try await index.search("approved")
            #expect(results.count == 1)
            #expect(results.first?.hits.filter { $0.source == .report }.count == 1)
        }
    }

    @Test("update replaces stale rows when sources change")
    func updateReplacesStaleContent() async throws {
        try await withTemporaryDirectory { root in
            let (library, meeting) = try await Self.makeSeededLibrary(in: root)
            let notes = MeetingNotesStore(layout: library.layout)
            let index = try MeetingSearchIndex(layout: library.layout)
            try await index.update(meetingID: meeting.id, library: library)
            #expect(try await index.search("pricing").isEmpty == false)

            // Changing the note invalidates the fingerprint and reindexes.
            try await notes.setNotes(meeting.id, to: "Now about invoices instead")
            try await index.update(meetingID: meeting.id, library: library)
            #expect(try await index.search("pricing").isEmpty)
            #expect(try await index.search("invoices").isEmpty == false)
        }
    }

    @Test("search ordering is stable across repeated runs")
    func orderingIsDeterministic() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let index = try MeetingSearchIndex(layout: library.layout)
            var ids: [MeetingID] = []
            // Small corpus; enough to pin tie-break determinism without
            // slowing the suite. Benchmark target: query < 50 ms at 100
            // meetings - this test asserts the ordering-stability property.
            for number in 0..<30 {
                let meeting = try await library.createMeeting(title: "Standup \(number)", status: .ready)
                ids.append(meeting.id)
                let revision = TranscriptRevision(
                    meetingID: meeting.id,
                    origin: .legacyImport,
                    turns: [
                        TranscriptTurn(
                            speaker: nil,
                            start: 0,
                            end: 1,
                            segments: [
                                TranscriptSegment(
                                    text: "shared keyword payload number \(number)",
                                    start: 0,
                                    end: 1,
                                    words: []
                                )
                            ]
                        )
                    ]
                )
                _ = try await library.appendRevision(revision)
                try await index.update(meetingID: meeting.id, library: library)
            }

            let first = try await index.search("keyword")
            let second = try await index.search("KEYWORD")
            #expect(first.map(\.meetingID) == second.map(\.meetingID))
            #expect(Set(first.map(\.meetingID)) == Set(ids))
        }
    }

    @Test("query syntax characters never break matching")
    func userQueryIsSyntaxSafe() async throws {
        #expect(MeetingSearchIndex.matchExpression(for: "NEAR(a b)") == "\"near(a b)\"")
        #expect(MeetingSearchIndex.matchExpression(for: "  ") == "")
        #expect(
            MeetingSearchIndex.matchExpression(for: "say \"hello\"")
                == "\"say\" \"\"\"hello\"\"\""
        )
    }

    @Test("fingerprint reflects only existing sources")
    func fingerprintTracksExistingSources() async throws {
        try await withTemporaryDirectory { root in
            let (library, meeting) = try await Self.makeSeededLibrary(in: root)
            let notes = MeetingNotesStore(layout: library.layout)

            let document = try await MeetingSearchIndex.indexDocument(
                meetingID: meeting.id,
                library: library
            )
            #expect(document.entries.map(\.source.rawValue).sorted() == ["note", "report", "transcript"])

            // Removing the note drops exactly that entry on reindex.
            try await notes.setNotes(meeting.id, to: nil)
            let updated = try await MeetingSearchIndex.indexDocument(
                meetingID: meeting.id,
                library: library
            )
            #expect(updated.entries.map(\.source.rawValue).sorted() == ["report", "transcript"])
            #expect(updated.fingerprint != document.fingerprint)
        }
    }
}

private extension Template {
    /// Minimal valid fixture template for report encoding tests.
    static let minutesFixture = Template(
        id: "meeting-minutes",
        name: "Meeting Minutes",
        description: "",
        sections: [],
        prompts: TemplatePromptComponents(
            role: "",
            mapInstructions: "",
            reduceInstructions: ""
        )
    )
}
