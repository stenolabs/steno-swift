import Foundation
import StenoDomain
import Testing
@testable import StenoIntelligence

@Suite("Outbound disclosure")
struct OutboundDisclosureTests {
    @Test("disclosure lists only the prompt data classes that are present")
    func listsPresentPromptDataClasses() {
        let revisionWithTurns = TranscriptRevision(
            meetingID: MeetingID(),
            origin: .liveProvisional,
            turns: [
                TranscriptTurn(
                    speaker: .channel("Microphone"),
                    start: 0,
                    end: 1,
                    segments: [
                        TranscriptSegment(text: "Agenda", start: 0, end: 1, words: []),
                    ]
                ),
            ]
        )

        #expect(
            OutboundDisclosure(transcript: revisionWithTurns, context: .empty).classes
                == [.transcriptWithSpeakerNames]
        )
        #expect(
            OutboundDisclosure(
                transcript: revisionWithTurns,
                context: RenderContext(participants: ["Ada Lovelace"])
            ).classes == [.transcriptWithSpeakerNames, .participants]
        )
        #expect(
            OutboundDisclosure(
                transcript: revisionWithTurns,
                context: RenderContext(
                    userNotes: "Project Aurora",
                    participants: ["Ada"]
                )
            ).classes == [
                .transcriptWithSpeakerNames,
                .participants,
                .userNotes,
            ]
        )
    }

    @Test("empty input discloses no prompt data")
    func emptyInputDisclosesNoPromptData() {
        let emptyRevision = TranscriptRevision(
            meetingID: MeetingID(),
            origin: .liveProvisional,
            turns: []
        )

        #expect(
            OutboundDisclosure(
                transcript: emptyRevision,
                context: RenderContext(userNotes: "   ", participants: [])
            ).classes.isEmpty
        )
        #expect(PromptDataClass.allCases.count == 3)
    }

    @Test("external notice renders multiple data classes as one English sentence")
    func externalNoticeRendersEnglishSentence() throws {
        let endpoint = makeTextModelEndpoint(
            name: "Remote model",
            baseURL: URL(string: "https://models.example.com/v1")!,
            modelID: "gemma-3",
            requiresAPIKey: true
        )
        let revision = TranscriptRevision(
            meetingID: MeetingID(),
            origin: .legacyImport,
            turns: [TranscriptTurn(start: 0, end: 1, segments: [])]
        )
        let disclosure = OutboundDisclosure(
            transcript: revision,
            context: RenderContext(
                userNotes: "notes",
                participants: ["Ada, Example Org"]
            )
        )

        let notice = try ExternalModelNotice(
            endpoint: endpoint,
            disclosure: disclosure,
            localDeviceDescription: "this Mac"
        )

        #expect(
            notice.text
                == "Generating sends transcript with speaker names, participants, and your notes to \u{201C}Remote model\u{201D} (models.example.com). Audio, structured profile email fields, and attachments are not added to the model input. Email addresses written into the meeting text or the notes are included with it."
        )
    }
}
