import StenoDomain
import Testing
@testable import StenoIdentity

@Suite("Identity clusters")
struct IdentityClusterTests {
    @Test("cluster context keeps channel and run provenance")
    func keepsProvenance() {
        let meetingID = MeetingID()
        let runID = RunID()
        let cluster = IdentityCluster(
            meetingID: meetingID,
            runID: runID,
            channel: "mic",
            clusterID: "SPEAKER_0",
            recordingType: .inPerson,
            embedding: [1, 0],
            speechDurationSeconds: 20,
            segmentCount: 3
        )

        #expect(cluster.meetingID == meetingID)
        #expect(cluster.runID == runID)
        #expect(cluster.channel == "mic")
    }
}
