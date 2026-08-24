import Foundation
import StenoDomain
import StenoTranscription

/// Leitet die sichtbare Legacy-Aufwertung vollstaendig aus gespeichertem
/// Zustand ab. So bleibt Schritt 2 sichtbar, obwohl Schritt 1 die Herkunft
/// der aktuellen Transkriptrevision bereits auf `.finalRun` umgestellt hat.
enum LegacyUpgradePresentation: Equatable {
    case hidden
    case unavailable
    case ready(actionTitle: String)
    case running(job: Job)
    case failed(message: String, actionTitle: String?)

    static func state(
        meeting: Meeting?,
        revision: TranscriptRevision?,
        reviewRunID: RunID?,
        jobs: [Job],
        hasAudio: Bool,
        needsTranscriptionFirst: Bool
    ) -> Self {
        guard meeting?.metadata?.legacyProvenanceKey != nil else { return .hidden }
        let relevant = jobs.filter({ job in
            job.kind == .finalASR
                || job.kind == .diarization
                || job.kind == .identitySuggestion
        })
        let active = relevant
            .filter({ job in job.status == .running || job.status == .queued })
            .sorted(by: activeOrder)
            .first
        if let active {
            return .running(job: active)
        }
        if let failed = SpeakerProcessingJobSelection.unresolvedFailure(in: relevant) {
            return .failed(
                message: failed.errorMessage ?? "unknown",
                actionTitle: hasAudio ? actionTitle(needsTranscriptionFirst) : nil
            )
        }
        if reviewMatchesCurrentRevision(revision, reviewRunID: reviewRunID) {
            return .hidden
        }
        guard hasAudio else { return .unavailable }
        return .ready(actionTitle: actionTitle(needsTranscriptionFirst))
    }

    /// Welches Modell diesen Schritt ausfuehrt.
    ///
    /// Der Nutzer liest das als Tatsache, also steht hier nur, was der Job
    /// wirklich gepinnt hat. Ein Job ohne Pin stammt aus der Zeit vor der
    /// Modellwahl und laeuft auf Apple; das ist keine Vermutung, sondern die
    /// Aufloesung, die der Koordinator selbst anwendet.
    static func modelTitle(
        for job: Job,
        catalog: TranscriptionModelCatalog = .standard
    ) -> String {
        switch job.kind {
        case .finalASR:
            let providerID = job.transcriptionProviderID ?? .apple
            return catalog.descriptor(for: providerID)?.displayName
                ?? providerID.rawValue
        case .diarization:
            return "FluidAudio speaker separation"
        case .identitySuggestion:
            return "Local voice comparison"
        case .templateRender, .export:
            return "Local processing"
        }
    }

    static func stepTitle(for kind: Job.Kind) -> String {
        switch kind {
        case .finalASR: "Transcription, step 1 of 3"
        case .diarization: "Detecting speakers, step 2 of 3"
        case .identitySuggestion: "Comparing voices, step 3 of 3"
        default: "Processing"
        }
    }

    private static func actionTitle(_ needsTranscriptionFirst: Bool) -> String {
        needsTranscriptionFirst
            ? "Re-transcribe and detect speakers"
            : "Detect speakers"
    }

    private static func activeOrder(_ lhs: Job, _ rhs: Job) -> Bool {
        if lhs.status != rhs.status { return lhs.status == .running }
        return lhs.createdAt < rhs.createdAt
    }

    private static func reviewMatchesCurrentRevision(
        _ revision: TranscriptRevision?,
        reviewRunID: RunID?
    ) -> Bool {
        guard let revision, let reviewRunID else { return false }
        switch revision.origin {
        case .finalRun(let runID):
            return runID == reviewRunID
        case .userEdit:
            return revision.turns.contains { turn in
                guard let speaker = turn.speaker,
                      case .cluster(let runID, _) = speaker
                else { return false }
                return runID == reviewRunID
            }
        case .liveProvisional, .legacyImport, .meetingTransfer, .demo:
            return false
        }
    }
}
