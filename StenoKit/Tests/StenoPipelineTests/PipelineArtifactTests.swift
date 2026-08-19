import Foundation
import StenoDomain
import StenoTranscription
import Testing
@testable import StenoPipeline

@Suite("Pipeline artifacts")
struct PipelineArtifactTests {
    @Test("diarization artifact round-trips segments, cluster evidence, and engine provenance")
    func diarizationArtifactRoundTrip() throws {
        let artifact = DiarizationArtifact(
            jobID: JobID(),
            sourceRunID: RunID(),
            revisionID: RevisionID(),
            tracks: [
                DiarizationTrackResult(
                    assetID: MediaAssetID(),
                    assetKind: .micTrack,
                    engine: EngineDescriptor(
                        name: "FakeDiarization",
                        version: "1.0",
                        modelVersion: "fixture"
                    ),
                    segments: [
                        DiarizationRunSegment(clusterID: "asset/S0", start: 0, end: 2),
                    ],
                    clusters: [
                        DiarizationClusterResult(
                            clusterID: "asset/S0",
                            embedding: [1, 0],
                            speechDurationSeconds: 2,
                            segmentCount: 1
                        ),
                    ]
                ),
            ]
        )

        let decoded = try JSONDecoder().decode(
            DiarizationArtifact.self,
            from: JSONEncoder().encode(artifact)
        )

        #expect(decoded == artifact)
        #expect(decoded.schemaVersion == 1)
    }

    @Test("identity suggestion artifact round-trips without changing speaker names")
    func suggestionArtifactRoundTrip() throws {
        let artifact = IdentitySuggestionArtifact(
            jobID: JobID(),
            sourceRunID: RunID(),
            clusterResolutions: [
                IdentityClusterResolution(
                    channel: "systemTrack",
                    sourceClusterID: "asset/S1",
                    primaryClusterID: "asset/S0"
                ),
            ],
            identityEvidenceFingerprint: "sha256:fixture",
            suggestions: [
                ClusterSuggestion(
                    meetingID: MeetingID(),
                    runID: RunID(),
                    channel: "systemTrack",
                    clusterID: "asset/S0",
                    status: .possible,
                    suggestedPersonID: PersonID(),
                    suggestedName: "Ada"
                ),
            ]
        )

        let decoded = try JSONDecoder().decode(
            IdentitySuggestionArtifact.self,
            from: JSONEncoder().encode(artifact)
        )

        #expect(decoded == artifact)
        #expect(decoded.schemaVersion == 1)
    }

    @Test("rejects duplicate Final ASR tracks and a revision id unrelated to the job")
    func validatesFinalASRStructure() {
        let job = Job(kind: .finalASR, meetingID: MeetingID())
        let track = FinalASRTrackResult(
            assetID: MediaAssetID(),
            assetKind: .micTrack,
            output: TranscriptOutput(localeIdentifier: "de-DE", blocks: [])
        )
        let duplicateTracks = FinalASRArtifact(
            jobID: job.id,
            revisionID: StablePipelineIdentifiers.revisionID(for: job),
            tracks: [track, track]
        )
        let wrongRevision = FinalASRArtifact(
            jobID: job.id,
            revisionID: RevisionID(),
            tracks: [track]
        )

        #expect(!PipelineArtifactValidator.finalASR(
            duplicateTracks,
            expectedJobID: job.id,
            expectedRunID: StablePipelineIdentifiers.runID(for: job)
        ))
        #expect(!PipelineArtifactValidator.finalASR(
            wrongRevision,
            expectedJobID: job.id,
            expectedRunID: StablePipelineIdentifiers.runID(for: job)
        ))
    }

    @Test("rejects duplicate diarization tracks and invalid segment boundaries")
    func validatesDiarizationStructure() {
        let job = Job(kind: .diarization, meetingID: MeetingID(), sourceRunID: RunID())
        let assetID = MediaAssetID()
        let invalidTrack = DiarizationTrackResult(
            assetID: assetID,
            assetKind: .micTrack,
            engine: EngineDescriptor(name: "Fake", version: "1"),
            segments: [
                DiarizationRunSegment(clusterID: "asset/S0", start: 2, end: 1),
            ],
            clusters: [
                DiarizationClusterResult(
                    clusterID: "asset/S0",
                    embedding: [1, 0],
                    speechDurationSeconds: 1,
                    segmentCount: 1
                ),
            ]
        )
        let artifact = DiarizationArtifact(
            jobID: job.id,
            sourceRunID: job.sourceRunID!,
            revisionID: StablePipelineIdentifiers.revisionID(for: job),
            tracks: [invalidTrack, invalidTrack]
        )

        #expect(!PipelineArtifactValidator.diarization(
            artifact,
            expectedJobID: job.id,
            expectedRunID: StablePipelineIdentifiers.runID(for: job),
            expectedSourceRunID: job.sourceRunID!
        ))
    }
}
