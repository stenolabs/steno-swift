import Foundation
import StenoDomain
import StenoLibrary
import StenoTranscription

/// Requeues only final-ASR jobs that failed because the selected locale's
/// speech asset was absent. Readiness is explicit so launch recovery cannot
/// turn a still-unavailable model into an endless retry loop.
public enum MissingSpeechModelJobRetrier {
    public static func requeue(
        jobStore: JobStore,
        locale: Locale,
        modelIsReady: Bool = true
    ) async throws -> [JobID] {
        guard modelIsReady else { return [] }
        let expected = TranscriptionError.assetsNotInstalled(
            localeIdentifier: locale.identifier
        ).localizedDescription
        return try await jobStore.requeueFailedJobs(
            kind: .finalASR,
            errorMessage: expected,
            currentMeetingGenerationOnly: true
        )
    }
}
