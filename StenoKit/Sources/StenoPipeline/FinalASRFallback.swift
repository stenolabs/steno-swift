import CryptoKit
import Foundation
import StenoDomain
import StenoLibrary
import StenoTranscription

/// Automatic one-shot engine fallback for failed final-ASR runs.
///
/// When a final-ASR job fails with an engine/provider error, the coordinator
/// requeues it once against the alternative registered provider: Parakeet,
/// and only while resolution proves it installed and ready. The reverse
/// direction stays manual on purpose - a failed Parakeet run keeps its
/// explicit "Run with Apple" offer instead of silently switching engines -
/// and model-missing failures remain owned by their dedicated launch
/// retriers (`MissingSpeechModelJobRetrier`).
///
/// Loop protection is layered so it survives restarts without extra state:
///
/// 1. Direction: only Apple-pinned or unpinned (legacy) jobs fall back, and
///    always to Parakeet; a Parakeet job has no automatic alternative.
/// 2. Identity: every fallback job carries a deterministic ID derived from
///    its origin job, so repeated failure handling cannot enqueue twice.
/// 3. Chain: a job whose ID equals a derived fallback ID of any other stored
///    job is itself a fallback and never falls back again.
/// 4. Generation: at most one engagement per `processingGenerationID`, proven
///    by run-level provenance (`ProcessingRun.supersededBy`) on the failed
///    runs of same-generation final-ASR jobs.
public enum FinalASRFallback {
    /// Why a failing final-ASR job may or may not fall back.
    public enum Eligibility: Equatable, Sendable {
        case eligible(TranscriptionProviderID)
        case ineligibleError
        case noAlternativeProvider
        case alternativeNotReady
        case fallbackAlreadyEngaged
    }

    /// What the coordinator needs to persist alongside the original failure.
    public struct Engagement: Equatable, Sendable {
        /// Run of the failed original job; receives `supersededBy`.
        public let originalRunID: RunID
        /// Deterministic run of the fallback job; recorded as the value of
        /// `supersededBy` on the failed original run.
        public let fallbackRunID: RunID
        /// Distinct user-visible message for the job-failure notice channel.
        public let noticeMessage: String
    }

    // MARK: - Error classification

    /// The model-missing family. These have dedicated recovery paths
    /// (`MissingSpeechModelJobRetrier` and friends) and must bypass the
    /// automatic fallback entirely.
    public static func isModelMissing(_ error: any Error) -> Bool {
        // Cast first: bare-dot cases on `any Error` can resolve against the
        // wrong protocol surface under Swift 6.
        guard let transcriptionError = error as? TranscriptionError else {
            return false
        }
        switch transcriptionError {
        case .speechTranscriberUnavailable,
             .noSupportedLocale,
             .assetsUnsupported,
             .assetsNotInstalled,
             .assetInstallationUnavailable:
            return true
        default:
            return false
        }
    }

    /// An engine/provider error eligible for one automatic requeue.
    /// Cancellation is a deliberate user action, and model-missing errors
    /// have their own retriers; both stay out of the fallback path.
    public static func isEngineProviderError(_ error: any Error) -> Bool {
        !(error is CancellationError) && !isModelMissing(error)
    }

    // MARK: - Provider direction

    /// The alternative registered provider for automatic fallback. Only the
    /// Apple side falls back automatically: an unpinned (legacy) job ran as
    /// Apple anyway, and a failed Parakeet run keeps its explicit manual
    /// retry offer. Unknown pinned providers simply remain failed.
    public static func alternativeProvider(
        for providerID: TranscriptionProviderID?
    ) -> TranscriptionProviderID? {
        switch providerID {
        case nil, .apple:
            .parakeetTDTv3
        case .parakeetTDTv3, .some:
            nil
        }
    }

    /// Display name used in the distinct fallback notice message.
    static func providerDisplayName(_ providerID: TranscriptionProviderID) -> String {
        switch providerID {
        case .apple: "Apple Speech"
        case .parakeetTDTv3: "Parakeet"
        default: providerID.rawValue
        }
    }

    /// Distinct message for the existing job-failure notice channel, so a
    /// user can tell "failed outright" from "failed, but a fallback run is
    /// already on its way".
    public static func noticeMessage(
        originalEngineName: String,
        alternative: TranscriptionProviderID
    ) -> String {
        "Transcription with \(originalEngineName) failed. "
            + "One automatic retry with \(providerDisplayName(alternative)) was queued."
    }

    // MARK: - Deterministic identity

    /// Deterministic fallback job ID derived from the failing job. Kept
    /// stable across restarts so engagement stays idempotent; uses the same
    /// domain-separated SHA-256 scheme as `StablePipelineIdentifiers` (its
    /// derivation helper is file-private there, hence this local replica).
    public static func fallbackJobID(after job: Job) -> JobID {
        JobID(rawValue: derive(
            from: job.id.rawValue,
            domain: "steno.fallback-asr-job"
        ))
    }

    /// Run ID the fallback job will produce (runs are derived from jobs).
    public static func fallbackRunID(forFallbackFrom job: Job) -> RunID {
        StablePipelineIdentifiers.runID(for: fallbackJobID(after: job), kind: .finalASR)
    }

    private static func derive(from source: UUID, domain: String) -> UUID {
        var sourceUUID = source.uuid
        let sourceBytes = withUnsafeBytes(of: &sourceUUID) { Array($0) }
        var input = Data(domain.utf8)
        input.append(contentsOf: sourceBytes)
        let digest = Array(SHA256.hash(data: input))
        let bytes: uuid_t = (
            sourceBytes[0], sourceBytes[1], sourceBytes[2], sourceBytes[3],
            sourceBytes[4], sourceBytes[5],
            0x70 | (digest[6] & 0x0f), digest[7],
            0x80 | (digest[8] & 0x3f), digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        )
        return UUID(uuid: bytes)
    }

    // MARK: - Engagement guards

    /// True when `candidate` carries the deterministic ID derived from some
    /// OTHER stored job - i.e. it was created by this fallback and must not
    /// trigger another one.
    public static func isFallbackJob(
        _ candidate: Job,
        among jobs: [Job]
    ) -> Bool {
        jobs.contains {
            $0.id != candidate.id && fallbackJobID(after: $0) == candidate.id
        }
    }

    /// True when a previous engagement already recorded supersession
    /// provenance on any same-generation final-ASR run of this meeting.
    /// This bounds the whole meeting generation to a single fallback even if
    /// further unpinned retries fail later.
    public static func generationHasSupersededRuns(
        for job: Job,
        jobs: [Job],
        layout: LibraryLayout
    ) -> Bool {
        for peer in jobs where peer.kind == .finalASR
            && peer.meetingID == job.meetingID
            && peer.processingGenerationID == job.processingGenerationID {
            let url = layout.runMetadata(
                job.meetingID,
                runID: StablePipelineIdentifiers.runID(for: peer)
            )
            guard
                let data = try? Data(contentsOf: url),
                let run = try? JSONDecoder().decode(ProcessingRun.self, from: data),
                run.supersededBy != nil
            else { continue }
            return true
        }
        return false
    }

    /// Full eligibility decision for engaging the fallback. Pure with respect
    /// to its inputs; the coordinator supplies the store listing, the layout,
    /// and whether the alternative provider resolves for the meeting's asset
    /// kinds (the pipeline's own definition of installed-and-ready).
    public static func eligibility(
        error: any Error,
        job: Job,
        jobs: [Job],
        alternativeProviderIsReady: Bool,
        layout: LibraryLayout
    ) -> Eligibility {
        guard isEngineProviderError(error) else { return .ineligibleError }
        guard let alternative = alternativeProvider(for: job.transcriptionProviderID)
        else { return .noAlternativeProvider }
        guard alternativeProviderIsReady else { return .alternativeNotReady }
        let existingIDs = Set(jobs.map(\.id))
        guard !existingIDs.contains(fallbackJobID(after: job)),
              !isFallbackJob(job, among: jobs),
              !generationHasSupersededRuns(for: job, jobs: jobs, layout: layout)
        else { return .fallbackAlreadyEngaged }
        return .eligible(alternative)
    }

    /// The replacement job: pinned to the alternative provider so a second
    /// failure is attributable and directionally terminal, preserving the
    /// language pin, detection pin, and import generation of the original.
    public static func makeFallbackJob(
        for failedJob: Job,
        alternative: TranscriptionProviderID
    ) -> Job {
        Job(
            id: fallbackJobID(after: failedJob),
            kind: .finalASR,
            meetingID: failedJob.meetingID,
            localeIdentifier: failedJob.localeIdentifier,
            importGenerationID: failedJob.importGenerationID,
            transcriptionProviderID: alternative,
            languageDetection: failedJob.languageDetection
        )
    }
}
