import StenoDomain
import Testing
@testable import StenoIdentity

@Suite("Identity confirmation flow")
struct ConfirmationFlowTests {
    private let engine = SpeakerSuggestionEngine()

    @Test("mutual hard negatives cover every cluster of a many-to-one assignment and rebuild on reassign")
    func manyToOneHardNegatives() throws {
        let meetingID = MeetingID()
        let runID = RunID()
        let ada = Person(displayName: "Ada")
        let bob = Person(displayName: "Bob")
        var state = IdentityReviewState(
            meetingID: meetingID,
            currentRunID: runID,
            voiceEvidenceMutationPolicy: .allowed,
            clusters: [
                makeCluster(meetingID: meetingID, runID: runID, clusterID: "A1", distance: 0),
                makeCluster(meetingID: meetingID, runID: runID, clusterID: "A2", distance: 0.8),
                makeCluster(meetingID: meetingID, runID: runID, clusterID: "B1", distance: 1.5),
            ],
            persons: [ada, bob]
        )
        state = try engine.confirm(
            clusterID: "A1", channel: "system", runID: runID,
            as: ada.id, in: state
        ).state
        state = try engine.confirm(
            clusterID: "A2", channel: "system", runID: runID,
            as: ada.id, in: state
        ).state
        state = try engine.confirm(
            clusterID: "B1", channel: "system", runID: runID,
            as: bob.id, in: state
        ).state

        #expect(Set(person(bob.id, in: state)?.hardNegatives.map(\.clusterID) ?? []) == ["A1", "A2"])
        #expect(person(ada.id, in: state)?.hardNegatives.map(\.clusterID) == ["B1"])

        let reassigned = try engine.reassign(
            clusterID: "A1", channel: "system", runID: runID,
            to: bob.id, in: state
        )
        state = reassigned.state

        #expect(reassigned.status == .reassigned)
        #expect(reassigned.reassignedFrom == [ada.id])
        #expect(Set(person(ada.id, in: state)?.hardNegatives.map(\.clusterID) ?? []) == ["A1", "B1"])
        #expect(person(bob.id, in: state)?.hardNegatives.map(\.clusterID) == ["A2"])

        state = try engine.markMultiple(
            clusterID: "A1", channel: "system", runID: runID,
            in: state
        ).state
        let bobPrototypes = try #require(person(bob.id, in: state)?.prototypes)
        #expect(bobPrototypes.filter(\.isActive).map(\.clusterID) == ["B1"])
        #expect(bobPrototypes.first { $0.clusterID == "A1" }?.isActive == false)
        #expect(person(ada.id, in: state)?.hardNegatives.map(\.clusterID) == ["B1"])
        #expect(state.participantIDs.contains(bob.id))
    }

    @Test("keepGeneric records review progress without creating identity evidence")
    func keepGenericDoesNotCreateEvidence() throws {
        let meetingID = MeetingID()
        let runID = RunID()
        let ada = Person(displayName: "Ada")
        let state = IdentityReviewState(
            meetingID: meetingID,
            currentRunID: runID,
            voiceEvidenceMutationPolicy: .allowed,
            clusters: [makeCluster(meetingID: meetingID, runID: runID, clusterID: "A")],
            persons: [ada]
        )

        let result = try engine.keepGeneric(
            clusterID: "A", channel: "system", runID: runID,
            in: state
        )

        #expect(result.status == .generic)
        #expect(result.state.clusters.first?.reviewState == .generic)
        #expect(result.state.persons == state.persons)
    }
}
