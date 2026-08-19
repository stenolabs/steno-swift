import Foundation
import StenoDomain
import StenoIdentity
import Testing
@testable import StenoPipeline

@Suite("Meeting markdown")
struct MeetingMarkdownTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    private var createdAt: Date {
        calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 6, hour: 14, minute: 30
        ))!
    }

    private func meeting(title: String = "Board review") -> Meeting {
        Meeting(title: title, createdAt: createdAt, status: .ready)
    }

    private func turn(
        _ speaker: SpeakerReference?,
        _ text: String,
        at start: TimeInterval
    ) -> TranscriptTurn {
        TranscriptTurn(
            speaker: speaker,
            start: start,
            end: start + 5,
            segments: [TranscriptSegment(
                text: text,
                start: start,
                end: start + 5,
                words: []
            )]
        )
    }

    private func revision(_ turns: [TranscriptTurn]) -> TranscriptRevision {
        TranscriptRevision(
            meetingID: MeetingID(),
            origin: .finalRun(RunID()),
            turns: turns
        )
    }

    @Test("renders title, date, participants and a timecoded transcript")
    func rendersCompleteDocument() {
        let ada = PersonID()
        let markdown = MeetingMarkdown.render(
            MeetingMarkdown.Input(
                meeting: meeting(),
                revision: revision([
                    turn(.person(ada), "Let us start.", at: 5),
                    turn(.channel("Other"), "Agreed.", at: 3_671),
                ]),
                speakerNames: [.person(ada): "Ada Lovelace"],
                participants: ["Ada Lovelace", "Grace Hopper"],
                notes: "  Bring the budget.  ",
                reports: []
            ),
            calendar: calendar
        )

        #expect(markdown.contains("# Board review"))
        #expect(markdown.contains("*2026-08-06 14:30*"))
        #expect(markdown.contains("**Participants:** Ada Lovelace, Grace Hopper"))
        #expect(markdown.contains("## Notes\n\nBring the budget."))
        #expect(markdown.contains("**[00:05] Ada Lovelace:** Let us start."))
        // Ueber einer Stunde braucht die Stunde, sonst wiederholt sich 11:11.
        #expect(markdown.contains("**[1:01:11] Other:** Agreed."))
    }

    @Test("an unresolved speaker keeps its technical name instead of a guess")
    func doesNotGuessSpeakerNames() {
        let runID = RunID()
        let markdown = MeetingMarkdown.render(
            MeetingMarkdown.Input(
                meeting: meeting(),
                revision: revision([
                    turn(.cluster(runID: runID, clusterID: "SPEAKER_2"), "Hello.", at: 0),
                    turn(nil, "Anonymous line.", at: 10),
                ])
            ),
            calendar: calendar
        )

        // Ein falscher Name in einem Dokument, das jemand weitergibt, ist der
        // teuerste Fehler dieser Kette - lieber die technische Bezeichnung.
        #expect(markdown.contains("**[00:00] Speaker SPEAKER_2:** Hello."))
        #expect(markdown.contains("**[00:10] Unknown speaker:** Anonymous line."))
    }

    @Test("an imported text label is rendered without local person evidence")
    func rendersImportedTextLabelWithoutPersonEvidence() {
        let imported = SpeakerReference.importedTextLabel(
            ImportedSpeakerTextLabel(
                id: UUID(uuidString: "00000000-0000-7000-8000-000000000020")!,
                text: "Ada",
                wasConfirmedAtSource: true
            )
        )
        let review = MeetingReviewData(
            runID: RunID(),
            clusters: [],
            suggestions: [],
            resolutions: [],
            persons: []
        )
        let importedRevision = revision([turn(imported, "Imported words.", at: 0)])
        let markdown = MeetingMarkdown.render(
            MeetingMarkdown.Input(meeting: meeting(), revision: importedRevision),
            calendar: calendar
        )

        #expect(markdown.contains("**[00:00] Ada:** Imported words."))
        #expect(review.confirmedPerson(for: imported) == nil)
        #expect(review.confirmedName(for: imported) == nil)
        #expect(TemplateParticipants.list(revision: importedRevision, review: review) == ["Ada"])
    }

    @Test("imported labels keep source confirmation separate from local names")
    func importedLabelsIgnoreLocalNamesAndHideUnconfirmedText() {
        let confirmed = SpeakerReference.importedTextLabel(
            ImportedSpeakerTextLabel(
                id: UUID(uuidString: "00000000-0000-7000-8000-000000000021")!,
                text: "Ada",
                wasConfirmedAtSource: true
            )
        )
        let unconfirmed = SpeakerReference.importedTextLabel(
            ImportedSpeakerTextLabel(
                id: UUID(uuidString: "00000000-0000-7000-8000-000000000022")!,
                text: "Ada",
                wasConfirmedAtSource: false
            )
        )
        let review = MeetingReviewData(
            runID: RunID(),
            clusters: [],
            suggestions: [],
            resolutions: [],
            persons: []
        )
        let importedRevision = revision([
            turn(confirmed, "Confirmed words.", at: 0),
            turn(unconfirmed, "Unconfirmed words.", at: 5),
        ])
        let markdown = MeetingMarkdown.render(
            MeetingMarkdown.Input(
                meeting: meeting(),
                revision: importedRevision,
                speakerNames: [confirmed: "Mallory", unconfirmed: "Mallory"]
            ),
            calendar: calendar
        )

        #expect(markdown.contains("**[00:00] Ada:** Confirmed words."))
        #expect(markdown.contains("**[00:05] Unknown speaker:** Unconfirmed words."))
        #expect(!markdown.contains("Mallory"))
        #expect(TemplateParticipants.list(revision: importedRevision, review: review) == ["Ada", "Speaker 1"])
    }

    @Test("a meeting without a transcript says so instead of ending blank")
    func statesTheMissingTranscript() {
        let markdown = MeetingMarkdown.render(
            MeetingMarkdown.Input(meeting: meeting(), revision: nil),
            calendar: calendar
        )

        #expect(markdown.contains("## Transcript"))
        #expect(markdown.contains("_No transcript yet._"))
        #expect(!markdown.contains("Participants"))
        #expect(!markdown.contains("## Notes"))
    }

    @Test("reports appear with their template name, before the transcript")
    func includesReports() {
        let report = TemplateResult(
            markdown: "- Decided to ship.",
            template: Template(
                id: "minutes",
                name: "Minutes",
                description: "",
                sections: [],
                prompts: TemplatePromptComponents(
                    role: "",
                    mapInstructions: "",
                    reduceInstructions: ""
                )
            ),
            engine: EngineDescriptor(name: "fixture", version: "1"),
            revisionID: RevisionID()
        )

        let markdown = MeetingMarkdown.render(
            MeetingMarkdown.Input(
                meeting: meeting(),
                revision: revision([turn(nil, "Hello.", at: 0)]),
                reports: [report]
            ),
            calendar: calendar
        )

        let minutes = try! #require(markdown.range(of: "## Minutes"))
        let transcript = try! #require(markdown.range(of: "## Transcript"))
        #expect(minutes.lowerBound < transcript.lowerBound)
        #expect(markdown.contains("- Decided to ship."))
    }

    @Test("the file name carries the date and survives a hostile title")
    func buildsASafeFileName() {
        #expect(
            MeetingMarkdown.fileName(for: meeting(), calendar: calendar)
                == "2026-08-06 Board review.md"
        )
        #expect(
            MeetingMarkdown.fileName(
                for: meeting(title: "Q3/Q4: \"plan\"\n"),
                calendar: calendar
            ) == "2026-08-06 Q3 Q4 plan.md"
        )
        // Ein Titel, von dem nichts uebrig bleibt, darf keine namenlose Datei
        // erzeugen.
        #expect(
            MeetingMarkdown.fileName(for: meeting(title: "///"), calendar: calendar)
                == "2026-08-06 meeting.md"
        )
    }

    @Test("empty turns are dropped instead of producing blank speaker lines")
    func dropsEmptyTurns() {
        let markdown = MeetingMarkdown.render(
            MeetingMarkdown.Input(
                meeting: meeting(),
                revision: revision([
                    turn(.channel("Mic"), "   ", at: 0),
                    turn(.channel("Mic"), "Real content.", at: 5),
                ])
            ),
            calendar: calendar
        )

        #expect(markdown.contains("**[00:05] Mic:** Real content."))
        #expect(!markdown.contains("[00:00]"))
    }
}
