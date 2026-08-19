import Foundation
import StenoDomain

public enum PipelineError: Error, Equatable, Sendable {
    case noMediaAssets(MeetingID)
    case noAudioSamples(MeetingID)
    case missingProvider(MediaAsset.Kind)
    case invalidMediaAssetPath(MediaAssetID)
    case mediaAssetChanged(MediaAssetID)
    case invalidMediaSnapshotRoot
    case mediaCleanupRequired(UUID)
    case inconsistentEngineDescriptors
    case unsupportedJobKind(Job.Kind)
    case missingSourceRun(JobID)
    case missingSourceArtifact(RunID)
    case missingSourceMediaAsset(MediaAssetID)
    case missingDiarizationTrack(MediaAssetID)
    case missingTemplateID(JobID)
    case unknownTemplate(String)
    case unknownTextModelEndpoint(String)
    case textModelEndpointConfigurationChanged(String)
    case textModelUnavailable(String)
    case templateRenderInputChanged
    case templateRenderPinsRequired
    case invalidDownstreamJob(JobID)
    case invalidRunArtifact(RunID)
    case corruptRunArtifact(RunID)
    case cancellationTooLate(JobID)
    case importedGenerationChanged(MeetingID)
    case persistenceFailure(String)
}

extension PipelineError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noMediaAssets(let meetingID):
            "Meeting \(meetingID) has no media assets to transcribe."
        case .noAudioSamples:
            "The recording contains no audio samples."
        case .missingProvider(let kind):
            "No transcription provider is configured for \(kind.rawValue)."
        case .invalidMediaAssetPath(let assetID):
            "Media asset \(assetID) has an invalid registered file name."
        case .mediaAssetChanged(let assetID):
            "Media asset \(assetID) changed while it was being bound for processing."
        case .invalidMediaSnapshotRoot:
            "The private pipeline media root could not be verified."
        case .mediaCleanupRequired(let sessionID):
            "Pipeline media cleanup for session \(sessionID) must be retried."
        case .inconsistentEngineDescriptors:
            "All tracks in one final ASR run must use the same engine descriptor."
        case .unsupportedJobKind(let kind):
            "Pipeline job kind \(kind.rawValue) is not supported by this coordinator."
        case .missingSourceRun(let jobID):
            "Pipeline job \(jobID) does not identify its source processing run."
        case .missingSourceArtifact(let runID):
            "Source processing run \(runID) is missing or unfinished."
        case .missingSourceMediaAsset(let assetID):
            "Source media asset \(assetID) is missing or changed."
        case .missingDiarizationTrack(let assetID):
            "Diarization output for media asset \(assetID) is missing."
        case .missingTemplateID(let jobID):
            "Template render job \(jobID) does not identify its template."
        case .unknownTemplate(let templateID):
            "Template \(templateID) is not available."
        case .unknownTextModelEndpoint:
            "Der ausgewählte Textmodell-Endpunkt ist nicht mehr verfügbar."
        case .textModelEndpointConfigurationChanged:
            "The selected text-model endpoint changed after this report was queued. Create the report again."
        case .textModelUnavailable(let message):
            message
        case .templateRenderInputChanged:
            "The report input changed after it was queued. Create the report again."
        case .templateRenderPinsRequired:
            "This external report predates the required input and endpoint safeguards. Review the current report preview and create the report again."
        case .invalidDownstreamJob(let jobID):
            "Downstream pipeline job \(jobID) conflicts with its deterministic provenance."
        case .invalidRunArtifact(let runID):
            "Processing run \(runID) is incomplete or inconsistent."
        case .corruptRunArtifact(let runID):
            "Processing run \(runID) was corrupt and has been quarantined."
        case .cancellationTooLate(let jobID):
            "Job \(jobID) has crossed its atomic commit point and can no longer be cancelled."
        case .importedGenerationChanged:
            "Imported meeting generation changed."
        case .persistenceFailure(let message):
            "The pipeline could not persist its terminal state: \(message)"
        }
    }
}
