import Foundation
import StenoDomain
import StenoExchange
import StenoLibrary

public enum ImportedMeetingProcessingReconcilerError: Error, Equatable, Sendable {
    case invalidLocale
    case manualRetryNotAllowed(MeetingID)
    case commitRecoveryRequired(MeetingID)
    case noAudioForProcessing(MeetingID)
    case importGenerationConflict(MeetingID)
}

enum ImportedMeetingProcessingReconcilerCheckpoint: Equatable, Sendable {
    case afterCandidateStateReadBeforeTransaction
    case beforeManualRetryTransaction(MeetingID)
    case afterEnsureEnqueuedBeforeStateUpdate
}

typealias ImportedMeetingProcessingReconcilerAction = @Sendable (
    ImportedMeetingProcessingReconcilerCheckpoint
) throws -> Void

public struct ImportedMeetingProcessingReconciler: Sendable {
    private let library: Library
    private let stateStore: MeetingTransferStateStore
    private let jobStore: JobStore
    private let checkpoint: ImportedMeetingProcessingReconcilerAction

    public init(
        library: Library,
        stateStore: MeetingTransferStateStore,
        jobStore: JobStore
    ) {
        self.library = library
        self.stateStore = stateStore
        self.jobStore = jobStore
        checkpoint = { _ in }
    }

    init(
        library: Library,
        stateStore: MeetingTransferStateStore,
        jobStore: JobStore,
        checkpoint: @escaping ImportedMeetingProcessingReconcilerAction
    ) {
        self.library = library
        self.stateStore = stateStore
        self.jobStore = jobStore
        self.checkpoint = checkpoint
    }

    public func reconcileAll() async throws {
        for (meetingID, state) in try await stateStore.list() {
            guard case .processingRequested(let request) = state else { continue }
            try checkpoint(.afterCandidateStateReadBeforeTransaction)
            _ = try await reconcile(request, meetingID: meetingID)
        }
    }

    /// Reconciles each visible or transfer-state-bearing meeting independently
    /// during pipeline startup. Candidate enumeration remains a hard startup
    /// gate. Only failures that can be attributed to one meeting's transfer
    /// state or fixed job identity are returned as warnings; every other error
    /// still aborts startup.
    public func reconcileAtPipelineStartup() async throws -> [PipelineStartupWarning] {
        let visibleMeetingIDs = try await library.listMeetings().map(\.id)
        let transferStateMeetingIDs = try await stateStore.listMeetingIDsWithTransferState()
        let meetingIDs = Set(visibleMeetingIDs).union(transferStateMeetingIDs).sorted()
        var warnings: [PipelineStartupWarning] = []
        for meetingID in meetingIDs {
            do {
                try await reconcileStartupCandidate(meetingID: meetingID)
            } catch {
                guard let warning = startupWarning(for: error, meetingID: meetingID) else {
                    throw error
                }
                warnings.append(warning)
            }
        }
        return warnings
    }

    /// Strict reconciliation for a concrete import. The caller receives every
    /// error so a failed processing transition cannot be reported as success.
    public func reconcile(meetingID: MeetingID) async throws {
        guard case .processingRequested(let request) = try await stateStore.load(meetingID)
        else {
            throw LibraryError.invalidImportedMeetingProcessingState(
                "expected processing request is missing"
            )
        }
        try checkpoint(.afterCandidateStateReadBeforeTransaction)
        guard try await reconcile(request, meetingID: meetingID) else {
            throw LibraryError.invalidImportedMeetingProcessingState(
                "expected processing request is no longer current"
            )
        }
    }

    @discardableResult
    public func requestManualRetry(
        meetingID: MeetingID,
        expectedImportGenerationID: MeetingTransferGenerationID,
        localeIdentifier: String,
        modelsReady: Bool
    ) async throws -> ImportedProcessingRequest? {
        let locale = localeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !locale.isEmpty,
              locale == localeIdentifier,
              !locale.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw ImportedMeetingProcessingReconcilerError.invalidLocale
        }
        try checkpoint(.beforeManualRetryTransaction(meetingID))
        let request = try LibraryMutationCoordination.withExclusiveTransaction(
            layout: library.layout
        ) { transaction -> ImportedProcessingRequest? in
            guard let current = try stateStore.load(
                meetingID,
                transaction: transaction
            ) else {
                throw ImportedMeetingProcessingReconcilerError.manualRetryNotAllowed(meetingID)
            }
            let receipt = try stateStore.transferReceipt(
                for: meetingID,
                transaction: transaction
            )
            guard receipt.importGenerationID == expectedImportGenerationID else {
                throw ImportedMeetingProcessingReconcilerError.importGenerationConflict(
                    meetingID
                )
            }
            guard try !stateStore.requiresFreshImportRetry(
                meetingID,
                transaction: transaction
            ) else {
                throw ImportedMeetingProcessingReconcilerError.commitRecoveryRequired(meetingID)
            }
            guard try manualRetryIsAllowed(
                current,
                meetingID: meetingID,
                importGenerationID: expectedImportGenerationID,
                transaction: transaction
            ) else {
                throw ImportedMeetingProcessingReconcilerError.manualRetryNotAllowed(meetingID)
            }
            guard try hasValidatedLocalAudio(
                meetingID: meetingID,
                transaction: transaction
            ) else {
                throw ImportedMeetingProcessingReconcilerError.noAudioForProcessing(meetingID)
            }
            guard modelsReady else {
                guard try stateStore.compareAndSet(
                    expected: current,
                    newState: .awaitingModel(localeIdentifier: locale),
                    for: meetingID,
                    transaction: transaction
                ) == .updated else {
                    throw ImportedMeetingProcessingReconcilerError.manualRetryNotAllowed(
                        meetingID
                    )
                }
                return nil
            }
            let request = ImportedProcessingRequest(
                id: MeetingTransferRequestID(),
                jobID: JobID(),
                meetingID: meetingID,
                localeIdentifier: locale,
                createdAt: Date(),
                importGenerationID: expectedImportGenerationID
            )
            guard try stateStore.compareAndSet(
                expected: current,
                newState: .processingRequested(request),
                for: meetingID,
                transaction: transaction
            ) == .updated else {
                throw ImportedMeetingProcessingReconcilerError.manualRetryNotAllowed(meetingID)
            }
            return request
        }
        if let request {
            _ = try await reconcile(request, meetingID: meetingID)
        }
        return request
    }

    private func hasValidatedLocalAudio(
        meetingID: MeetingID,
        transaction: LibraryMutationTransaction
    ) throws -> Bool {
        let mediaDirectory = library.layout.mediaDirectory(meetingID).standardizedFileURL
        for asset in try library.listMediaAssets(
            meetingID: meetingID,
            transaction: transaction
        ) {
            guard asset.meetingID == meetingID,
                  !asset.fileName.isEmpty,
                  asset.fileName != ".",
                  asset.fileName != "..",
                  URL(fileURLWithPath: asset.fileName).lastPathComponent == asset.fileName
            else { continue }
            let source = library.layout.mediaFile(
                meetingID,
                fileName: asset.fileName
            ).standardizedFileURL
            guard source.deletingLastPathComponent() == mediaDirectory else { continue }
            if let inspection = try? MeetingTransferAudioInspector().inspectCAFSource(at: source),
               inspection.byteCount > 0,
               inspection.duration > 0 {
                return true
            }
        }
        return false
    }

    private func manualRetryIsAllowed(
        _ state: ImportedMeetingProcessingState,
        meetingID: MeetingID,
        importGenerationID: MeetingTransferGenerationID,
        transaction: LibraryMutationTransaction
    ) throws -> Bool {
        switch state {
        case .importedOnly,
             .awaitingLanguageConfirmation,
             .awaitingModel:
            return true
        case .processingRequested:
            return false
        case .jobEnqueued(let jobID, _),
             .needsManualRetry(let jobID, _, _):
            let job = try jobStore.load(jobID, transaction: transaction)
            guard job.meetingID == meetingID,
                  job.importGenerationID == importGenerationID else { return false }
            return job.status == .failed || job.status == .cancelled
        }
    }

    private func reconcile(
        _ request: ImportedProcessingRequest,
        meetingID: MeetingID
    ) async throws -> Bool {
        guard request.meetingID == meetingID else {
            throw LibraryError.invalidImportedMeetingProcessingState(
                "processing request meeting mismatch"
            )
        }
        return try LibraryMutationCoordination.withExclusiveTransaction(
            layout: library.layout
        ) { transaction in
            let current = try stateStore.load(
                meetingID,
                transaction: transaction
            )
            let requiresFreshImportRetry = try stateStore.requiresFreshImportRetry(
                meetingID,
                transaction: transaction
            )
            guard current == .processingRequested(request),
                  !requiresFreshImportRetry else {
                return false
            }
            let job = Job(
                id: request.jobID,
                kind: .finalASR,
                meetingID: request.meetingID,
                localeIdentifier: request.localeIdentifier,
                importGenerationID: request.importGenerationID,
                createdAt: request.createdAt
            )
            _ = try jobStore.ensureEnqueued(job, transaction: transaction)
            try checkpoint(.afterEnsureEnqueuedBeforeStateUpdate)
            return try stateStore.compareAndSet(
                expected: .processingRequested(request),
                newState: .jobEnqueued(
                    jobID: request.jobID,
                    localeIdentifier: request.localeIdentifier
                ),
                for: meetingID,
                transaction: transaction
            ) == .updated
        }
    }

    private func reconcileStartupCandidate(meetingID: MeetingID) async throws {
        guard case .processingRequested(let request) = try await stateStore.load(meetingID)
        else {
            return
        }
        try checkpoint(.afterCandidateStateReadBeforeTransaction)
        _ = try await reconcile(request, meetingID: meetingID)
    }

    private func startupWarning(
        for error: Error,
        meetingID: MeetingID
    ) -> PipelineStartupWarning? {
        guard let libraryError = error as? LibraryError else { return nil }
        let issue: ImportedMeetingProcessingStartupIssue
        switch libraryError {
        case .invalidImportedMeetingProcessingState:
            issue = .invalidTransferState
        case .jobIdentityConflict:
            issue = .jobIdentityConflict
        case .unsupportedSchemaVersion(let document, _, _)
            where document.standardizedFileURL
                == library.layout.transferState(meetingID).standardizedFileURL:
            issue = .invalidTransferState
        case .corruptDocument(let original, _)
            where original.standardizedFileURL
                == library.layout.transferState(meetingID).standardizedFileURL:
            issue = .invalidTransferState
        default:
            return nil
        }
        return .importedMeetingProcessing(meetingID: meetingID, issue: issue)
    }
}
