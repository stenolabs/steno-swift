import Foundation
import StenoDomain

/// One diarized speaker found in an enrollment recording or imported clip.
///
/// The extractor (WeSpeaker-backed, see StenoPipeline) runs the very same
/// models over the sample that meeting processing uses, so an
/// enrollment-time embedding is directly comparable to a match-time cluster
/// embedding - averaging across differently produced embeddings would quietly
/// break every distance gate.
public struct VoiceEnrollmentCandidate: Equatable, Sendable {
    public let clusterID: String
    public let embedding: [Float]
    public let speechDurationSeconds: TimeInterval
    public let segmentCount: Int

    public init(
        clusterID: String,
        embedding: [Float],
        speechDurationSeconds: TimeInterval,
        segmentCount: Int
    ) {
        self.clusterID = clusterID
        self.embedding = embedding
        self.speechDurationSeconds = speechDurationSeconds
        self.segmentCount = segmentCount
    }
}

public enum VoiceEnrollmentError: Error, Equatable, Sendable {
    /// The clip produced no usable speaker embedding at all.
    case noSpeakerDetected
    /// The loudest speaker spoke less than `VoiceEnrollmentSelector.minimumSpeechSeconds`.
    case sampleTooShort(TimeInterval)
}

/// Picks the enrolled voice out of a diarized enrollment clip.
///
/// Legacy parity (`simple_recorder.py`): a clean solo clip diarizes as
/// effectively one speaker; whichever voice carries the most total speaking
/// time is the enrollment voice. Ties fall to the lowest cluster ID so the
/// outcome is deterministic.
public enum VoiceEnrollmentSelector {

    /// Below this much detected speech the centroid is noise, not a voice.
    /// Measured floor from the legacy enrollment path, which required 3 s
    /// before a sample could anchor anything.
    public static let minimumSpeechSeconds: TimeInterval = 3.0

    public static func dominant(
        _ candidates: [VoiceEnrollmentCandidate]
    ) throws -> VoiceEnrollmentCandidate {
        let usable = candidates.filter { !$0.embedding.isEmpty }
        guard let best = usable.max(by: { lhs, rhs in
            if lhs.speechDurationSeconds != rhs.speechDurationSeconds {
                return lhs.speechDurationSeconds < rhs.speechDurationSeconds
            }
            return lhs.clusterID > rhs.clusterID
        }) else {
            throw VoiceEnrollmentError.noSpeakerDetected
        }
        guard best.speechDurationSeconds >= minimumSpeechSeconds else {
            throw VoiceEnrollmentError.sampleTooShort(best.speechDurationSeconds)
        }
        return best
    }
}

/// Builds the stored evidence for one manual enrollment capture.
///
/// An enrollment prototype is deliberately tagged as *outside* every meeting
/// run: no channel, no meeting, no run, and the stable `enrollment` cluster
/// marker instead of a run-scoped cluster ID. Its recording type stays
/// `unknown` so recognition falls back to comparing it against all contexts -
/// a voice recorded at the desk must not silently vanish from remote meetings,
/// and inventing a context the sample never had would average across contexts
/// by the back door. The `manualEnrollment` source is what distinguishes it
/// from meeting-confirmed evidence everywhere it is displayed.
public enum ManualEnrollment {

    public static let clusterID = "enrollment"

    public static func prototype(
        personID: PersonID,
        from candidate: VoiceEnrollmentCandidate,
        createdAt: Date = Date()
    ) -> SpeakerPrototype {
        SpeakerPrototype(
            personID: personID,
            embedding: candidate.embedding,
            sampleCount: 1,
            qualityScore: nil,
            recordingType: .unknown,
            channel: nil,
            meetingID: nil,
            runID: nil,
            clusterID: Self.clusterID,
            speechDurationSeconds: candidate.speechDurationSeconds,
            segmentCount: candidate.segmentCount,
            source: .manualEnrollment,
            createdAt: createdAt
        )
    }
}
