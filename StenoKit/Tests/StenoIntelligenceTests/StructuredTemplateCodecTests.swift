import Foundation
import StenoDomain
@testable import StenoIntelligence
import Testing

@Suite("Structured template codec")
struct StructuredTemplateCodecTests {
    @Test("schema contains every generated section exactly once")
    func schemaUsesUniqueGeneratedSections() throws {
        let template = Template(
            id: "test",
            name: "Test",
            description: "",
            sections: [
                TemplateSection(id: "summary", title: "Summary", prompt: "A"),
                TemplateSection(id: "summary", title: "Duplicate", prompt: "B"),
                TemplateSection(
                    id: "participants",
                    title: "Participants",
                    prompt: "C",
                    source: .speakerList
                ),
                TemplateSection(id: "actions", title: "Actions", prompt: "D"),
            ],
            prompts: TemplatePromptComponents(
                role: "Role",
                mapInstructions: "Map",
                reduceInstructions: "Reduce"
            )
        )

        let schema = StructuredTemplateCodec.schema(for: template)
        let sections = try #require(
            ((schema["properties"] as? [String: Any])?["sections"] as? [String: Any])
        )
        let properties = try #require(sections["properties"] as? [String: Any])
        let required = try #require(sections["required"] as? [String])

        #expect(Set(properties.keys) == ["summary", "actions"])
        #expect(required == ["summary", "actions"])
    }

    @Test("keyed output is decoded in template order")
    func outputUsesTemplateOrder() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "sections": [
                "action-items": "Second",
                "summary": "First",
                "decisions": "Third",
                "key-topics": "Topics",
            ],
        ])

        let output = try StructuredTemplateCodec.decode(
            data,
            template: .meetingMinutes
        )

        #expect(output.sections.map(\.sectionID) == [
            "summary", "key-topics", "decisions", "action-items",
        ])
        #expect(output.sections.first?.markdown == "First")
    }

    @Test("legacy array output is normalized into template order")
    func legacyArrayOutputIsNormalizedIntoTemplateOrder() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "sections": [
                ["sectionID": "action-items", "markdown": "Second"],
                ["sectionID": "summary", "markdown": "First"],
                ["sectionID": "decisions", "markdown": "Third"],
                ["sectionID": "key-topics", "markdown": "Topics"],
            ],
        ])

        let output = try StructuredTemplateCodec.decode(
            data,
            template: .meetingMinutes
        )

        #expect(output.sections.map(\.sectionID) == [
            "summary", "key-topics", "decisions", "action-items",
        ])
        #expect(output.sections.first?.markdown == "First")
    }

    @Test("semantic schema deviations fail closed")
    func invalidSectionsFail() throws {
        for object in [
            ["sections": ["summary": "Only one"]],
            ["sections": [
                "summary": "Summary",
                "key-topics": "Topics",
                "decisions": "Decisions",
                "action-items": "Actions",
                "extra": "No",
            ]],
            ["sections": [
                "summary": 3,
                "key-topics": "Topics",
                "decisions": "Decisions",
                "action-items": "Actions",
            ]],
        ] as [[String: Any]] {
            let data = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: StructuredTemplateCodecError.invalidOutput) {
                try StructuredTemplateCodec.decode(data, template: .meetingMinutes)
            }
        }
    }

    @Test("an empty string is accepted for a section without content")
    func emptyStringIsAcceptedForASection() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "sections": [
                "summary": "",
                "key-topics": "Topics",
                "decisions": "Decisions",
                "action-items": "Actions",
            ],
        ])

        let output = try StructuredTemplateCodec.decode(
            data,
            template: .meetingMinutes
        )

        #expect(output.sections.first?.markdown == "")
    }

    @Test("generic compatibility removes one outer JSON fence only in the fallback path")
    func outerJSONFenceIsOptional() throws {
        let json = """
        {"sections":{"summary":"S","key-topics":"K","decisions":"D","action-items":"A"}}
        """
        let fenced = Data("```json\n\(json)\n```".utf8)

        #expect(throws: StructuredTemplateCodecError.invalidOutput) {
            try StructuredTemplateCodec.decode(fenced, template: .meetingMinutes)
        }
        let output = try StructuredTemplateCodec.decode(
            fenced,
            template: .meetingMinutes,
            allowsOuterJSONCodeFence: true
        )
        #expect(output.sections.first?.markdown == "S")
    }
}
