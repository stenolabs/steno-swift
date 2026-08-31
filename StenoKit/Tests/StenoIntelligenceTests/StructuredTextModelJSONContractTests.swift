import Foundation
import StenoDomain
import Testing
@testable import StenoIntelligence

@Suite("Structured local text-model JSON contract")
struct StructuredTextModelJSONContractTests {
    @Test("the exact counted prompt includes policy, request, locale, and output shape")
    func promptIsComplete() {
        let template = Template.meetingMinutes
        let prompt = StructuredTextModelJSONContract.prompt(
            template: template,
            request: .map(TranscriptChunk(turns: [
                TranscriptChunkTurn(
                    speakerName: "Speaker 1",
                    start: 1.25,
                    end: 2.5,
                    text: "Budget approved."
                ),
            ])),
            context: RenderContext(outputLocaleIdentifier: "en-GB")
        )

        #expect(prompt.contains("System instructions:"))
        #expect(prompt.contains("Required output language and locale: en-GB."))
        #expect(prompt.contains("Budget approved."))
        #expect(prompt.contains("Required JSON shape example:"))
        #expect(prompt.contains("\"sections\""))
    }

    @Test("strict decoder accepts the exact keyed shape")
    func strictDecoderAcceptsExactShape() throws {
        let template = Template.meetingMinutes
        let sections = Dictionary(
            uniqueKeysWithValues: template.generatedSections.map {
                ($0.id, "value for \($0.id)")
            }
        )
        let data = try JSONSerialization.data(
            withJSONObject: ["sections": sections],
            options: [.sortedKeys]
        )
        let text = try #require(String(data: data, encoding: .utf8))

        let output = try StructuredTextModelJSONContract.decode(text, template: template)

        #expect(output.sections.map(\.sectionID) == template.generatedSections.map(\.id))
    }

    @Test("strict decoder rejects prose and outer code fences")
    func strictDecoderRejectsWrappers() {
        let template = Template.meetingMinutes

        #expect(throws: StructuredTextModelJSONContractError.invalidOutput) {
            _ = try StructuredTextModelJSONContract.decode(
                #"Here is the result: {"sections":{}}"#,
                template: template
            )
        }
        #expect(throws: StructuredTextModelJSONContractError.invalidOutput) {
            _ = try StructuredTextModelJSONContract.decode(
                "```json\n{\"sections\":{}}\n```",
                template: template
            )
        }
    }
}
