import Foundation
import StenoDomain
import Testing
@testable import StenoIdentity

/// Manual enrollment: the dominant-voice selection and the exact tagging of
/// the stored prototype. The tagging is load-bearing - the suggestion engine's
/// context fallback only stays correct while enrollment evidence carries no
/// meeting, run, or channel of its own.
@Suite("Manual voice enrollment")
struct VoiceEnrollmentTests {

    private func candidate(
        clusterID: String,
        duration: TimeInterval,
        segments: Int = 2,
        embedding: [Float] = [1, 0]
    ) -> VoiceEnrollmentCandidate {
        VoiceEnrollmentCandidate(
            clusterID: clusterID,
            embedding: embedding,
            speechDurationSeconds: duration,
            segmentCount: segments
        )
    }

    @Test("the voice with the most speaking time wins")
    func dominantPicksLongestVoice() throws {
        let quiet = candidate(clusterID: "SPEAKER_0", duration: 4)
        let loud = candidate(clusterID: "SPEAKER_1", duration: 12)

        #expect(try VoiceEnrollmentSelector.dominant([quiet, loud]).clusterID == "SPEAKER_1")
    }

    @Test("a duration tie falls to the lowest cluster ID deterministically")
    func tieFallsToLowestClusterID() throws {
        let first = candidate(clusterID: "SPEAKER_0", duration: 8)
        let second = candidate(clusterID: "SPEAKER_1", duration: 8)

        #expect(try VoiceEnrollmentSelector.dominant([second, first]).clusterID == "SPEAKER_0")
    }

    @Test("an empty clip reports no speaker at all")
    func emptyClipThrows() {
        #expect(throws: VoiceEnrollmentError.noSpeakerDetected) {
            _ = try VoiceEnrollmentSelector.dominant([])
        }
    }

    @Test("a clip below the measured speech floor is rejected as too short")
    func shortClipThrows() {
        #expect(throws: VoiceEnrollmentError.sampleTooShort(1.5)) {
            _ = try VoiceEnrollmentSelector.dominant([
                candidate(clusterID: "SPEAKER_0", duration: 1.5)
            ])
        }
    }

    @Test("enrollment prototypes are tagged outside every meeting context")
    func prototypeCarriesEnrollmentContext() throws {
        let voice = candidate(
            clusterID: "SPEAKER_2",
            duration: 9,
            segments: 3,
            embedding: [0.6, 0.8]
        )
        let personID = PersonID()
        let date = Date(timeIntervalSince1970: 100)

        let prototype = ManualEnrollment.prototype(
            personID: personID,
            from: voice,
            createdAt: date
        )

        // The whole point of this shape: no channel, meeting, run, or
        // run-scoped cluster ID, so recognition compares it against all
        // contexts instead of averaging across them.
        #expect(prototype.personID == personID)
        #expect(prototype.embedding == [0.6, 0.8])
        #expect(prototype.recordingType == .unknown)
        #expect(prototype.channel == nil)
        #expect(prototype.meetingID == nil)
        #expect(prototype.runID == nil)
        #expect(prototype.clusterID == ManualEnrollment.clusterID)
        #expect(prototype.source == .manualEnrollment)
        #expect(prototype.sampleCount == 1)
        #expect(prototype.speechDurationSeconds == 9)
        #expect(prototype.segmentCount == 3)
        #expect(prototype.createdAt == date)
        // Freshly enrolled evidence counts.
        #expect(prototype.isActive)
    }
}
