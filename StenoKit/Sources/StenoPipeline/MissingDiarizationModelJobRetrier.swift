import StenoDomain
import StenoLibrary

/// Deliberate one-shot recovery after the user has installed the speaker
/// separation bundle. It never creates jobs and cannot touch final ASR.
public enum MissingDiarizationModelJobRetrier {
    // Builds before Job.FailureReason persisted this exact LocalizedError
    // shape. Match both fixed halves and require a non-empty missing-model
    // list so unrelated load and inference failures never become eligible.
    private static let legacyErrorPrefix =
        "The speaker separation models are not installed yet (missing: "
    private static let legacyErrorSuffix =
        "). Install them in Steno's settings."

    public static func requeue(jobStore: JobStore) async throws -> [JobID] {
        try await jobStore.requeueFailedJobs(
            kind: .diarization,
            failureReason: .diarizationModelsNotInstalled,
            legacyErrorPrefix: legacyErrorPrefix,
            legacyErrorSuffix: legacyErrorSuffix
        )
    }
}
