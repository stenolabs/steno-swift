import Darwin
import Foundation
import StenoDomain

struct MeetingTransferStateDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let state: ImportedMeetingProcessingState

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        state: ImportedMeetingProcessingState
    ) {
        self.schemaVersion = schemaVersion
        self.state = state
    }
}

private struct MeetingTransferCommitPendingDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let meetingID: MeetingID
    let importGenerationID: MeetingTransferGenerationID?
    let sourcePackageContentDigest: String?

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        meetingID: MeetingID,
        importGenerationID: MeetingTransferGenerationID,
        sourcePackageContentDigest: String
    ) {
        self.schemaVersion = schemaVersion
        self.meetingID = meetingID
        self.importGenerationID = importGenerationID
        self.sourcePackageContentDigest = sourcePackageContentDigest
    }
}

public struct MeetingTransferFreshImportRetryToken: Equatable, Sendable {
    public let meetingID: MeetingID
    public let importGenerationID: MeetingTransferGenerationID
    public let sourcePackageContentDigest: String
    public let state: ImportedMeetingProcessingState

    init(
        meetingID: MeetingID,
        importGenerationID: MeetingTransferGenerationID,
        sourcePackageContentDigest: String,
        state: ImportedMeetingProcessingState
    ) {
        self.meetingID = meetingID
        self.importGenerationID = importGenerationID
        self.sourcePackageContentDigest = sourcePackageContentDigest
        self.state = state
    }
}

public enum MeetingTransferStateTransitionResult: Equatable, Sendable {
    case updated
    case stateMismatch(ImportedMeetingProcessingState?)
}

enum MeetingTransferStateStoreCheckpoint: Equatable, Sendable {
    case afterNamespaceLockBeforeBody
}

typealias MeetingTransferStateStoreAction = @Sendable (
    MeetingTransferStateStoreCheckpoint
) throws -> Void

public actor MeetingTransferStateStore {
    private nonisolated let layout: LibraryLayout
    private nonisolated let checkpoint: MeetingTransferStateStoreAction

    public init(layout: LibraryLayout) {
        self.layout = layout
        checkpoint = { _ in }
    }

    init(
        layout: LibraryLayout,
        checkpoint: @escaping MeetingTransferStateStoreAction
    ) {
        self.layout = layout
        self.checkpoint = checkpoint
    }

    public func load(_ meetingID: MeetingID) throws -> ImportedMeetingProcessingState? {
        try withExclusiveStateTransaction { transaction in
            try load(meetingID, transaction: transaction)
        }
    }

    package nonisolated func load(
        _ meetingID: MeetingID,
        transaction: LibraryMutationTransaction
    ) throws -> ImportedMeetingProcessingState? {
        try transaction.validate(layout: layout)
        return try loadWithoutMutationLock(meetingID)
    }

    private nonisolated func loadWithoutMutationLock(
        _ meetingID: MeetingID
    ) throws -> ImportedMeetingProcessingState? {
        let url = layout.transferState(meetingID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let receipt = try transferReceipt(for: meetingID)
        let state = try Self.loadDocument(from: url).state
        try Self.validate(state, meetingID: meetingID, receipt: receipt)
        return state
    }

    public func save(
        _ state: ImportedMeetingProcessingState,
        for meetingID: MeetingID
    ) throws {
        try withExclusiveStateTransaction { transaction in
            try transaction.validate(layout: layout)
            let receipt = try transferReceipt(for: meetingID)
            try Self.write(
                state,
                meetingID: meetingID,
                receipt: receipt,
                to: layout.transferState(meetingID)
            )
        }
    }

    public func compareAndSet(
        expected: ImportedMeetingProcessingState,
        newState: ImportedMeetingProcessingState,
        for meetingID: MeetingID
    ) throws -> MeetingTransferStateTransitionResult {
        try withExclusiveStateTransaction { transaction in
            try compareAndSet(
                expected: expected,
                newState: newState,
                for: meetingID,
                transaction: transaction
            )
        }
    }

    package nonisolated func compareAndSet(
        expected: ImportedMeetingProcessingState,
        newState: ImportedMeetingProcessingState,
        for meetingID: MeetingID,
        transaction: LibraryMutationTransaction
    ) throws -> MeetingTransferStateTransitionResult {
        try transaction.validate(layout: layout)
        let current = try loadWithoutMutationLock(meetingID)
        guard current == expected else {
            return .stateMismatch(current)
        }
        let receipt = try transferReceipt(for: meetingID)
        try Self.write(
            newState,
            meetingID: meetingID,
            receipt: receipt,
            to: layout.transferState(meetingID)
        )
        return .updated
    }

    public func list() throws -> [(MeetingID, ImportedMeetingProcessingState)] {
        try withExclusiveStateTransaction { transaction in
            try list(transaction: transaction)
        }
    }

    package func listMeetingIDsWithTransferState() throws -> [MeetingID] {
        try withExclusiveStateTransaction { transaction in
            try transaction.validate(layout: layout)
            return try listMeetingIDsWithTransferStateWithoutMutationLock()
        }
    }

    package nonisolated func list(
        transaction: LibraryMutationTransaction
    ) throws -> [(MeetingID, ImportedMeetingProcessingState)] {
        try transaction.validate(layout: layout)
        let meetingIDs = try listMeetingIDsWithTransferStateWithoutMutationLock()
        var states: [(MeetingID, ImportedMeetingProcessingState)] = []
        for meetingID in meetingIDs {
            if let state = try loadWithoutMutationLock(meetingID) {
                states.append((meetingID, state))
            }
        }
        return states
    }

    private nonisolated func listMeetingIDsWithTransferStateWithoutMutationLock(
    ) throws -> [MeetingID] {
        let entries = try FileManager.default.contentsOfDirectory(
            at: layout.meetingsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return try entries.compactMap { entry in
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true,
                  let uuid = UUID(uuidString: entry.lastPathComponent) else {
                return nil
            }
            let meetingID = MeetingID(rawValue: uuid)
            guard FileManager.default.fileExists(
                atPath: layout.transferState(meetingID).path
            ) else {
                return nil
            }
            return meetingID
        }.sorted()
    }

    public func requiresFreshImportRetry(_ meetingID: MeetingID) throws -> Bool {
        try withExclusiveStateTransaction { transaction in
            try requiresFreshImportRetry(meetingID, transaction: transaction)
        }
    }

    package nonisolated func requiresFreshImportRetry(
        _ meetingID: MeetingID,
        transaction: LibraryMutationTransaction
    ) throws -> Bool {
        try transaction.validate(layout: layout)
        return try requiresFreshImportRetryWithoutMutationLock(meetingID)
    }

    private nonisolated func requiresFreshImportRetryWithoutMutationLock(
        _ meetingID: MeetingID
    ) throws -> Bool {
        guard let document = try commitPendingDocument(meetingID) else { return false }
        let receipt = try transferReceipt(for: meetingID)
        try validate(document, meetingID: meetingID, receipt: receipt)
        return true
    }

    public func freshImportRetryToken(
        _ meetingID: MeetingID
    ) throws -> MeetingTransferFreshImportRetryToken? {
        try withExclusiveStateTransaction { transaction in
            try freshImportRetryToken(meetingID, transaction: transaction)
        }
    }

    package nonisolated func freshImportRetryToken(
        _ meetingID: MeetingID,
        transaction: LibraryMutationTransaction
    ) throws -> MeetingTransferFreshImportRetryToken? {
        try transaction.validate(layout: layout)
        return try freshImportRetryTokenWithoutMutationLock(meetingID)
    }

    private nonisolated func freshImportRetryTokenWithoutMutationLock(
        _ meetingID: MeetingID
    ) throws -> MeetingTransferFreshImportRetryToken? {
        guard let document = try commitPendingDocument(meetingID) else { return nil }
        let receipt = try transferReceipt(for: meetingID)
        try validate(document, meetingID: meetingID, receipt: receipt)
        guard let importGenerationID = document.importGenerationID,
              let sourcePackageContentDigest = document.sourcePackageContentDigest,
              receipt.importGenerationID == importGenerationID,
              receipt.sourcePackageContentDigest == sourcePackageContentDigest else {
            throw LibraryError.invalidImportedMeetingProcessingState(
                "transfer commit guard has no generation identity"
            )
        }
        guard let state = try loadWithoutMutationLock(meetingID) else {
            throw LibraryError.invalidImportedMeetingProcessingState(
                "transfer commit guard has no processing state"
            )
        }
        return MeetingTransferFreshImportRetryToken(
            meetingID: meetingID,
            importGenerationID: importGenerationID,
            sourcePackageContentDigest: sourcePackageContentDigest,
            state: state
        )
    }

    public func clearFreshImportRetryRequirement(
        _ meetingID: MeetingID,
        expectedImportGenerationID: MeetingTransferGenerationID,
        expectedSourcePackageContentDigest: String,
        expectedState: ImportedMeetingProcessingState
    ) throws {
        try withExclusiveStateTransaction { transaction in
            try transaction.validate(layout: layout)
            guard let current = try freshImportRetryTokenWithoutMutationLock(meetingID) else {
                throw LibraryError.transferImportGenerationConflict(meetingID)
            }
            let expected = MeetingTransferFreshImportRetryToken(
                meetingID: meetingID,
                importGenerationID: expectedImportGenerationID,
                sourcePackageContentDigest: expectedSourcePackageContentDigest,
                state: expectedState
            )
            guard current == expected else {
                throw LibraryError.transferImportGenerationConflict(meetingID)
            }
            let descriptor = try openValidatedMeetingDirectory(meetingID)
            defer { Darwin.close(descriptor) }
            try removeCommitGuard(meetingID, directoryDescriptor: descriptor)
        }
    }

    @discardableResult
    public func resolveFreshImportRetry(
        _ state: ImportedMeetingProcessingState,
        for meetingID: MeetingID,
        expected: MeetingTransferFreshImportRetryToken
    ) throws -> Bool {
        try withExclusiveStateTransaction { transaction in
            try resolveFreshImportRetry(
                state,
                for: meetingID,
                expected: expected,
                transaction: transaction
            )
        }
    }

    package nonisolated func resolveFreshImportRetry(
        _ state: ImportedMeetingProcessingState,
        for meetingID: MeetingID,
        expected: MeetingTransferFreshImportRetryToken,
        transaction: LibraryMutationTransaction
    ) throws -> Bool {
        try transaction.validate(layout: layout)
        guard expected.meetingID == meetingID else {
            throw LibraryError.transferImportGenerationConflict(meetingID)
        }
        guard let current = try freshImportRetryTokenWithoutMutationLock(meetingID) else {
            throw LibraryError.transferImportGenerationConflict(meetingID)
        }
        guard current == expected else {
            throw LibraryError.transferImportGenerationConflict(meetingID)
        }
        let receipt = try transferReceipt(for: meetingID)
        try Self.write(
            state,
            meetingID: meetingID,
            receipt: receipt,
            to: layout.transferState(meetingID)
        )
        let descriptor = try openValidatedMeetingDirectory(meetingID)
        defer { Darwin.close(descriptor) }
        try removeCommitGuard(meetingID, directoryDescriptor: descriptor)
        return true
    }

    private nonisolated func openValidatedMeetingDirectory(
        _ meetingID: MeetingID
    ) throws -> Int32 {
        let path = layout.meetingDirectory(meetingID).path
        let descriptor = path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT {
                throw LibraryError.meetingNotFound(meetingID)
            }
            throw POSIXFailure(operation: "open transfer commit guard directory", code: errno)
        }
        do {
            try verifyMeetingDirectory(descriptor, meetingID: meetingID)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        return descriptor
    }

    private nonisolated func verifyMeetingDirectory(
        _ descriptor: Int32,
        meetingID: MeetingID
    ) throws {
        var descriptorStatus = stat()
        var pathStatus = stat()
        let path = layout.meetingDirectory(meetingID).path
        guard fstat(descriptor, &descriptorStatus) == 0,
              path.withCString({ lstat($0, &pathStatus) }) == 0,
              descriptorStatus.st_mode & S_IFMT == S_IFDIR,
              pathStatus.st_mode & S_IFMT == S_IFDIR,
              descriptorStatus.st_dev == pathStatus.st_dev,
              descriptorStatus.st_ino == pathStatus.st_ino else {
            throw LibraryError.invalidImportedMeetingProcessingState(
                "meeting state lock directory identity mismatch"
            )
        }
    }

    private nonisolated func withExclusiveStateTransaction<Result>(
        _ body: (LibraryMutationTransaction) throws -> Result
    ) throws -> Result {
        try LibraryMutationCoordination.withExclusiveTransaction(layout: layout) {
            transaction in
            try checkpoint(.afterNamespaceLockBeforeBody)
            return try body(transaction)
        }
    }

    private nonisolated func removeCommitGuard(
        _ meetingID: MeetingID,
        directoryDescriptor: Int32
    ) throws {
        let name = layout.transferCommitPending(meetingID).lastPathComponent
        guard unlinkat(directoryDescriptor, name, 0) == 0 else {
            throw POSIXFailure(operation: "remove transfer commit guard", code: errno)
        }
        guard fsync(directoryDescriptor) == 0 else {
            throw POSIXFailure(operation: "fsync transfer commit guard directory", code: errno)
        }
    }

    static func writeCommitPendingGuard(
        meetingID: MeetingID,
        receipt: MeetingTransferReceipt,
        to url: URL
    ) throws {
        guard receipt.sourceMeetingID == meetingID,
              let importGenerationID = receipt.importGenerationID else {
            throw LibraryError.invalidImportedMeetingProcessingState(
                "transfer commit guard requires a generation identity"
            )
        }
        try JSONDocumentStore.write(
            MeetingTransferCommitPendingDocument(
                meetingID: meetingID,
                importGenerationID: importGenerationID,
                sourcePackageContentDigest: receipt.sourcePackageContentDigest
            ),
            to: url
        )
    }

    static func write(
        _ state: ImportedMeetingProcessingState,
        meetingID: MeetingID,
        receipt: MeetingTransferReceipt,
        to url: URL
    ) throws {
        try validate(state, meetingID: meetingID, receipt: receipt)
        try JSONDocumentStore.write(MeetingTransferStateDocument(state: state), to: url)
    }

    static func validate(
        _ state: ImportedMeetingProcessingState,
        meetingID: MeetingID,
        receipt: MeetingTransferReceipt
    ) throws {
        guard receipt.sourceMeetingID == meetingID else {
            throw LibraryError.invalidImportedMeetingProcessingState(
                "transfer receipt meeting mismatch"
            )
        }
        if let generationID = receipt.importGenerationID,
           generationID.rawValue == zeroUUID {
            throw LibraryError.invalidImportedMeetingProcessingState(
                "transfer receipt generation must not be zero"
            )
        }
        switch state {
        case .importedOnly, .awaitingLanguageConfirmation:
            break
        case .awaitingModel(let localeIdentifier):
            try validateLocale(localeIdentifier)
        case .processingRequested(let request):
            guard request.meetingID == meetingID else {
                throw LibraryError.invalidImportedMeetingProcessingState(
                    "processing request meeting mismatch"
                )
            }
            guard request.id.rawValue != zeroUUID,
                  request.jobID.rawValue != zeroUUID else {
                throw LibraryError.invalidImportedMeetingProcessingState(
                    "processing request identifiers must not be zero"
                )
            }
            guard request.createdAt.timeIntervalSinceReferenceDate.isFinite else {
                throw LibraryError.invalidImportedMeetingProcessingState(
                    "processing request date must be finite"
                )
            }
            if receipt.importGenerationID != nil || request.importGenerationID != nil {
                guard let receiptGenerationID = receipt.importGenerationID,
                      let requestGenerationID = request.importGenerationID,
                      receiptGenerationID == requestGenerationID,
                      requestGenerationID.rawValue != zeroUUID else {
                    throw LibraryError.invalidImportedMeetingProcessingState(
                        "processing request generation mismatch"
                    )
                }
            }
            try validateLocale(request.localeIdentifier)
        case .jobEnqueued(let jobID, let localeIdentifier):
            guard jobID.rawValue != zeroUUID else {
                throw LibraryError.invalidImportedMeetingProcessingState(
                    "job identifier must not be zero"
                )
            }
            try validateLocale(localeIdentifier)
        case .needsManualRetry(let jobID, let localeIdentifier, let reason):
            guard jobID.rawValue != zeroUUID else {
                throw LibraryError.invalidImportedMeetingProcessingState(
                    "job identifier must not be zero"
                )
            }
            try validateLocale(localeIdentifier)
            guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LibraryError.invalidImportedMeetingProcessingState(
                    "manual retry reason must not be blank"
                )
            }
        }
    }

    private static func loadDocument(from url: URL) throws -> MeetingTransferStateDocument {
        try JSONDocumentStore.read(
            MeetingTransferStateDocument.self,
            from: url,
            currentSchemaVersion: MeetingTransferStateDocument.currentSchemaVersion,
            schemaVersion: \.schemaVersion
        )
    }

    private nonisolated func transferReceipt(
        for meetingID: MeetingID
    ) throws -> MeetingTransferReceipt {
        let meetingURL = layout.meetingMetadata(meetingID)
        guard FileManager.default.fileExists(atPath: meetingURL.path) else {
            throw LibraryError.meetingNotFound(meetingID)
        }
        let meeting = try JSONDocumentStore.read(
            Meeting.self,
            from: meetingURL,
            currentSchemaVersion: Meeting.currentSchemaVersion,
            schemaVersion: \.schemaVersion
        )
        guard meeting.id == meetingID,
              let receipt = meeting.metadata?.transferReceipt else {
            throw LibraryError.invalidImportedMeetingProcessingState(
                "state requires a transfer receipt for its target meeting"
            )
        }
        return receipt
    }

    package nonisolated func transferReceipt(
        for meetingID: MeetingID,
        transaction: LibraryMutationTransaction
    ) throws -> MeetingTransferReceipt {
        try transaction.validate(layout: layout)
        return try transferReceipt(for: meetingID)
    }

    private nonisolated func commitPendingDocument(
        _ meetingID: MeetingID
    ) throws -> MeetingTransferCommitPendingDocument? {
        let url = layout.transferCommitPending(meetingID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let document = try JSONDocumentStore.read(
            MeetingTransferCommitPendingDocument.self,
            from: url,
            currentSchemaVersion: MeetingTransferCommitPendingDocument.currentSchemaVersion,
            schemaVersion: \.schemaVersion
        )
        guard document.schemaVersion == MeetingTransferCommitPendingDocument.currentSchemaVersion
        else {
            throw LibraryError.invalidImportedMeetingProcessingState(
                "unsupported transfer commit guard"
            )
        }
        return document
    }

    private nonisolated func validate(
        _ document: MeetingTransferCommitPendingDocument,
        meetingID: MeetingID,
        receipt: MeetingTransferReceipt
    ) throws {
        guard document.meetingID == meetingID else {
            throw LibraryError.invalidImportedMeetingProcessingState(
                "transfer commit guard meeting mismatch"
            )
        }
        switch (document.importGenerationID, document.sourcePackageContentDigest) {
        case (nil, nil):
            // Pre-generation guards remain visible and fail closed. They can
            // block reconciliation but cannot mint a generation token.
            break
        case let (.some(generationID), .some(digest)):
            guard generationID.rawValue != Self.zeroUUID,
                  receipt.importGenerationID == generationID,
                  receipt.sourcePackageContentDigest == digest else {
                throw LibraryError.invalidImportedMeetingProcessingState(
                    "transfer commit guard generation mismatch"
                )
            }
        default:
            throw LibraryError.invalidImportedMeetingProcessingState(
                "incomplete transfer commit guard generation"
            )
        }
    }

    private static func validateLocale(_ localeIdentifier: String) throws {
        let trimmed = localeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed == localeIdentifier,
              !localeIdentifier.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw LibraryError.invalidImportedMeetingProcessingState(
                "locale identifier must be nonblank and normalized"
            )
        }
    }

    private static let zeroUUID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000000"
    )!
}
