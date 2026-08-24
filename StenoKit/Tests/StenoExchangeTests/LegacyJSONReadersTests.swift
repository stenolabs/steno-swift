import Foundation
import Testing
@testable import StenoExchange

@Suite("Legacy JSON readers")
struct LegacyJSONReadersTests {
    private let parser = LegacyTimestampParser(
        timeZone: TimeZone(identifier: "Europe/Berlin")!
    )

    @Test("reads legacy summary JSON")
    func readsSummaryJSON() throws {
        let file = try LegacySummaryJSON.read(
            from: Fixture.url("legacy_summary", extension: "json"),
            timestampParser: parser
        )

        #expect(file.sessionInfo.name == "Altbesprechung")
        #expect(file.sessionInfo.processedAt == Date(timeIntervalSince1970: 1_785_926_096))
        #expect(file.sessionInfo.durationSeconds == 42)
        #expect(file.discussionAreas == [
            LegacyDiscussionArea(title: "Thema", analysis: "Analyse"),
        ])
        #expect(file.participants == ["Grace", "Ada"])
        #expect(file.userNotes == "Notiz")
        #expect(file.folders == ["folder-a"])
    }

    @Test("reads reports in stored order and local ISO dates")
    func readsReports() throws {
        let file = try LegacyReportsFile.read(
            from: Fixture.url("legacy_reports", extension: "json"),
            timestampParser: parser
        )

        #expect(file.activeReport == "rep_new")
        #expect(file.reports.map(\.id) == ["rep_new", "rep_old"])
        #expect(file.reports[0].templateID == "detailed")
        #expect(file.reports[0].createdAt == Date(timeIntervalSince1970: 1_785_926_096))
    }

    @Test("reads folders with optional icons")
    func readsFolders() throws {
        let file = try LegacyFolders.read(
            from: Fixture.url("legacy_folders", extension: "json"),
            timestampParser: parser
        )

        #expect(file.folders.count == 2)
        #expect(file.folders[0].name == "Arbeit")
        #expect(file.folders[0].createdAt == Date(timeIntervalSince1970: 1_785_926_096))
        #expect(file.folders[1].icon == nil)
    }

    @Test("reads arbitrary override values and UTC edit times")
    func readsOverrides() throws {
        let file = try LegacyOverrides.read(
            from: Fixture.url("legacy_overrides", extension: "json"),
            timestampParser: parser
        )

        #expect(file.fields["summary"]?.value == .string("Vom Nutzer geändert"))
        #expect(file.fields["participants"]?.value == .array([.string("Grace"), .string("Ada")]))
        #expect(file.fields["summary"]?.editedAt == Date(timeIntervalSince1970: 1_785_933_296))
    }
}
