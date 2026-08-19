import Foundation
import StenoDomain

public enum EnsureJobResult: Equatable, Sendable {
    case inserted
    case alreadyMatching
}

/// Persisted state of speaker separation for one exact final-ASR generation.
/// The UI derives its presentation from this value instead of keeping a
/// window-local approximation of the job lifecycle.
public enum MeetingDiarizationJobState: Equatable, Sendable {
    case unavailable
    case modelsRequired
    case ready
    case queued
    case running
    case resultsPending
    case completed
    case failed(String?)
}

enum JobStoreEnsureCheckpoint: Equatable, Sendable {
    case afterMissingIdentityBeforeInsert
}

typealias JobStoreEnsureAction = @Sendable (JobStoreEnsureCheckpoint) throws -> Void

public actor JobStore {
    public nonisolated let layout: LibraryLayout
    private nonisolated let ensureAction: JobStoreEnsureAction

    public init(layout: LibraryLayout) throws {
        self.layout = layout
        ensureAction = { _ in }
        try FileManager.default.createDirectory(
            at: layout.jobsDirectory,
            withIntermediateDirectories: true
        )
    }

    init(
        layout: LibraryLayout,
        ensureCheckpoint: @escaping JobStoreEnsureAction
    ) throws {
        self.layout = layout
        ensureAction = ensureCheckpoint
        try FileManager.default.createDirectory(
            at: layout.jobsDirectory,
            withIntermediateDirectories: true
        )
    }

    public func enqueue(_ job: Job) throws {
        try Self.enqueue(job, layout: layout)
    }

    private nonisolated static func enqueue(
        _ job: Job,
        layout: LibraryLayout
    ) throws {
        let url = layout.job(job.id)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw LibraryError.documentAlreadyExists(url)
        }
        guard job.schemaVersion == Job.currentSchemaVersion else {
            throw LibraryError.unsupportedSchemaVersion(
                document: url,
                found: job.schemaVersion,
                supported: Job.currentSchemaVersion
            )
        }
        try JSONDocumentStore.write(job, to: url)
    }

    @discardableResult
    public func ensureEnqueued(_ job: Job) throws -> EnsureJobResult {
        try ensureEnqueuedWithoutLibraryTransaction(job)
    }

    @discardableResult
    package nonisolated func ensureEnqueued(
        _ job: Job,
        transaction: LibraryMutationTransaction
    ) throws -> EnsureJobResult {
        try transaction.validate(layout: layout)
        return try ensureEnqueuedWithoutLibraryTransaction(job)
    }

    private nonisolated func ensureEnqueuedWithoutLibraryTransaction(
        _ job: Job
    ) throws -> EnsureJobResult {
        let url = layout.job(job.id)
        if FileManager.default.fileExists(atPath: url.path) {
            return try Self.matchingResult(for: job, layout: layout)
        }
        guard job.schemaVersion == Job.currentSchemaVersion else {
            throw LibraryError.unsupportedSchemaVersion(
                document: url,
                found: job.schemaVersion,
                supported: Job.currentSchemaVersion
            )
        }
        try ensureAction(.afterMissingIdentityBeforeInsert)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let prepared = try AtomicFile.prepare(try encoder.encode(job), to: url)
        do {
            if try prepared.commitWithoutReplacing() {
                return .inserted
            }
        } catch {
            try? FileManager.default.removeItem(at: prepared.temporaryURL)
            throw error
        }
        return try Self.matchingResult(for: job, layout: layout)
    }

    private nonisolated static func matchingResult(
        for job: Job,
        layout: LibraryLayout
    ) throws -> EnsureJobResult {
        let existing = try load(job.id, layout: layout)
        guard existing.meetingID == job.meetingID,
              existing.kind == job.kind,
              existing.localeIdentifier == job.localeIdentifier,
              existing.sourceRunID == job.sourceRunID,
              existing.templateID == job.templateID,
              existing.revisionID == job.revisionID,
              existing.textModelEndpointID == job.textModelEndpointID,
              existing.textModelEndpointSnapshot == job.textModelEndpointSnapshot,
              existing.templateRenderInputFingerprint
                == job.templateRenderInputFingerprint,
              existing.importGenerationID == job.importGenerationID,
              existing.createdAt == job.createdAt else {
            throw LibraryError.jobIdentityConflict(job.id)
        }
        return .alreadyMatching
    }

    /// Reiht einen Job nur ein, wenn innerhalb derselben Actor-Isolation kein
    /// gleichwertiger blockierender Job existiert. Der zusammengesetzte
    /// Vergleich und das Schreiben muessen atomar bleiben, damit zwei
    /// gleichzeitige UI-Aktionen keine doppelten Pipelines anlegen.
    @discardableResult
    public func enqueueIfNoEquivalentJob(
        _ job: Job,
        blockingStatuses: [Job.Status]
    ) throws -> Bool {
        let exists = try list().contains {
            Self.isEquivalent($0, to: job, blockingStatuses: blockingStatuses)
        }
        guard !exists else { return false }
        try enqueue(job)
        return true
    }

    /// Returns the already persisted blocking job for the exact same pinned
    /// request, or inserts and returns the supplied job. Selection and write
    /// stay in one actor turn, so concurrent callers converge on one JobID.
    @discardableResult
    public func enqueueOrExistingEquivalentJob(
        _ job: Job,
        blockingStatuses: [Job.Status]
    ) throws -> Job {
        try enqueueOrExistingEquivalentJobWithoutLibraryTransaction(
            job,
            blockingStatuses: blockingStatuses
        )
    }

    @discardableResult
    package nonisolated func enqueueOrExistingEquivalentJob(
        _ job: Job,
        blockingStatuses: [Job.Status],
        transaction: LibraryMutationTransaction
    ) throws -> Job {
        try transaction.validate(layout: layout)
        return try enqueueOrExistingEquivalentJobWithoutLibraryTransaction(
            job,
            blockingStatuses: blockingStatuses
        )
    }

    private nonisolated func enqueueOrExistingEquivalentJobWithoutLibraryTransaction(
        _ job: Job,
        blockingStatuses: [Job.Status]
    ) throws -> Job {
        if let existing = try Self.list(layout: layout).first(where: {
            Self.isEquivalent($0, to: job, blockingStatuses: blockingStatuses)
        }) {
            return existing
        }
        try Self.enqueue(job, layout: layout)
        return job
    }

    public func meetingDiarizationState(
        meetingID: MeetingID,
        sourceRunID: RunID,
        importGenerationID: MeetingTransferGenerationID?,
        visibleDiarizationJobID: JobID? = nil,
        pendingDiarizationJobID: JobID? = nil,
        modelsReady: Bool
    ) throws -> MeetingDiarizationJobState {
        try diarizationDecision(
            meetingID: meetingID,
            sourceRunID: sourceRunID,
            importGenerationID: importGenerationID,
            visibleDiarizationJobID: visibleDiarizationJobID,
            pendingDiarizationJobID: pendingDiarizationJobID,
            modelsReady: modelsReady
        ).state
    }

    /// Requests speaker separation for one exact transcript generation.
    /// Selection and mutation stay inside this actor so two windows cannot
    /// enqueue duplicates or both retry the same failed job.
    public func requestMeetingDiarization(
        meetingID: MeetingID,
        sourceRunID: RunID,
        importGenerationID: MeetingTransferGenerationID?,
        visibleDiarizationJobID: JobID? = nil,
        pendingDiarizationJobID: JobID? = nil,
        modelsReady: Bool
    ) throws -> MeetingDiarizationJobState {
        let decision = try diarizationDecision(
            meetingID: meetingID,
            sourceRunID: sourceRunID,
            importGenerationID: importGenerationID,
            visibleDiarizationJobID: visibleDiarizationJobID,
            pendingDiarizationJobID: pendingDiarizationJobID,
            modelsReady: modelsReady
        )
        guard decision.state == .ready else { return decision.state }
        if let retry = decision.retry {
            _ = try transition(retry.id, to: .queued)
        } else {
            try enqueue(Job(
                kind: .diarization,
                meetingID: meetingID,
                sourceRunID: sourceRunID,
                importGenerationID: importGenerationID
            ))
        }
        return .queued
    }

    private func diarizationDecision(
        meetingID: MeetingID,
        sourceRunID: RunID,
        importGenerationID: MeetingTransferGenerationID?,
        visibleDiarizationJobID: JobID?,
        pendingDiarizationJobID: JobID?,
        modelsReady: Bool
    ) throws -> (state: MeetingDiarizationJobState, retry: Job?) {
        let matching = try list().filter {
            $0.kind == .diarization
                && $0.meetingID == meetingID
                && $0.sourceRunID == sourceRunID
                && $0.importGenerationID == importGenerationID
        }
        let finished = matching.filter { $0.status == .finished }
        if finished.contains(where: { $0.id == visibleDiarizationJobID }) {
            return (.completed, nil)
        }
        if finished.contains(where: { $0.id == pendingDiarizationJobID }) {
            return (.resultsPending, nil)
        }
        // The job is persisted as finished before the revision pointer is
        // committed. Until that exact result is visible or parked, keep the UI
        // in a non-terminal state so it reloads after the pointer update.
        if !finished.isEmpty {
            return (.running, nil)
        }
        if matching.contains(where: { $0.status == .running }) {
            return (.running, nil)
        }
        if matching.contains(where: { $0.status == .queued }) {
            return (.queued, nil)
        }
        let terminal = matching
            .filter { $0.status == .failed || $0.status == .cancelled }
            .sorted { $0.createdAt > $1.createdAt }
            .first
        if let terminal {
            if terminal.status == .failed,
               terminal.isDiarizationModelsNotInstalledFailure {
                return modelsReady ? (.ready, terminal) : (.modelsRequired, nil)
            }
            return (
                .failed(terminal.errorMessage),
                nil
            )
        }
        return modelsReady ? (.ready, nil) : (.modelsRequired, nil)
    }

    public func load(_ jobID: JobID) throws -> Job {
        try Self.load(jobID, layout: layout)
    }

    package nonisolated func load(
        _ jobID: JobID,
        transaction: LibraryMutationTransaction
    ) throws -> Job {
        try transaction.validate(layout: layout)
        return try Self.load(jobID, layout: layout)
    }

    private nonisolated static func load(
        _ jobID: JobID,
        layout: LibraryLayout
    ) throws -> Job {
        try JSONDocumentStore.read(
            Job.self,
            from: layout.job(jobID),
            currentSchemaVersion: Job.currentSchemaVersion,
            schemaVersion: \.schemaVersion
        )
    }

    public func list() throws -> [Job] {
        try Self.list(layout: layout)
    }

    private nonisolated static func list(layout: LibraryLayout) throws -> [Job] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: layout.jobsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let jobs = try urls
            .filter { $0.pathExtension == "json" }
            .map {
                try JSONDocumentStore.read(
                    Job.self,
                    from: $0,
                    currentSchemaVersion: Job.currentSchemaVersion,
                    schemaVersion: \.schemaVersion
                )
            }
        return jobs.sorted {
            if $0.createdAt == $1.createdAt { return $0.id < $1.id }
            return $0.createdAt < $1.createdAt
        }
    }

    public func transition(
        _ jobID: JobID,
        to newStatus: Job.Status,
        errorMessage: String? = nil,
        failureReason: Job.FailureReason? = nil
    ) throws -> Job {
        var job = try load(jobID)
        guard Self.allowsTransition(from: job.status, to: newStatus) else {
            throw LibraryError.invalidStatusTransition(
                from: job.status,
                to: newStatus
            )
        }
        if job.status == .queued, newStatus == .running {
            job.attemptCount += 1
        }
        job.status = newStatus
        job.errorMessage = errorMessage
        job.failureReason = newStatus == .failed ? failureReason : nil
        try JSONDocumentStore.write(job, to: layout.job(jobID))
        return job
    }

    public func recoverAtLaunch() throws -> [Job] {
        var recovered: [Job] = []
        for job in try list() where job.status == .running {
            recovered.append(try transition(job.id, to: .queued))
        }
        return recovered
    }

    /// Atomically returns only failed jobs with one exact recoverable reason
    /// to the queue. An optional fixed legacy message shape supports a narrow
    /// upgrade migration for jobs written before typed reasons existed.
    /// Keeping the scan and transitions in this actor method makes repeated
    /// or concurrent user actions idempotent.
    public func requeueFailedJobs(
        kind: Job.Kind,
        failureReason: Job.FailureReason,
        legacyErrorPrefix: String? = nil,
        legacyErrorSuffix: String? = nil
    ) throws -> [JobID] {
        var requeued: [JobID] = []
        for job in try list() where
            job.kind == kind
            && job.status == .failed
            && (
                job.failureReason == failureReason
                || Self.matchesLegacyFailure(
                    job,
                    prefix: legacyErrorPrefix,
                    suffix: legacyErrorSuffix
                )
            )
        {
            _ = try transition(job.id, to: .queued)
            requeued.append(job.id)
        }
        return requeued
    }

    private static func matchesLegacyFailure(
        _ job: Job,
        prefix: String?,
        suffix: String?
    ) -> Bool {
        guard job.failureReason == nil,
              let prefix,
              let suffix,
              let message = job.errorMessage,
              message.hasPrefix(prefix),
              message.hasSuffix(suffix)
        else {
            return false
        }
        return message.count > prefix.count + suffix.count
    }

    private static func isEquivalent(
        _ existing: Job,
        to candidate: Job,
        blockingStatuses: [Job.Status]
    ) -> Bool {
        existing.meetingID == candidate.meetingID
            && existing.kind == candidate.kind
            && existing.sourceRunID == candidate.sourceRunID
            && existing.templateID == candidate.templateID
            && existing.revisionID == candidate.revisionID
            && existing.textModelEndpointID == candidate.textModelEndpointID
            && existing.textModelEndpointSnapshot == candidate.textModelEndpointSnapshot
            && existing.templateRenderInputFingerprint
                == candidate.templateRenderInputFingerprint
            && existing.importGenerationID == candidate.importGenerationID
            && blockingStatuses.contains(existing.status)
    }

    public func containsJob(
        kind: Job.Kind,
        meetingID: MeetingID
    ) throws -> Bool {
        try list().contains {
            $0.kind == kind && $0.meetingID == meetingID
        }
    }

    /// Entfernt alle Jobs eines Meetings (vor dem Löschen des Meetings).
    @discardableResult
    public func removeJobs(meetingID: MeetingID) throws -> [JobID] {
        var removed: [JobID] = []
        for job in try list() where job.meetingID == meetingID {
            try FileManager.default.removeItem(at: layout.job(job.id))
            removed.append(job.id)
        }
        return removed
    }

    public func claimNext(kind: Job.Kind) throws -> Job? {
        guard let job = try list().first(where: {
            $0.kind == kind && $0.status == .queued
        }) else {
            return nil
        }
        return try transition(job.id, to: .running)
    }

    private static func allowsTransition(
        from oldStatus: Job.Status,
        to newStatus: Job.Status
    ) -> Bool {
        switch (oldStatus, newStatus) {
        case (.queued, .running),
             (.queued, .cancelled),
             (.running, .queued),
             (.running, .finished),
             (.running, .failed),
             (.running, .cancelled),
             (.failed, .queued),
             (.failed, .cancelled):
            true
        default:
            false
        }
    }
}

package extension Job {
    var isDiarizationModelsNotInstalledFailure: Bool {
        if failureReason == .diarizationModelsNotInstalled { return true }
        guard failureReason == nil,
              let errorMessage,
              errorMessage.hasPrefix(
                "The speaker separation models are not installed yet (missing: "
              ),
              errorMessage.hasSuffix("). Install them in Steno's settings.")
        else { return false }
        let prefixCount =
            "The speaker separation models are not installed yet (missing: ".count
        let suffixCount = "). Install them in Steno's settings.".count
        return errorMessage.count > prefixCount + suffixCount
    }
}
