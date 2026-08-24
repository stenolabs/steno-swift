import StenoDomain

/// Waehlt einen unterbrochenen Verarbeitungsschritt aus, ohne bereits
/// erfolgreiche Vorstufen erneut auszufuehren. Der neue Job erhaelt eine neue
/// ID, damit das unveraenderliche Artefakt des fehlgeschlagenen Laufs erhalten
/// bleibt.
enum SpeakerProcessingJobSelection {
    static func hasActiveJob(in jobs: [Job]) -> Bool {
        jobs.contains {
            isRelevant($0)
                && ($0.status == .queued || $0.status == .running)
        }
    }

    static func hasActiveJob(
        in jobs: [Job],
        processingGenerationID: MeetingTransferGenerationID?
    ) -> Bool {
        hasActiveJob(in: jobs.filter {
            $0.processingGenerationID == processingGenerationID
        })
    }

    static func retryJob(in jobs: [Job]) -> Job? {
        guard let terminal = unresolvedTerminal(in: jobs) else { return nil }
        return Job(
            kind: terminal.kind,
            meetingID: terminal.meetingID,
            sourceRunID: terminal.sourceRunID,
            localeIdentifier: terminal.localeIdentifier,
            importGenerationID: terminal.processingGenerationID
        )
    }

    static func retryJob(
        in jobs: [Job],
        processingGenerationID: MeetingTransferGenerationID?
    ) -> Job? {
        retryJob(in: jobs.filter {
            $0.processingGenerationID == processingGenerationID
        })
    }

    static func unresolvedFailure(in jobs: [Job]) -> Job? {
        unresolvedTerminal(in: jobs, statuses: [.failed])
    }

    private static func unresolvedTerminal(
        in jobs: [Job],
        statuses: [Job.Status] = [.failed, .cancelled]
    ) -> Job? {
        let relevant = jobs.filter(isRelevant)
        return relevant
            .filter { statuses.contains($0.status) }
            .sorted { $0.createdAt > $1.createdAt }
            .first { terminal in
                !relevant.contains {
                    $0.kind == terminal.kind
                        && $0.status == .finished
                        && $0.createdAt > terminal.createdAt
                }
            }
    }

    private static func isRelevant(_ job: Job) -> Bool {
        job.kind == .finalASR
            || job.kind == .diarization
            || job.kind == .identitySuggestion
    }
}
