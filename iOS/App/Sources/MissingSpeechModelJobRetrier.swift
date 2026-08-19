import Foundation
import StenoDomain
import StenoLibrary
import StenoTranscription

enum MissingSpeechModelJobRetrier {
    static func requeue(jobStore: JobStore, locale: Locale) async throws -> [JobID] {
        let expected = TranscriptionError.assetsNotInstalled(
            localeIdentifier: locale.identifier
        ).localizedDescription
        var requeued: [JobID] = []
        for job in try await jobStore.list() where
            job.kind == .finalASR
            && job.status == .failed
            && job.errorMessage == expected
        {
            _ = try await jobStore.transition(job.id, to: .queued)
            requeued.append(job.id)
        }
        return requeued
    }
}
