import Foundation
import StenoDomain

enum PipelineArtifactValidator {
    static func templateRender(
        _ artifact: TemplateRenderArtifact,
        expectedJobID: JobID,
        expectedRunID: RunID,
        expectedTemplateID: String
    ) -> Bool {
        artifact.schemaVersion == TemplateRenderArtifact.currentSchemaVersion
            && artifact.jobID == expectedJobID
            && StablePipelineIdentifiers.runID(
                for: artifact.jobID,
                kind: .templateRender
            ) == expectedRunID
            && artifact.templateID == expectedTemplateID
            && artifact.result.schemaVersion == TemplateResult.currentSchemaVersion
            && artifact.result.template.id == expectedTemplateID
    }

    static func finalASR(
        _ artifact: FinalASRArtifact,
        expectedJobID: JobID,
        expectedRunID: RunID
    ) -> Bool {
        guard artifact.schemaVersion == FinalASRArtifact.currentSchemaVersion,
              artifact.jobID == expectedJobID,
              StablePipelineIdentifiers.runID(
                for: artifact.jobID,
                kind: .finalASR
              ) == expectedRunID,
              artifact.revisionID == StablePipelineIdentifiers.revisionID(
                for: artifact.jobID,
                kind: .finalASR
              ) else {
            return false
        }
        return Set(artifact.tracks.map(\.assetID)).count == artifact.tracks.count
    }

    static func diarization(
        _ artifact: DiarizationArtifact,
        expectedJobID: JobID,
        expectedRunID: RunID,
        expectedSourceRunID: RunID
    ) -> Bool {
        guard artifact.schemaVersion == DiarizationArtifact.currentSchemaVersion,
              artifact.jobID == expectedJobID,
              artifact.sourceRunID == expectedSourceRunID,
              StablePipelineIdentifiers.runID(
                for: artifact.jobID,
                kind: .diarization
              ) == expectedRunID,
              artifact.revisionID == StablePipelineIdentifiers.revisionID(
                for: artifact.jobID,
                kind: .diarization
              ),
              Set(artifact.tracks.map(\.assetID)).count == artifact.tracks.count else {
            return false
        }
        return artifact.tracks.allSatisfy(validDiarizationTrack)
    }

    static func identitySuggestion(
        _ artifact: IdentitySuggestionArtifact,
        expectedJobID: JobID,
        expectedRunID: RunID,
        expectedSourceRunID: RunID
    ) -> Bool {
        guard artifact.schemaVersion == IdentitySuggestionArtifact.currentSchemaVersion,
              artifact.jobID == expectedJobID,
              artifact.sourceRunID == expectedSourceRunID,
              StablePipelineIdentifiers.runID(
                for: artifact.jobID,
                kind: .identitySuggestion
              ) == expectedRunID,
              !artifact.identityEvidenceFingerprint.isEmpty else {
            return false
        }
        let resolutionKeys = artifact.clusterResolutions.map {
            "\($0.channel)\u{0}\($0.sourceClusterID)"
        }
        let suggestionKeys = artifact.suggestions.map {
            "\($0.channel)\u{0}\($0.clusterID)"
        }
        return Set(resolutionKeys).count == resolutionKeys.count
            && Set(suggestionKeys).count == suggestionKeys.count
    }

    private static func validDiarizationTrack(
        _ track: DiarizationTrackResult
    ) -> Bool {
        guard !track.engine.name.isEmpty, !track.engine.version.isEmpty else {
            return false
        }
        let clusterIDs = track.clusters.map(\.clusterID)
        guard Set(clusterIDs).count == clusterIDs.count,
              clusterIDs.allSatisfy({ !$0.isEmpty }),
              track.clusters.allSatisfy({
                  $0.speechDurationSeconds.isFinite
                      && $0.speechDurationSeconds >= 0
                      && $0.segmentCount >= 0
                      && $0.embedding.allSatisfy(\.isFinite)
              }),
              track.segments.allSatisfy({
                  !$0.clusterID.isEmpty
                      && $0.start.isFinite
                      && $0.end.isFinite
                      && $0.start >= 0
                      && $0.end >= $0.start
              }) else {
            return false
        }
        let grouped = Dictionary(grouping: track.segments, by: \.clusterID)
        guard Set(grouped.keys) == Set(clusterIDs) else { return false }
        return track.clusters.allSatisfy { cluster in
            let segments = grouped[cluster.clusterID] ?? []
            let duration = segments.reduce(0) { $0 + $1.end - $1.start }
            return cluster.segmentCount == segments.count
                && abs(cluster.speechDurationSeconds - duration) < 0.000_001
        }
    }
}
