import Foundation
import Testing
@testable import StenoDomain

@Suite("Identity domain models")
struct IdentityDomainTests {
    @Test("person evidence preserves complete context and run provenance")
    func evidenceRoundTrip() throws {
        let meetingID = MeetingID()
        let runID = RunID()
        let personID = PersonID()
        let prototype = SpeakerPrototype(
            personID: personID,
            embedding: [1, 0],
            recordingType: .remote,
            channel: "system",
            meetingID: meetingID,
            runID: runID,
            clusterID: "SPEAKER_0",
            speechDurationSeconds: 24,
            segmentCount: 4,
            source: .userConfirmed
        )
        let negative = HardNegative(
            personID: personID,
            embedding: [0, 1],
            recordingType: .remote,
            channel: "system",
            meetingID: meetingID,
            runID: runID,
            clusterID: "SPEAKER_1",
            speechDurationSeconds: 21,
            segmentCount: 3,
            source: .userConfirmed
        )
        let person = Person(
            id: personID,
            displayName: "Ada",
            prototypes: [prototype],
            hardNegatives: [negative]
        )

        let decoded = try JSONDecoder().decode(
            Person.self,
            from: JSONEncoder().encode(person)
        )

        #expect(decoded == person)
        #expect(decoded.prototypes.first?.runID == runID)
        #expect(decoded.hardNegatives.first?.channel == "system")
    }

    @Test("cluster suggestion round-trips ranked candidates without assigning a name")
    func suggestionRoundTrip() throws {
        let suggestion = ClusterSuggestion(
            meetingID: MeetingID(),
            runID: RunID(),
            channel: "mic",
            clusterID: "SPEAKER_0",
            status: .possible,
            suggestedPersonID: PersonID(),
            suggestedName: "Ada",
            candidates: [
                SpeakerCandidate(
                    personID: PersonID(),
                    displayName: "Grace",
                    distance: 0.2,
                    hardNegativeConflict: false,
                    confirmedMeetingCount: 1,
                    negativeDistance: nil
                ),
            ],
            reasons: ["human review required"]
        )

        let decoded = try JSONDecoder().decode(
            ClusterSuggestion.self,
            from: JSONEncoder().encode(suggestion)
        )

        #expect(decoded == suggestion)
        #expect(decoded.status == .possible)
    }
}
