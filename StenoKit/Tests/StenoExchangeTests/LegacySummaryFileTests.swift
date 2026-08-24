import Foundation
import Testing
@testable import StenoExchange

@Suite("Legacy Markdown summary reader")
struct LegacySummaryFileTests {
    @Test("uses the old line parser and extracts all body sections")
    func readsLegacyFrontmatterAndBody() throws {
        let file = try LegacySummaryFile.read(
            from: Fixture.url("meeting_summary", extension: "md"),
            timestampParser: LegacyTimestampParser(
                timeZone: TimeZone(identifier: "Europe/Berlin")!
            )
        )

        #expect(file.title == "Gespräch: Planung")
        #expect(file.durationSeconds == 125)
        #expect(file.isDiarised == true)
        #expect(file.folders == ["folder-a", "folder-b"])
        #expect(file.transcriptCorrectedAt == Date(timeIntervalSince1970: 1_785_933_356))
        #expect(file.summaryGeneratedAt == Date(timeIntervalSince1970: 1_785_926_216))
        #expect(file.updatedAt == Date(timeIntervalSince1970: 1_785_933_476))
        #expect(file.frontmatter["notes_generated"] == .bool(false))
        #expect(file.frontmatter["nullable"] == .null)
        #expect(file.frontmatter["unquoted_colon"] == .string("Wert: bleibt erhalten"))
        #expect(file.body.summary == "Kurze Zusammenfassung.")
        #expect(file.body.keyTopics == [
            LegacySummaryTopic(title: "Migration", body: "Die Daten bleiben lokal."),
            LegacySummaryTopic(title: "Tests", body: "Parser werden geprüft."),
        ])
        #expect(file.body.keyPoints == ["Erster Punkt", "Zweiter Punkt"])
        #expect(file.body.actionItems == ["Import prüfen"])
        #expect(file.body.participants == ["Grace", "Ada"])
        #expect(file.body.transcript == "[00:05] [You] Guten Morgen.")
        #expect(file.body.userNotes == "Eigene Notiz.\n\nMit zweitem Absatz.")
    }

    @Test("recognizes Electron UTC dates and processing placeholders")
    func readsElectronPlaceholder() throws {
        let file = try LegacySummaryFile.read(
            from: Fixture.url("electron_processing_summary", extension: "md"),
            timestampParser: LegacyTimestampParser(timeZone: TimeZone(identifier: "Europe/Berlin")!)
        )

        #expect(file.processing == true)
        #expect(file.date == Date(timeIntervalSince1970: 1_785_933_296))
    }
}
