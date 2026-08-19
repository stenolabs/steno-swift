import Foundation
import Testing
@testable import StenoDomain

@Suite("Template domain")
struct TemplateDomainTests {
    @Test("meeting-minutes template defines the five required sections")
    func meetingMinutesSections() {
        let template = Template.meetingMinutes

        #expect(template.id == "meeting-minutes")
        #expect(template.name == "Meeting Minutes")
        #expect(template.sections.map(\.id) == [
            "summary",
            "participants",
            "key-topics",
            "decisions",
            "action-items",
        ])
        #expect(template.sections.map(\.title) == [
            "Summary",
            "Participants",
            "Key Topics",
            "Decisions",
            "Action Items",
        ])
    }

    @Test("participants section is data-based, the other four stay generated")
    func participantsSectionIsDataBased() {
        let template = Template.meetingMinutes

        #expect(
            template.sections.first { $0.id == "participants" }?.source
                == .speakerList
        )
        #expect(template.generatedSections.map(\.id) == [
            "summary",
            "key-topics",
            "decisions",
            "action-items",
        ])
    }

    @Test("stored sections without a source field decode as generated")
    func legacySectionsDecodeAsGenerated() throws {
        let legacyJSON = Data("""
        {"id": "summary", "title": "Zusammenfassung", "prompt": "Fasse zusammen."}
        """.utf8)

        let section = try JSONDecoder().decode(
            TemplateSection.self,
            from: legacyJSON
        )

        #expect(section.source == .generated)
    }

    @Test("template result round-trips template, engine, and revision provenance")
    func templateResultRoundTrip() throws {
        let result = TemplateResult(
            markdown: "## Zusammenfassung\n\nBeschluss gefasst.",
            template: .meetingMinutes,
            engine: EngineDescriptor(
                name: "FoundationModels",
                version: "26.0"
            ),
            revisionID: RevisionID(),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(TemplateResult.self, from: data)

        #expect(decoded == result)
        #expect(decoded.schemaVersion == 1)
    }
}
