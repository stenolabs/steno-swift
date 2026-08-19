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
                    userNotes: "Synthetic Project",
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
}
